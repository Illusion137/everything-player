import Foundation

struct EPMP4Sample {
  var trackId: UInt32 = 0
  let dts: Int64
  let pts: Int64
  let duration: Int64
  let isSync: Bool
  let data: Data
}

enum EPMP4Codec {
  case avc(avcC: Data, width: Int, height: Int)
  case aac(asc: Data, sampleRate: Double, channels: Int)
  case unsupported(String)
}

struct EPMP4TrackInfo {
  let trackId: UInt32
  let timescale: UInt32
  let codec: EPMP4Codec
}

final class EPFMP4Demuxer {
  private(set) var tracks: [EPMP4TrackInfo] = []
  var track: EPMP4TrackInfo? { tracks.first }
  private var buf = Data()
  private var pendingMoof: Data?
  private var trexDefaultDuration: UInt32 = 0
  private var trexDefaultSize: UInt32 = 0
  private var trexDefaultFlags: UInt32 = 0

  func reset() {
    buf = Data()
    pendingMoof = nil
  }

  func feed(_ data: Data) -> [EPMP4Sample] {
    buf.append(data)
    var samples: [EPMP4Sample] = []
    var pos = buf.startIndex
    while true {
      guard let (type, headerLen, size) = boxHeader(buf, at: pos) else { break }
      guard pos + size <= buf.endIndex else { break }
      let box = buf[pos..<pos + size]
      switch type {
      case "moov":
        parseMoov(box[(box.startIndex + headerLen)...])
      case "moof":
        pendingMoof = Data(box)
      case "mdat":
        if let moof = pendingMoof {
          samples.append(contentsOf: parseFragment(moof: moof, mdat: Data(box), mdatHeader: headerLen))
          pendingMoof = nil
        }
      default:
        break
      }
      pos += size
    }
    if pos > buf.startIndex { buf = Data(buf[pos...]) }
    return samples
  }

  private func boxHeader(_ data: Data, at pos: Data.Index) -> (String, Int, Int)? {
    guard pos + 8 <= data.endIndex else { return nil }
    var size = Int(readU32(data, pos))
    let type = String(bytes: data[pos + 4..<pos + 8], encoding: .ascii) ?? ""
    var header = 8
    if size == 1 {
      guard pos + 16 <= data.endIndex else { return nil }
      size = Int(readU64(data, pos + 8))
      header = 16
    } else if size == 0 {
      size = data.endIndex - pos
    }
    guard size >= header else { return nil }
    return (type, header, size)
  }

  private func children(_ data: Data) -> [(String, Data)] {
    var out: [(String, Data)] = []
    var pos = data.startIndex
    while let (type, header, size) = boxHeader(data, at: pos), pos + size <= data.endIndex {
      out.append((type, data[pos + header..<pos + size]))
      pos += size
    }
    return out
  }

  private func parseMoov(_ moov: Data) {
    for (type, body) in children(moov) {
      if type == "mvex" {
        for (t, b) in children(body) where t == "trex" {
          let s = b.startIndex + 4
          guard s + 20 <= b.endIndex else { continue }
          trexDefaultDuration = readU32(b, s + 8)
          trexDefaultSize = readU32(b, s + 12)
          trexDefaultFlags = readU32(b, s + 16)
        }
      } else if type == "trak", let t = parseTrak(body) {
        tracks.removeAll { $0.trackId == t.trackId }
        tracks.append(t)
      }
    }
  }

  private func parseTrak(_ trak: Data) -> EPMP4TrackInfo? {
    var trackId: UInt32 = 1
    var timescale: UInt32 = 1000
    var codec: EPMP4Codec?
    for (type, body) in children(trak) {
      if type == "tkhd" {
        let version = body[body.startIndex]
        trackId = readU32(body, body.startIndex + (version == 1 ? 20 : 12))
      } else if type == "mdia" {
        for (t, b) in children(body) {
          if t == "mdhd" {
            let version = b[b.startIndex]
            timescale = readU32(b, b.startIndex + (version == 1 ? 20 : 12))
          } else if t == "minf" {
            for (mt, mb) in children(b) where mt == "stbl" {
              for (st, sb) in children(mb) where st == "stsd" {
                codec = parseStsd(sb)
              }
            }
          }
        }
      }
    }
    guard let codec else { return nil }
    return EPMP4TrackInfo(trackId: trackId, timescale: timescale, codec: codec)
  }

  private func parseStsd(_ stsd: Data) -> EPMP4Codec {
    let entries = stsd[(stsd.startIndex + 8)...]
    guard let (type, header, size) = boxHeader(entries, at: entries.startIndex) else { return .unsupported("stsd") }
    let entry = entries[(entries.startIndex + header)..<(entries.startIndex + size)]
    switch type {
    case "avc1", "avc3":
      guard entry.count > 78 else { return .unsupported(type) }
      let width = Int(readU16(entry, entry.startIndex + 24))
      let height = Int(readU16(entry, entry.startIndex + 26))
      for (t, b) in children(entry[(entry.startIndex + 78)...]) where t == "avcC" {
        return .avc(avcC: Data(b), width: width, height: height)
      }
      return .unsupported("avc1 without avcC")
    case "mp4a":
      guard entry.count > 28 else { return .unsupported(type) }
      let channels = Int(readU16(entry, entry.startIndex + 16))
      let sampleRate = Double(readU32(entry, entry.startIndex + 24) >> 16)
      for (t, b) in children(entry[(entry.startIndex + 28)...]) where t == "esds" {
        if let asc = parseESDS(b) { return .aac(asc: asc, sampleRate: sampleRate, channels: channels) }
      }
      return .unsupported("mp4a without esds")
    default:
      return .unsupported(type)
    }
  }

  private func parseESDS(_ esds: Data) -> Data? {
    var pos = esds.startIndex + 4
    func readDescriptor() -> (UInt8, Int)? {
      guard pos < esds.endIndex else { return nil }
      let tag = esds[pos]; pos += 1
      var len = 0
      for _ in 0..<4 {
        guard pos < esds.endIndex else { return nil }
        let b = esds[pos]; pos += 1
        len = (len << 7) | Int(b & 0x7F)
        if b & 0x80 == 0 { break }
      }
      return (tag, len)
    }
    guard let (tag, _) = readDescriptor(), tag == 0x03 else { return nil }
    guard pos + 3 <= esds.endIndex else { return nil }
    let flags = esds[pos + 2]
    pos += 3
    if flags & 0x80 != 0 { pos += 2 }
    if flags & 0x40 != 0, pos < esds.endIndex { pos += 1 + Int(esds[pos]) }
    if flags & 0x20 != 0 { pos += 2 }
    guard let (dcTag, _) = readDescriptor(), dcTag == 0x04 else { return nil }
    pos += 13
    guard let (dsiTag, dsiLen) = readDescriptor(), dsiTag == 0x05, pos + dsiLen <= esds.endIndex else { return nil }
    return Data(esds[pos..<pos + dsiLen])
  }

  private func parseFragment(moof: Data, mdat: Data, mdatHeader: Int) -> [EPMP4Sample] {
    var samples: [EPMP4Sample] = []
    let moofBody = moof[(moof.startIndex + 8)...]
    for (type, traf) in children(moofBody) where type == "traf" {
      var baseDataOffset: Int64 = 0
      var defaultDuration = trexDefaultDuration
      var defaultSize = trexDefaultSize
      var defaultFlags = trexDefaultFlags
      var baseDecodeTime: Int64 = 0
      var trafTrackId: UInt32 = 0
      var runs: [Data] = []
      for (t, b) in children(traf) {
        switch t {
        case "tfhd":
          let flags = readU32(b, b.startIndex) & 0xFFFFFF
          trafTrackId = readU32(b, b.startIndex + 4)
          var p = b.startIndex + 8
          if flags & 0x01 != 0 { baseDataOffset = Int64(readU64(b, p)); p += 8 }
          if flags & 0x02 != 0 { p += 4 }
          if flags & 0x08 != 0 { defaultDuration = readU32(b, p); p += 4 }
          if flags & 0x10 != 0 { defaultSize = readU32(b, p); p += 4 }
          if flags & 0x20 != 0 { defaultFlags = readU32(b, p); p += 4 }
        case "tfdt":
          let version = b[b.startIndex]
          baseDecodeTime = version == 1 ? Int64(readU64(b, b.startIndex + 4)) : Int64(readU32(b, b.startIndex + 4))
        case "trun":
          runs.append(b)
        default:
          break
        }
      }
      var dts = baseDecodeTime
      for trun in runs {
        let version = trun[trun.startIndex]
        let flags = readU32(trun, trun.startIndex) & 0xFFFFFF
        let count = Int(readU32(trun, trun.startIndex + 4))
        var p = trun.startIndex + 8
        var dataOffset: Int64 = 0
        if flags & 0x001 != 0 { dataOffset = Int64(Int32(bitPattern: readU32(trun, p))); p += 4 }
        var firstFlags: UInt32?
        if flags & 0x004 != 0 { firstFlags = readU32(trun, p); p += 4 }
        var offsetInMdat = Int(baseDataOffset + dataOffset) - moof.count - mdatHeader
        if flags & 0x001 == 0 { offsetInMdat = 0 }
        for i in 0..<count {
          var duration = defaultDuration
          var size = defaultSize
          var sampleFlags = (i == 0 ? firstFlags : nil) ?? defaultFlags
          var cto: Int64 = 0
          if flags & 0x100 != 0 { duration = readU32(trun, p); p += 4 }
          if flags & 0x200 != 0 { size = readU32(trun, p); p += 4 }
          if flags & 0x400 != 0 { sampleFlags = readU32(trun, p); p += 4 }
          if flags & 0x800 != 0 {
            let raw = readU32(trun, p)
            cto = version == 0 ? Int64(raw) : Int64(Int32(bitPattern: raw))
            p += 4
          }
          let start = mdat.startIndex + mdatHeader + offsetInMdat
          let end = start + Int(size)
          guard start >= mdat.startIndex + mdatHeader, end <= mdat.endIndex else { break }
          let isSync = (sampleFlags & 0x00010000) == 0
          samples.append(EPMP4Sample(trackId: trafTrackId, dts: dts, pts: dts + cto, duration: Int64(duration), isSync: isSync, data: mdat.subdata(in: start..<end)))
          offsetInMdat += Int(size)
          dts += Int64(duration)
        }
      }
    }
    return samples
  }

  private func readU16(_ d: Data, _ p: Data.Index) -> UInt16 {
    guard p + 2 <= d.endIndex else { return 0 }
    return UInt16(d[p]) << 8 | UInt16(d[p + 1])
  }

  private func readU32(_ d: Data, _ p: Data.Index) -> UInt32 {
    guard p + 4 <= d.endIndex else { return 0 }
    return UInt32(d[p]) << 24 | UInt32(d[p + 1]) << 16 | UInt32(d[p + 2]) << 8 | UInt32(d[p + 3])
  }

  private func readU64(_ d: Data, _ p: Data.Index) -> UInt64 {
    UInt64(readU32(d, p)) << 32 | UInt64(readU32(d, p + 4))
  }
}
