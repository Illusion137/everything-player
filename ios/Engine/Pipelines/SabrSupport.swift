import Foundation

struct EPLocalSabrMedia {
  var audioURL: URL
  var audioIsOpus: Bool
  var videoURL: URL?
}

typealias EPChunkReader = () async throws -> Data?

enum EPSabr {
  static func googleFormat(_ f: EPSabrFormat) -> SabrFormat {
    let mime = f.mimeType ?? ""
    return SabrFormat(
      itag: f.itag, lastModified: f.lastModified, xtags: f.xtags, contentLength: f.contentLength,
      mimeType: f.mimeType, bitrate: f.bitrate, height: f.height, approxDurationMs: f.approxDurationMs,
      fps: f.fps, width: f.width, audioTrackId: f.audioTrackId, isDrc: f.isDrc, isVb: f.isVb, isSr: f.isSr,
      quality: f.quality, qualityLabel: f.qualityLabel, averageBitrate: f.averageBitrate,
      audioQuality: f.audioQuality, numChannels: f.audioChannels, language: f.language,
      isHdr: f.isHdr ?? false, isDubbed: f.isDubbed, isAutoDubbed: f.isAutoDubbed,
      isDescriptive: f.isDescriptive, isSecondary: f.isSecondary, isOriginal: f.isOriginal,
      hasAudio: mime.hasPrefix("audio"), hasVideo: mime.hasPrefix("video"))
  }

  static func pickAudio(_ formats: [EPSabrFormat]) -> EPSabrFormat? {
    let audio = formats.filter { ($0.mimeType ?? "").hasPrefix("audio") }
    let preferred = audio.filter(isMainAudio)
    let pool = preferred.isEmpty ? audio : preferred
    let original = pool.filter { $0.isOriginal != false }
    let candidates = original.isEmpty ? pool : original
    let opus = candidates.filter { ($0.mimeType ?? "").contains("opus") }
    let aac = candidates.filter { ($0.mimeType ?? "").contains("mp4a") }
    return (opus.isEmpty ? aac : opus).max { $0.bitrate < $1.bitrate }
  }

  private static func isMainAudio(_ f: EPSabrFormat) -> Bool {
    if f.isDrc == true || f.isDescriptive == true { return false }
    if f.isAutoDubbed == true || f.isSecondary == true { return false }
    return true
  }

  static func videoFormats(_ formats: [EPSabrFormat]) -> [EPSabrFormat] {
    var seen = Set<Int>()
    return formats.filter {
      let m = $0.mimeType ?? ""
      return m.hasPrefix("video") && (m.contains("avc1") || m.contains("avc3")) && $0.isHdr != true && seen.insert($0.itag).inserted
    }
    .sorted { (($0.height ?? 0), $0.bitrate) > (($1.height ?? 0), $1.bitrate) }
  }

  static func pickVideo(_ formats: [EPSabrFormat], range: EPVideoQualityRange) -> EPSabrFormat? {
    range.pick(videoFormats(formats), height: { $0.height }, bitrate: { $0.averageBitrate ?? $0.bitrate })
  }

  static func quality(_ f: EPSabrFormat) -> EPVideoQuality {
    let mime = f.mimeType ?? ""
    let codec = mime.range(of: "codecs=\"").map { r in String(mime[r.upperBound...].prefix { $0 != "\"" }) }
    return EPVideoQuality(
      id: String(f.itag), width: f.width, height: f.height, fps: f.fps.map(Double.init),
      bitrate: f.averageBitrate ?? f.bitrate, label: f.qualityLabel ?? f.height.map { "\($0)p" } ?? "itag \(f.itag)",
      codec: codec)
  }

  static func isOpus(_ format: EPSabrFormat) -> Bool {
    (format.mimeType ?? "").contains("opus") || (format.mimeType ?? "").contains("webm")
  }

  static func clientInfo(_ info: EPSabrInfo) -> ClientInfo {
    var client = ClientInfo()
    client.clientName = Int32(info.clientName)
    client.clientVersion = info.clientVersion
    return client
  }

  static func fetchFunction(headers: [String: String]) -> FetchFunction {
    { request in
      var req = request
      for (k, v) in headers where req.value(forHTTPHeaderField: k) == nil {
        req.setValue(v, forHTTPHeaderField: k)
      }
      return try await StreamingFetcher.shared.fetch(req)
    }
  }

  static func streamReader(_ stream: ReadableStream<Data>) -> EPChunkReader {
    let reader = stream.getReader()
    return {
      let result = try await reader.read()
      return result.done ? nil : (result.value ?? Data())
    }
  }

  static func fileReader(_ url: URL, chunkSize: Int = 64 * 1024) throws -> EPChunkReader {
    let handle = try FileHandle(forReadingFrom: url)
    return {
      try Task.checkCancellation()
      guard let data = try handle.read(upToCount: chunkSize), !data.isEmpty else {
        try? handle.close()
        return nil
      }
      return data
    }
  }
}

func epSleep(_ seconds: Double) async {
  try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
}
