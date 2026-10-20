import Foundation

enum EPSourceType: String {
  case raw, hls, sabr
}

enum EPState: String {
  case none, ready, playing, paused, stopped, buffering, loading, error, ended
}

enum EPRepeatMode: String {
  case off, track, queue
}

enum EPErrorCode: String {
  case sabrCallbackFailed = "sabr-callback-failed"
  case sabrUnsupported = "sabr-unsupported"
  case sabrStreamFailed = "sabr-stream-failed"
  case sourceError = "source-error"
  case networkError = "network-error"
  case decodeError = "decode-error"
  case unknown
}

struct EPError: Error, CustomStringConvertible {
  let code: EPErrorCode
  let message: String
  var trackId: String?

  init(_ code: EPErrorCode, _ message: String, trackId: String? = nil) {
    self.code = code
    self.message = message
    self.trackId = trackId
  }

  var description: String { "\(code.rawValue): \(message)" }

  static func from(_ error: Error, default code: EPErrorCode = .unknown) -> EPError {
    if let e = error as? EPError { return e }
    let ns = error as NSError
    if ns.domain == NSURLErrorDomain { return EPError(.networkError, ns.localizedDescription) }
    return EPError(code, String(describing: error))
  }
}

struct EPSabrFormat: Codable {
  var itag: Int
  var lastModified: String
  var xtags: String?
  var mimeType: String?
  var bitrate: Int
  var averageBitrate: Int?
  var approxDurationMs: Int
  var contentLength: Int?
  var width: Int?
  var height: Int?
  var fps: Int?
  var quality: String?
  var qualityLabel: String?
  var audioQuality: String?
  var audioSampleRate: Int?
  var audioChannels: Int?
  var audioTrackId: String?
  var language: String?
  var isDrc: Bool?
  var isVb: Bool?
  var isSr: Bool?
  var isHdr: Bool?
  var isDubbed: Bool?
  var isAutoDubbed: Bool?
  var isDescriptive: Bool?
  var isSecondary: Bool?
  var isOriginal: Bool?
}

struct EPSabrInfo: Codable {
  var videoId: String
  var serverAbrStreamingUrl: String
  var videoPlaybackUstreamerConfig: String
  var formats: [EPSabrFormat]
  var poToken: String
  var clientName: Int
  var clientVersion: String
  var cookie: String?
  var duration: Double
}

struct EPTrack: Codable {
  var id: String
  var title: String
  var artist: String
  var album: String?
  var artwork: String?
  var duration: Double?
  var startTime: Double?
  var endTime: Double?
  var url: String?
  var sabr: EPSabrInfo?
  var userAgent: String?
  var contentType: String?
  var headers: [String: String]

  var sourceType: EPSourceType {
    if sabr != nil { return .sabr }
    if let contentType = contentType?.lowercased(),
       contentType == "application/vnd.apple.mpegurl" || contentType == "application/x-mpegurl" {
      return .hls
    }
    if let url, let parsed = URL(string: url), parsed.path.lowercased().hasSuffix(".m3u8") {
      return .hls
    }
    return .raw
  }

  var requestHeaders: [String: String] {
    var h = headers
    if let userAgent, h["User-Agent"] == nil { h["User-Agent"] = userAgent }
    if let cookie = sabr?.cookie, h["Cookie"] == nil { h["Cookie"] = cookie }
    return h
  }

  var trimStart: Double { max(0, startTime ?? 0) }

  func trimEnd(mediaDuration: Double?) -> Double? {
    let known = duration ?? mediaDuration
    switch (endTime, known) {
    case let (e?, d?): return min(e, d)
    case let (e?, nil): return e
    case let (nil, d?): return d
    default: return nil
    }
  }
}

struct EPVideoQualityRange: Equatable, Codable {
  var minHeight: Int?
  var maxHeight: Int?
  var maxBitrate: Int?

  func contains(height: Int?, bitrate: Int) -> Bool {
    let h = height ?? 0
    if let minHeight, h < minHeight { return false }
    if let maxHeight, h > maxHeight { return false }
    if let maxBitrate, maxBitrate > 0, bitrate > maxBitrate { return false }
    return true
  }

  func pick<T>(_ items: [T], height: (T) -> Int?, bitrate: (T) -> Int, budget: Int? = nil) -> T? {
    guard !items.isEmpty else { return nil }
    let sorted = items.sorted { (height($0) ?? 0, bitrate($0)) < (height($1) ?? 0, bitrate($1)) }
    let inRange = sorted.filter { contains(height: height($0), bitrate: bitrate($0)) }
    if let budget {
      let pool = inRange.isEmpty ? sorted : inRange
      return pool.last { bitrate($0) <= budget } ?? pool.first
    }
    if let best = inRange.last { return best }
    if let maxHeight, sorted.allSatisfy({ (height($0) ?? 0) > maxHeight }) { return sorted.first }
    if let maxBitrate, maxBitrate > 0, let fitting = sorted.last(where: { bitrate($0) <= maxBitrate }) { return fitting }
    if let minHeight, sorted.allSatisfy({ (height($0) ?? 0) < minHeight }) { return sorted.last }
    return sorted.first
  }
}

struct EPVideoQuality: Equatable {
  var id: String
  var width: Int?
  var height: Int?
  var fps: Double?
  var bitrate: Int
  var label: String
  var codec: String?
}

struct EPVideoQualityState: Equatable {
  var qualities: [EPVideoQuality] = []
  var selectedId: String?
  var auto = true
}

struct EPSetupOptions {
  var cacheMaxSizeMB: Double = 256
  var cacheMaxAgeSeconds: Double = 7 * 24 * 3600
  var preloadNext: Int = 1
  var sabrPoolAhead: Int = 1
  var persistentCache: Bool = true
  var forwardBufferSeconds: Double = 30
  var maxBufferBytes: Int = 16 * 1024 * 1024
  var enableVideo: Bool = false
  var autoHandleRemoteEvents: Bool = true
  var autoHandleInterruptions: Bool = true
  var sabrCallbackTimeoutMs: Double = 21000
  var videoQualityRange = EPVideoQualityRange(maxHeight: 720)
}

struct EPUpdateOptions {
  var capabilities: [String] = []
  var progressUpdateEventInterval: Double = 0
  var forwardJumpInterval: Double = 15
  var backwardJumpInterval: Double = 15
}

struct EPProgress {
  var position: Double
  var duration: Double
  var buffered: Double
}

enum EPRemoteEvent {
  case play, pause, stop, next, previous
  case seek(Double)
  case jumpForward(Double)
  case jumpBackward(Double)
  case duck(paused: Bool, permanent: Bool)
  case playId(String, Int?)
  case playSearch(String)
  case skip(Int)
  case like, dislike, bookmark
}

enum EPEqualizer {
  static let frequencies: [Float] = [31, 62, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]
  static let minGain: Float = -12
  static let maxGain: Float = 12
}

extension NSLocking {
  func sync<T>(_ body: () throws -> T) rethrows -> T {
    lock()
    defer { unlock() }
    return try body()
  }
}

func onMain(_ block: @escaping () -> Void) {
  if Thread.isMainThread { block() } else { DispatchQueue.main.async(execute: block) }
}
