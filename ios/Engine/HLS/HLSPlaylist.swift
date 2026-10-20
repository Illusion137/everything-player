import Foundation

struct EPHLSByteRange: Hashable {
  var length: Int
  var offset: Int
}

struct EPHLSKey: Equatable {
  enum Method: String { case none = "NONE", aes128 = "AES-128", sampleAES = "SAMPLE-AES", other }
  var method: Method
  var uri: URL?
  var iv: Data?
}

struct EPHLSMap: Hashable {
  var uri: URL
  var range: EPHLSByteRange?
}

struct EPHLSSegment {
  var uri: URL
  var duration: Double
  var start: Double
  var sequence: Int
  var discontinuity: Int
  var range: EPHLSByteRange?
  var key: EPHLSKey?
  var map: EPHLSMap?
}

struct EPHLSMediaPlaylist {
  var targetDuration: Double
  var mediaSequence: Int
  var segments: [EPHLSSegment]
  var ended: Bool

  var duration: Double { segments.last.map { $0.start + $0.duration } ?? 0 }

  func index(containing time: Double) -> Int? {
    guard !segments.isEmpty else { return nil }
    if let i = segments.lastIndex(where: { $0.start <= time + 0.001 }) { return i }
    return 0
  }
}

struct EPHLSRendition {
  var groupId: String
  var name: String
  var language: String?
  var isDefault: Bool
  var uri: URL?
}

struct EPHLSVariant {
  var index: Int
  var uri: URL
  var bandwidth: Int
  var averageBandwidth: Int?
  var width: Int?
  var height: Int?
  var frameRate: Double?
  var codecs: [String]
  var audioGroup: String?

  var hasVideoCodec: Bool { codecs.contains { EPHLSCodec.isVideo($0) } || (codecs.isEmpty && height != nil) }
  var isAudioOnly: Bool { !codecs.isEmpty && codecs.allSatisfy { EPHLSCodec.isAudio($0) } }
}

struct EPHLSMasterPlaylist {
  var variants: [EPHLSVariant]
  var audio: [EPHLSRendition]
  var hasSessionKeySampleAES: Bool

  var playableVideoVariants: [EPHLSVariant] {
    variants.filter { v in
      guard !v.isAudioOnly else { return false }
      return v.codecs.filter(EPHLSCodec.isVideo).allSatisfy(EPHLSCodec.isSupportedVideo)
        && v.codecs.filter(EPHLSCodec.isAudio).allSatisfy(EPHLSCodec.isSupportedAudio)
    }
  }

  var audioVariant: EPHLSVariant? {
    let capable = variants.filter { $0.codecs.filter(EPHLSCodec.isAudio).allSatisfy(EPHLSCodec.isSupportedAudio) }
    let audioOnly = capable.filter(\.isAudioOnly)
    let withRendition = capable.filter { audioRendition(for: $0) != nil }
    let pool = !audioOnly.isEmpty ? audioOnly : (!withRendition.isEmpty ? withRendition : capable)
    return pool.min { $0.bandwidth < $1.bandwidth }
  }

  func audioRendition(for variant: EPHLSVariant) -> EPHLSRendition? {
    guard let group = variant.audioGroup else { return nil }
    let options = audio.filter { $0.groupId == group && $0.uri != nil }
    return options.first(where: \.isDefault) ?? options.first
  }
}

enum EPHLSCodec {
  static func isVideo(_ c: String) -> Bool {
    ["avc1", "avc3", "hvc1", "hev1", "dvh1", "dvhe", "av01", "vp09"].contains { c.hasPrefix($0) }
  }

  static func isAudio(_ c: String) -> Bool {
    ["mp4a", "ac-3", "ec-3", "opus", "flac", "alac", "mp3"].contains { c.hasPrefix($0) }
  }

  static func isSupportedVideo(_ c: String) -> Bool { c.hasPrefix("avc1") || c.hasPrefix("avc3") }

  static func isSupportedAudio(_ c: String) -> Bool { c.hasPrefix("mp4a.40") || c == "mp4a" }
}

enum EPHLSParser {
  enum Parsed {
    case master(EPHLSMasterPlaylist)
    case media(EPHLSMediaPlaylist)
  }

  static func parse(_ text: String, base: URL) throws -> Parsed {
    let lines = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
    guard lines.first?.hasPrefix("#EXTM3U") == true else {
      throw EPError(.sourceError, "Not an HLS playlist")
    }
    if lines.contains(where: { $0.hasPrefix("#EXT-X-STREAM-INF") }) {
      return .master(parseMaster(lines, base: base))
    }
    return .media(parseMedia(lines, base: base))
  }

  static func attributes(_ s: Substring) -> [String: String] {
    var out: [String: String] = [:]
    var i = s.startIndex
    while i < s.endIndex {
      guard let eq = s[i...].firstIndex(of: "=") else { break }
      let key = s[i..<eq].trimmingCharacters(in: CharacterSet(charactersIn: ", "))
      var j = s.index(after: eq)
      var value = ""
      if j < s.endIndex, s[j] == "\"" {
        let start = s.index(after: j)
        let close = s[start...].firstIndex(of: "\"") ?? s.endIndex
        value = String(s[start..<close])
        j = close < s.endIndex ? s.index(after: close) : close
      } else {
        let end = s[j...].firstIndex(of: ",") ?? s.endIndex
        value = String(s[j..<end])
        j = end
      }
      out[key] = value
      i = j < s.endIndex ? s.index(after: j) : j
    }
    return out
  }

  private static func tagValue(_ line: String) -> Substring {
    guard let colon = line.firstIndex(of: ":") else { return "" }
    return line[line.index(after: colon)...]
  }

  private static func parseMaster(_ lines: [String], base: URL) -> EPHLSMasterPlaylist {
    var variants: [EPHLSVariant] = []
    var audio: [EPHLSRendition] = []
    var pending: [String: String]?
    var sampleAES = false
    for line in lines {
      if line.hasPrefix("#EXT-X-STREAM-INF") {
        pending = attributes(tagValue(line))
      } else if line.hasPrefix("#EXT-X-MEDIA:") {
        let a = attributes(tagValue(line))
        guard a["TYPE"] == "AUDIO", let group = a["GROUP-ID"] else { continue }
        audio.append(EPHLSRendition(
          groupId: group, name: a["NAME"] ?? group, language: a["LANGUAGE"],
          isDefault: a["DEFAULT"] == "YES", uri: a["URI"].flatMap { URL(string: $0, relativeTo: base)?.absoluteURL }))
      } else if line.hasPrefix("#EXT-X-SESSION-KEY") {
        if attributes(tagValue(line))["METHOD"] != "NONE" { sampleAES = true }
      } else if !line.hasPrefix("#"), !line.isEmpty, let a = pending {
        pending = nil
        guard let uri = URL(string: line, relativeTo: base)?.absoluteURL else { continue }
        var width: Int?
        var height: Int?
        if let res = a["RESOLUTION"]?.split(separator: "x"), res.count == 2 {
          width = Int(res[0])
          height = Int(res[1])
        }
        variants.append(EPHLSVariant(
          index: variants.count, uri: uri, bandwidth: Int(a["BANDWIDTH"] ?? "") ?? 0,
          averageBandwidth: a["AVERAGE-BANDWIDTH"].flatMap { Int($0) }, width: width, height: height,
          frameRate: a["FRAME-RATE"].flatMap { Double($0) },
          codecs: (a["CODECS"] ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty },
          audioGroup: a["AUDIO"]))
      }
    }
    return EPHLSMasterPlaylist(variants: variants, audio: audio, hasSessionKeySampleAES: sampleAES)
  }

  private static func parseMedia(_ lines: [String], base: URL) -> EPHLSMediaPlaylist {
    var target: Double = 6
    var sequence = 0
    var segments: [EPHLSSegment] = []
    var ended = false
    var duration: Double?
    var discontinuity = 0
    var key: EPHLSKey?
    var map: EPHLSMap?
    var range: EPHLSByteRange?
    var lastRangeEnd: [URL: Int] = [:]
    var start: Double = 0
    var pendingRange: (Int, Int?)?

    for line in lines {
      if line.hasPrefix("#EXT-X-TARGETDURATION") {
        target = Double(tagValue(line)) ?? target
      } else if line.hasPrefix("#EXT-X-MEDIA-SEQUENCE") {
        sequence = Int(tagValue(line)) ?? 0
      } else if line.hasPrefix("#EXT-X-DISCONTINUITY-SEQUENCE") {
        discontinuity = Int(tagValue(line)) ?? 0
      } else if line.hasPrefix("#EXT-X-DISCONTINUITY") {
        discontinuity += 1
      } else if line.hasPrefix("#EXTINF") {
        let v = tagValue(line)
        duration = Double(v.split(separator: ",", maxSplits: 1).first ?? "") ?? 0
      } else if line.hasPrefix("#EXT-X-BYTERANGE") {
        let parts = tagValue(line).split(separator: "@")
        pendingRange = (Int(parts.first ?? "") ?? 0, parts.count > 1 ? Int(parts[1]) : nil)
      } else if line.hasPrefix("#EXT-X-KEY") {
        let a = attributes(tagValue(line))
        let method = EPHLSKey.Method(rawValue: a["METHOD"] ?? "NONE") ?? .other
        var iv: Data?
        if var hex = a["IV"] {
          if hex.hasPrefix("0x") || hex.hasPrefix("0X") { hex = String(hex.dropFirst(2)) }
          iv = Data(hexString: hex)
        }
        key = method == .none ? nil : EPHLSKey(method: method, uri: a["URI"].flatMap { URL(string: $0, relativeTo: base)?.absoluteURL }, iv: iv)
      } else if line.hasPrefix("#EXT-X-MAP") {
        let a = attributes(tagValue(line))
        if let raw = a["URI"], let uri = URL(string: raw, relativeTo: base)?.absoluteURL {
          var r: EPHLSByteRange?
          if let br = a["BYTERANGE"]?.split(separator: "@") {
            r = EPHLSByteRange(length: Int(br.first ?? "") ?? 0, offset: br.count > 1 ? Int(br[1]) ?? 0 : 0)
          }
          map = EPHLSMap(uri: uri, range: r)
        }
      } else if line.hasPrefix("#EXT-X-ENDLIST") {
        ended = true
      } else if !line.hasPrefix("#"), !line.isEmpty, let d = duration {
        guard let uri = URL(string: line, relativeTo: base)?.absoluteURL else { continue }
        if let (length, offset) = pendingRange {
          let o = offset ?? lastRangeEnd[uri] ?? 0
          range = EPHLSByteRange(length: length, offset: o)
          lastRangeEnd[uri] = o + length
        } else {
          range = nil
        }
        segments.append(EPHLSSegment(
          uri: uri, duration: d, start: start, sequence: sequence + segments.count,
          discontinuity: discontinuity, range: range, key: key, map: map))
        start += d
        duration = nil
        pendingRange = nil
      }
    }
    return EPHLSMediaPlaylist(targetDuration: target, mediaSequence: sequence, segments: segments, ended: ended)
  }
}

extension Data {
  init?(hexString: String) {
    var bytes: [UInt8] = []
    bytes.reserveCapacity(hexString.count / 2)
    var index = hexString.startIndex
    while index < hexString.endIndex {
      let next = hexString.index(index, offsetBy: 2, limitedBy: hexString.endIndex) ?? hexString.endIndex
      guard let b = UInt8(hexString[index..<next], radix: 16) else { return nil }
      bytes.append(b)
      index = next
    }
    self.init(bytes)
  }
}
