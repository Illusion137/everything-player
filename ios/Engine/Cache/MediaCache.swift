import CryptoKit
import Foundation
import UniformTypeIdentifiers

struct EPCachedMeta: Codable {
  var contentLength: Int64
  var contentType: String
}

final class EPMediaCache {
  static let shared = EPMediaCache()
  static let chunkSize: Int64 = 256 * 1024

  private let ioQueue = DispatchQueue(label: "everythingplayer.cache")
  private let memory = NSCache<NSString, NSData>()
  private var directory: URL
  private var persistent = true
  private var maxBytes: Int64 = 256 << 20
  private var maxAge: TimeInterval = 7 * 24 * 3600
  let session: URLSession

  private init() {
    let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
    directory = caches.appendingPathComponent("EverythingPlayer/media", isDirectory: true)
    let config = URLSessionConfiguration.default
    config.requestCachePolicy = .reloadIgnoringLocalCacheData
    config.urlCache = nil
    session = URLSession(configuration: config)
  }

  func configure(maxSizeMB: Double, maxAgeSeconds: Double, persistent: Bool) {
    ioQueue.sync {
      self.persistent = persistent
      self.maxBytes = Int64(max(1, maxSizeMB) * 1024 * 1024)
      self.maxAge = maxAgeSeconds
      memory.totalCostLimit = Int(min(Int64(Int.max), persistent ? 8 << 20 : maxBytes))
      if !persistent { try? FileManager.default.removeItem(at: directory) }
      try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    trim()
  }

  private func key(_ url: URL) -> String {
    SHA256.hash(data: Data(url.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined()
  }

  private func folder(_ url: URL) -> URL {
    directory.appendingPathComponent(key(url), isDirectory: true)
  }

  func meta(for url: URL) -> EPCachedMeta? {
    ioQueue.sync {
      let mk = "\(key(url))/meta" as NSString
      if let data = memory.object(forKey: mk) { return try? JSONDecoder().decode(EPCachedMeta.self, from: data as Data) }
      guard persistent else { return nil }
      let file = folder(url).appendingPathComponent("meta.json")
      guard let data = try? Data(contentsOf: file), isFresh(file) else { return nil }
      return try? JSONDecoder().decode(EPCachedMeta.self, from: data)
    }
  }

  func store(meta: EPCachedMeta, for url: URL) {
    guard let data = try? JSONEncoder().encode(meta) else { return }
    ioQueue.async {
      self.memory.setObject(data as NSData, forKey: "\(self.key(url))/meta" as NSString, cost: data.count)
      guard self.persistent else { return }
      let dir = self.folder(url)
      try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
      try? data.write(to: dir.appendingPathComponent("meta.json"))
    }
  }

  func chunk(_ index: Int64, for url: URL) -> Data? {
    ioQueue.sync {
      let mk = "\(key(url))/\(index)" as NSString
      if let data = memory.object(forKey: mk) { return data as Data }
      guard persistent else { return nil }
      let file = folder(url).appendingPathComponent("\(index)")
      guard isFresh(file), let data = try? Data(contentsOf: file) else { return nil }
      try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: file.path)
      return data
    }
  }

  func store(chunk data: Data, index: Int64, for url: URL) {
    ioQueue.async {
      self.memory.setObject(data as NSData, forKey: "\(self.key(url))/\(index)" as NSString, cost: data.count)
      guard self.persistent else { return }
      let dir = self.folder(url)
      try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
      try? data.write(to: dir.appendingPathComponent("\(index)"))
    }
    trimSoon()
  }

  private func isFresh(_ file: URL) -> Bool {
    guard let attrs = try? FileManager.default.attributesOfItem(atPath: file.path),
          let date = attrs[.modificationDate] as? Date else { return false }
    return Date().timeIntervalSince(date) <= maxAge
  }

  private var trimScheduled = false

  private func trimSoon() {
    ioQueue.async {
      guard !self.trimScheduled else { return }
      self.trimScheduled = true
      self.ioQueue.asyncAfter(deadline: .now() + 10) {
        self.trimScheduled = false
        self.trimLocked()
      }
    }
  }

  func trim() {
    ioQueue.async { self.trimLocked() }
  }

  private func trimLocked() {
    guard persistent else { return }
    let fm = FileManager.default
    guard let enumerator = fm.enumerator(at: directory, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]) else { return }
    var files: [(URL, Int64, Date)] = []
    var total: Int64 = 0
    let now = Date()
    for case let file as URL in enumerator {
      guard let v = try? file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]),
            v.isRegularFile == true else { continue }
      let date = v.contentModificationDate ?? .distantPast
      if now.timeIntervalSince(date) > maxAge {
        try? fm.removeItem(at: file)
        continue
      }
      let size = Int64(v.fileSize ?? 0)
      total += size
      files.append((file, size, date))
    }
    guard total > maxBytes else { return }
    for (file, size, _) in files.sorted(by: { $0.2 < $1.2 }) where total > maxBytes {
      try? fm.removeItem(at: file)
      total -= size
    }
  }

  func fetchMeta(_ url: URL, headers: [String: String]) async throws -> EPCachedMeta {
    if let cached = meta(for: url) { return cached }
    var request = URLRequest(url: url)
    headers.forEach { request.setValue($1, forHTTPHeaderField: $0) }
    request.setValue("bytes=0-1", forHTTPHeaderField: "Range")
    let (_, response) = try await session.data(for: request)
    guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
      throw EPError(.networkError, "HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1) for \(url.absoluteString)")
    }
    var length = http.expectedContentLength
    if let range = http.value(forHTTPHeaderField: "Content-Range"), let total = range.split(separator: "/").last, let n = Int64(total) {
      length = n
    }
    let mime = http.mimeType ?? "application/octet-stream"
    let meta = EPCachedMeta(contentLength: length, contentType: Self.uti(mime: mime, url: url))
    if length > 0 { store(meta: meta, for: url) }
    return meta
  }

  func fetchChunk(_ index: Int64, url: URL, headers: [String: String], meta: EPCachedMeta) async throws -> Data {
    if let cached = chunk(index, for: url) { return cached }
    let start = index * Self.chunkSize
    let end = min(meta.contentLength, start + Self.chunkSize) - 1
    var request = URLRequest(url: url)
    headers.forEach { request.setValue($1, forHTTPHeaderField: $0) }
    request.setValue("bytes=\(start)-\(end)", forHTTPHeaderField: "Range")
    let (data, response) = try await session.data(for: request)
    guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
      throw EPError(.networkError, "HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1) for \(url.absoluteString)")
    }
    let body = http.statusCode == 200 && data.count > Int(end - start + 1)
      ? data.subdata(in: Int(start)..<min(data.count, Int(end) + 1))
      : data
    store(chunk: body, index: index, for: url)
    return body
  }

  func prefetch(_ url: URL, headers: [String: String], bytes: Int64) {
    Task.detached(priority: .utility) {
      guard let meta = try? await self.fetchMeta(url, headers: headers), meta.contentLength > 0 else { return }
      let last = min(meta.contentLength, bytes) / Self.chunkSize
      for index in 0...last {
        _ = try? await self.fetchChunk(index, url: url, headers: headers, meta: meta)
      }
    }
  }

  static func uti(mime: String, url: URL) -> String {
    let lower = mime.lowercased()
    let known: [String: String] = [
      "audio/mpeg": "public.mp3", "audio/mp3": "public.mp3", "audio/mp4": "public.mpeg-4-audio",
      "audio/m4a": "com.apple.m4a-audio", "audio/x-m4a": "com.apple.m4a-audio", "audio/aac": "public.aac-audio",
      "audio/wav": "com.microsoft.waveform-audio", "audio/x-wav": "com.microsoft.waveform-audio",
      "audio/flac": "org.xiph.flac", "video/mp4": "public.mpeg-4", "video/quicktime": "com.apple.quicktime-movie",
    ]
    if let id = known[lower] { return id }
    if lower != "application/octet-stream", let type = UTType(mimeType: lower) { return type.identifier }
    if let type = UTType(filenameExtension: url.pathExtension) { return type.identifier }
    return "public.mpeg-4"
  }
}
