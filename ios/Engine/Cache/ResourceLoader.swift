import AVFoundation

final class EPResourceLoader: NSObject, AVAssetResourceLoaderDelegate {
  static let schemePrefix = "rnep-"

  let originalURL: URL
  private let headers: [String: String]
  private let cache = EPMediaCache.shared
  private let lock = NSLock()
  private var tasks: [ObjectIdentifier: Task<Void, Never>] = [:]
  let queue = DispatchQueue(label: "everythingplayer.loader")

  var allowedEndOffset: ((_ contentLength: Int64) -> Int64)?

  init(url: URL, headers: [String: String]) {
    originalURL = url
    self.headers = headers
  }

  static func loaderURL(for url: URL) -> URL? {
    guard var c = URLComponents(url: url, resolvingAgainstBaseURL: false), let scheme = c.scheme else { return nil }
    c.scheme = schemePrefix + scheme
    return c.url
  }

  func cancelAll() {
    lock.lock()
    let all = tasks.values
    tasks.removeAll()
    lock.unlock()
    all.forEach { $0.cancel() }
  }

  func resourceLoader(_ resourceLoader: AVAssetResourceLoader, shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest) -> Bool {
    let id = ObjectIdentifier(loadingRequest)
    let task = Task.detached(priority: .userInitiated) { [weak self] in
      await self?.serve(loadingRequest)
      self?.lock.sync { self?.tasks[id] = nil }
    }
    lock.lock()
    tasks[id] = task
    lock.unlock()
    return true
  }

  func resourceLoader(_ resourceLoader: AVAssetResourceLoader, didCancel loadingRequest: AVAssetResourceLoadingRequest) {
    lock.lock()
    let task = tasks.removeValue(forKey: ObjectIdentifier(loadingRequest))
    lock.unlock()
    task?.cancel()
  }

  private func serve(_ request: AVAssetResourceLoadingRequest) async {
    do {
      let meta = try await cache.fetchMeta(originalURL, headers: headers)
      if let info = request.contentInformationRequest {
        info.contentType = meta.contentType
        info.contentLength = meta.contentLength
        info.isByteRangeAccessSupported = true
      }
      guard let dataRequest = request.dataRequest else {
        request.finishLoading()
        return
      }
      let startOffset = dataRequest.currentOffset
      var offset = startOffset
      let end = dataRequest.requestsAllDataToEndOfResource
        ? meta.contentLength
        : min(meta.contentLength, dataRequest.requestedOffset + Int64(dataRequest.requestedLength))
      let burst: Int64 = 1 << 20
      while offset < end {
        try Task.checkCancellation()
        let chunkIndex = offset / EPMediaCache.chunkSize
        let chunkStart = chunkIndex * EPMediaCache.chunkSize
        while let allowed = allowedEndOffset?(meta.contentLength), chunkStart > max(allowed, startOffset + burst) {
          try Task.checkCancellation()
          try await Task.sleep(nanoseconds: 250_000_000)
        }
        let data = try await cache.fetchChunk(chunkIndex, url: originalURL, headers: headers, meta: meta)
        let from = Int(offset - chunkStart)
        guard from < data.count else { break }
        let to = Int(min(Int64(data.count), end - chunkStart))
        try Task.checkCancellation()
        dataRequest.respond(with: data.subdata(in: from..<to))
        offset = chunkStart + Int64(to)
      }
      request.finishLoading()
    } catch is CancellationError {
      return
    } catch {
      if !request.isCancelled { request.finishLoading(with: error) }
    }
  }
}
