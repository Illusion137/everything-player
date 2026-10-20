import Foundation

struct EPElementaryPacket {
  var pts: Double
  var dts: Double
  var duration: Double
  var isSync: Bool
  var data: Data
}

struct EPAACConfig: Equatable {
  var asc: Data
  var sampleRate: Double
  var channels: Int
}

struct EPH264ParameterSets: Equatable {
  var sps: Data
  var pps: Data
}

enum EPVideoConfig: Equatable {
  case avcC(Data, width: Int, height: Int)
  case parameterSets(EPH264ParameterSets)
}

struct EPDemuxedMedia {
  var audio: [EPElementaryPacket] = []
  var video: [EPElementaryPacket] = []
  var audioConfig: EPAACConfig?
  var videoConfig: EPVideoConfig?
  var unsupported: String?
}

enum EPADTS {
  static let sampleRates: [Double] = [96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050, 16000, 12000, 11025, 8000, 7350]

  static func frames(_ data: Data, pts: Double, config: inout EPAACConfig?) -> (packets: [EPElementaryPacket], rest: Data) {
    var out: [EPElementaryPacket] = []
    var p = data.startIndex
    var t = pts
    while p + 7 <= data.endIndex {
      guard data[p] == 0xFF, data[p + 1] & 0xF6 == 0xF0 else {
        p += 1
        continue
      }
      let protectionAbsent = data[p + 1] & 0x01 == 1
      let profile = Int(data[p + 2] >> 6)
      let freqIndex = Int((data[p + 2] >> 2) & 0x0F)
      let channelConfig = Int((data[p + 2] & 0x01) << 2 | data[p + 3] >> 6)
      let length = Int(data[p + 3] & 0x03) << 11 | Int(data[p + 4]) << 3 | Int(data[p + 5] >> 5)
      let blocks = Int(data[p + 6] & 0x03) + 1
      let header = protectionAbsent ? 7 : 9
      guard freqIndex < sampleRates.count, length > header else {
        p += 1
        continue
      }
      guard p + length <= data.endIndex else { break }
      let sr = sampleRates[freqIndex]
      if config == nil {
        let aot = profile + 1
        let asc = Data([UInt8(aot << 3 | freqIndex >> 1), UInt8((freqIndex & 1) << 7 | channelConfig << 3)])
        config = EPAACConfig(asc: asc, sampleRate: sr, channels: max(1, channelConfig))
      }
      let duration = Double(1024 * blocks) / sr
      out.append(EPElementaryPacket(pts: t, dts: t, duration: duration, isSync: true, data: data.subdata(in: (p + header)..<(p + length))))
      t += duration
      p += length
    }
    return (out, p < data.endIndex ? data.subdata(in: p..<data.endIndex) : Data())
  }

  static func packedAudio(_ data: Data) -> EPDemuxedMedia {
    var media = EPDemuxedMedia()
    var p = data.startIndex
    var pts: Double = 0
    while p + 10 <= data.endIndex, data[p] == 0x49, data[p + 1] == 0x44, data[p + 2] == 0x33 {
      let size = Int(data[p + 6] & 0x7F) << 21 | Int(data[p + 7] & 0x7F) << 14 | Int(data[p + 8] & 0x7F) << 7 | Int(data[p + 9] & 0x7F)
      let end = min(data.endIndex, p + 10 + size)
      if let ts = transportTimestamp(data[(p + 10)..<end]) { pts = ts }
      p = end
    }
    if p + 2 <= data.endIndex, data[p] == 0xFF, data[p + 1] & 0xF6 == 0xF0 {
      var config: EPAACConfig?
      media.audio = frames(data.subdata(in: p..<data.endIndex), pts: pts, config: &config).packets
      media.audioConfig = config
    } else if p < data.endIndex {
      media.unsupported = "packed audio"
    }
    return media
  }

  private static func transportTimestamp(_ tag: Data) -> Double? {
    let owner = Array("com.apple.streaming.transportStreamTimestamp".utf8) + [0]
    var p = tag.startIndex
    while p + 10 <= tag.endIndex {
      let id = String(bytes: tag[p..<p + 4], encoding: .ascii) ?? ""
      let size = Int(tag[p + 4]) << 24 | Int(tag[p + 5]) << 16 | Int(tag[p + 6]) << 8 | Int(tag[p + 7])
      let body = p + 10
      guard size > 0, body + size <= tag.endIndex else { return nil }
      if id == "PRIV", size >= owner.count + 8, Array(tag[body..<body + owner.count]) == owner {
        var v: UInt64 = 0
        for b in tag[(body + owner.count)..<(body + owner.count + 8)] { v = v << 8 | UInt64(b) }
        return Double(v & 0x1_FFFF_FFFF) / 90000
      }
      p = body + size
    }
    return nil
  }
}

final class EPMPEGTSDemuxer {
  private var pmtPid: Int?
  private var audioPid: Int?
  private var videoPid: Int?
  private var unsupported: String?
  private var audioPES = Data()
  private var videoPES = Data()
  private var audioRest = Data()
  private var audioRestPts: Double?
  private var audioConfig: EPAACConfig?
  private var sps: Data?
  private var pps: Data?

  func demux(_ data: Data) -> EPDemuxedMedia {
    var media = EPDemuxedMedia()
    var p = data.startIndex
    while p < data.endIndex, data[p] != 0x47 { p += 1 }
    while p + 188 <= data.endIndex {
      guard data[p] == 0x47 else {
        p += 1
        continue
      }
      packet(data[p..<p + 188], into: &media)
      p += 188
    }
    flushAudio(into: &media)
    flushVideo(into: &media)
    media.audioConfig = audioConfig
    if let sps, let pps { media.videoConfig = .parameterSets(EPH264ParameterSets(sps: sps, pps: pps)) }
    media.unsupported = unsupported
    return media
  }

  private func packet(_ pkt: Data, into media: inout EPDemuxedMedia) {
    let s = pkt.startIndex
    let start = pkt[s + 1] & 0x40 != 0
    let pid = Int(pkt[s + 1] & 0x1F) << 8 | Int(pkt[s + 2])
    let afc = (pkt[s + 3] >> 4) & 0x03
    var payload = s + 4
    if afc == 2 { return }
    if afc == 3 { payload += 1 + Int(pkt[s + 4]) }
    guard payload < pkt.endIndex else { return }
    let body = pkt[payload..<pkt.endIndex]
    if pid == 0 {
      parsePAT(body, start: start)
    } else if pid == pmtPid {
      parsePMT(body, start: start)
    } else if pid == audioPid {
      if start { flushAudio(into: &media) }
      audioPES.append(body)
    } else if pid == videoPid {
      if start { flushVideo(into: &media) }
      videoPES.append(body)
    }
  }

  private func section(_ body: Data, start: Bool) -> Data? {
    guard start, let first = body.first else { return nil }
    let s = body.startIndex + 1 + Int(first)
    guard s + 3 <= body.endIndex else { return nil }
    let length = Int(body[s + 1] & 0x0F) << 8 | Int(body[s + 2])
    guard s + 3 + length <= body.endIndex else { return nil }
    return body.subdata(in: s..<(s + 3 + length))
  }

  private func parsePAT(_ body: Data, start: Bool) {
    guard let sec = section(body, start: start), sec.count >= 12 else { return }
    var p = 8
    while p + 4 <= sec.count - 4 {
      let program = Int(sec[p]) << 8 | Int(sec[p + 1])
      let pid = Int(sec[p + 2] & 0x1F) << 8 | Int(sec[p + 3])
      if program != 0 {
        pmtPid = pid
        return
      }
      p += 4
    }
  }

  private func parsePMT(_ body: Data, start: Bool) {
    guard let sec = section(body, start: start), sec.count >= 16 else { return }
    let infoLength = Int(sec[10] & 0x0F) << 8 | Int(sec[11])
    var p = 12 + infoLength
    while p + 5 <= sec.count - 4 {
      let type = sec[p]
      let pid = Int(sec[p + 1] & 0x1F) << 8 | Int(sec[p + 2])
      let esLength = Int(sec[p + 3] & 0x0F) << 8 | Int(sec[p + 4])
      switch type {
      case 0x0F: if audioPid == nil { audioPid = pid }
      case 0x1B: if videoPid == nil { videoPid = pid }
      case 0x03, 0x04: if audioPid == nil { unsupported = "mp3 audio" }
      case 0x81, 0x87: if audioPid == nil { unsupported = "ac-3 audio" }
      case 0x24: if videoPid == nil { unsupported = "hevc video" }
      case 0xDB, 0xCF: unsupported = "sample-aes"
      default: break
      }
      p += 5 + esLength
    }
  }

  private func parsePES(_ pes: Data) -> (pts: Double?, dts: Double?, payload: Data)? {
    let s = pes.startIndex
    guard pes.count >= 9, pes[s] == 0, pes[s + 1] == 0, pes[s + 2] == 1 else { return nil }
    let flags = pes[s + 7]
    let headerLength = Int(pes[s + 8])
    guard 9 + headerLength <= pes.count else { return nil }
    func ts(_ o: Int) -> Double {
      let p = s + o
      let v = (UInt64(pes[p] & 0x0E) << 29) | (UInt64(pes[p + 1]) << 22) | (UInt64(pes[p + 2] & 0xFE) << 14) | (UInt64(pes[p + 3]) << 7) | (UInt64(pes[p + 4]) >> 1)
      return Double(v) / 90000
    }
    var pts: Double?
    var dts: Double?
    if flags & 0x80 != 0, headerLength >= 5 { pts = ts(9) }
    if flags & 0x40 != 0, headerLength >= 10 { dts = ts(14) }
    return (pts, dts ?? pts, pes.subdata(in: (s + 9 + headerLength)..<pes.endIndex))
  }

  private func flushAudio(into media: inout EPDemuxedMedia) {
    guard !audioPES.isEmpty else { return }
    defer { audioPES = Data() }
    guard let pes = parsePES(audioPES) else { return }
    var data = audioRest
    data.append(pes.payload)
    let pts = audioRest.isEmpty ? (pes.pts ?? audioRestPts ?? 0) : (audioRestPts ?? pes.pts ?? 0)
    let (packets, rest) = EPADTS.frames(data, pts: pts, config: &audioConfig)
    media.audio.append(contentsOf: packets)
    audioRest = rest
    audioRestPts = packets.last.map { $0.pts + $0.duration } ?? pts
  }

  private func flushVideo(into media: inout EPDemuxedMedia) {
    guard !videoPES.isEmpty else { return }
    defer { videoPES = Data() }
    guard let pes = parsePES(videoPES), let pts = pes.pts else { return }
    var avcc = Data()
    var sync = false
    for nal in Self.nalUnits(pes.payload) {
      guard let header = nal.first else { continue }
      switch header & 0x1F {
      case 9: continue
      case 7: sps = nal
      case 8: pps = nal
      case 5: sync = true
      default: break
      }
      var length = UInt32(nal.count).bigEndian
      withUnsafeBytes(of: &length) { avcc.append(contentsOf: $0) }
      avcc.append(nal)
    }
    guard !avcc.isEmpty else { return }
    media.video.append(EPElementaryPacket(pts: pts, dts: pes.dts ?? pts, duration: 0, isSync: sync, data: avcc))
  }

  static func nalUnits(_ data: Data) -> [Data] {
    var units: [Data] = []
    let bytes = [UInt8](data)
    var i = 0
    var start = -1
    let n = bytes.count
    while i + 2 < n {
      if bytes[i] == 0, bytes[i + 1] == 0, bytes[i + 2] == 1 {
        if start >= 0 {
          var end = i
          if end > start, bytes[end - 1] == 0 { end -= 1 }
          if end > start { units.append(Data(bytes[start..<end])) }
        }
        i += 3
        start = i
      } else {
        i += 1
      }
    }
    if start >= 0, start < n { units.append(Data(bytes[start..<n])) }
    return units
  }
}
