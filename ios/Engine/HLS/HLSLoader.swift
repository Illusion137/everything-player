import CommonCrypto
import Foundation

final class EPHLSLoader: @unchecked Sendable {
  private let headers: [String: String]
  private let session: URLSession
  private let lock = NSLock()
  private var keys: [URL: Data] = [:]
  private var bandwidth: Double = 0

  init(headers: [String: String]) {
    self.headers = headers
    let config = URLSessionConfiguration.default
    config.requestCachePolicy = .reloadIgnoringLocalCacheData
    config.urlCache = nil
    config.timeoutIntervalForRequest = 20
    session = URLSession(configuration: config)
  }

  deinit { session.invalidateAndCancel() }

  var bandwidthEstimate: Double { lock.sync { bandwidth } }

  func fetch(_ url: URL, range: EPHLSByteRange? = nil, measure: Bool = false) async throws -> Data {
    if url.isFileURL {
      let data = try Data(contentsOf: url, options: .mappedIfSafe)
      guard let range else { return data }
      let end = min(data.count, range.offset + range.length)
      guard range.offset < end else { return Data() }
      return data.subdata(in: range.offset..<end)
    }
    var lastError: Error?
    for attempt in 0..<3 {
      try Task.checkCancellation()
      if attempt > 0 { try await Task.sleep(nanoseconds: UInt64(attempt) * 500_000_000) }
      var request = URLRequest(url: url)
      for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }
      if let range { request.setValue("bytes=\(range.offset)-\(range.offset + range.length - 1)", forHTTPHeaderField: "Range") }
      let started = CFAbsoluteTimeGetCurrent()
      do {
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
          lastError = EPError(.networkError, "HTTP \(http.statusCode) for \(url.lastPathComponent)")
          if http.statusCode >= 400 && http.statusCode < 500 { break }
          continue
        }
        if measure { record(bytes: data.count, seconds: CFAbsoluteTimeGetCurrent() - started) }
        if let range, (response as? HTTPURLResponse)?.statusCode == 200, data.count > range.length {
          let end = min(data.count, range.offset + range.length)
          return data.subdata(in: range.offset..<end)
        }
        return data
      } catch is CancellationError {
        throw CancellationError()
      } catch {
        if (error as NSError).code == NSURLErrorCancelled { throw CancellationError() }
        lastError = error
      }
    }
    throw EPError.from(lastError ?? EPError(.networkError, "Request failed"), default: .networkError)
  }

  func text(_ url: URL) async throws -> String {
    let data = try await fetch(url)
    guard let s = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
      throw EPError(.sourceError, "Playlist is not text")
    }
    return s
  }

  func segmentData(_ segment: EPHLSSegment) async throws -> Data {
    let data = try await fetch(segment.uri, range: segment.range, measure: true)
    return try await decrypt(data, key: segment.key, sequence: segment.sequence)
  }

  func mapData(_ map: EPHLSMap, key: EPHLSKey?, sequence: Int) async throws -> Data {
    let data = try await fetch(map.uri, range: map.range)
    return try await decrypt(data, key: key, sequence: sequence)
  }

  private func record(bytes: Int, seconds: Double) {
    guard bytes > 32 * 1024, seconds > 0.01 else { return }
    let bps = Double(bytes * 8) / seconds
    lock.sync { bandwidth = bandwidth == 0 ? bps : bandwidth * 0.7 + bps * 0.3 }
  }

  private func decrypt(_ data: Data, key: EPHLSKey?, sequence: Int) async throws -> Data {
    guard let key, key.method == .aes128 else { return data }
    guard let uri = key.uri else { throw EPError(.sourceError, "AES-128 key without URI") }
    let keyData: Data
    if let cached = lock.sync({ keys[uri] }) {
      keyData = cached
    } else {
      keyData = try await fetch(uri)
      lock.sync { keys[uri] = keyData }
    }
    guard keyData.count == kCCKeySizeAES128 else { throw EPError(.sourceError, "Invalid AES-128 key") }
    var iv = key.iv ?? Data(count: 16)
    if key.iv == nil {
      var seq = UInt64(sequence).bigEndian
      iv.replaceSubrange(8..<16, with: Data(bytes: &seq, count: 8))
    }
    var out = Data(count: data.count + kCCBlockSizeAES128)
    var written = 0
    let outCapacity = out.count
    let status = out.withUnsafeMutableBytes { outRaw in
      data.withUnsafeBytes { inRaw in
        keyData.withUnsafeBytes { keyRaw in
          iv.withUnsafeBytes { ivRaw in
            CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                    keyRaw.baseAddress, keyData.count, ivRaw.baseAddress,
                    inRaw.baseAddress, data.count, outRaw.baseAddress, outCapacity, &written)
          }
        }
      }
    }
    guard status == kCCSuccess else { throw EPError(.decodeError, "AES-128 decrypt failed (\(status))") }
    out.count = written
    return out
  }
}
