import AVFoundation

enum EPDownloadState: String, Codable {
  case queued, downloading, paused, completed, failed, cancelled
}

struct EPDownloadRecord: Codable {
  var trackId: String
  var track: EPTrack
  var state: EPDownloadState
  var progress: Double = 0
  var bytesDownloaded: Int64 = 0
  var totalBytes: Int64?
  var audioPath: String?
  var videoPath: String?
  var audioIsOpus: Bool?
  var includeVideo: Bool = false
  var videoQuality: EPVideoQualityRange?
  var errorCode: String?
  var errorMessage: String?

  var isLive: Bool { state == .queued || state == .downloading || state == .paused }
}

final class EPDownloads: NSObject, URLSessionDownloadDelegate {
  static let shared = EPDownloads()

  var onChanged: ((EPDownloadRecord) -> Void)?

  private let lock = NSRecursiveLock()
  private var records: [String: EPDownloadRecord] = [:]
  private var loaded = false
  private var rawTasks: [String: URLSessionDownloadTask] = [:]
  private var streamTasks: [String: Task<Void, Never>] = [:]
  private var resumeData: [String: Data] = [:]
  private lazy var rawSession = URLSession(configuration: .default, delegate: self, delegateQueue: nil)

  let directory: URL = {
    let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    let dir = base.appendingPathComponent("EverythingPlayer/downloads", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    var values = URLResourceValues()
    values.isExcludedFromBackup = true
    var mutable = dir
    try? mutable.setResourceValues(values)
    return dir
  }()

  private var indexURL: URL { directory.appendingPathComponent("index.json") }

  private func ensureLoaded() {
    lock.lock(); defer { lock.unlock() }
    guard !loaded else { return }
    loaded = true
    guard let data = try? Data(contentsOf: indexURL),
          let decoded = try? JSONDecoder().decode([String: EPDownloadRecord].self, from: data) else { return }
    records = decoded.mapValues { r in
      var r = r
      if r.state == .downloading || r.state == .queued { r.state = .paused }
      return r
    }
  }

  private func persist() {
    lock.lock()
    let snapshot = records
    lock.unlock()
    guard let data = try? JSONEncoder().encode(snapshot) else { return }
    try? data.write(to: indexURL, options: .atomic)
  }

  private func mutate(_ trackId: String, notify: Bool = true, _ body: (inout EPDownloadRecord) -> Void) {
    lock.lock()
    guard var record = records[trackId] else { lock.unlock(); return }
    body(&record)
    records[trackId] = record
    lock.unlock()
    if notify {
      persist()
      onChanged?(record)
    }
  }

  func record(_ trackId: String) -> EPDownloadRecord? {
    ensureLoaded()
    lock.lock(); defer { lock.unlock() }
    return records[trackId]
  }

  func all() -> [EPDownloadRecord] {
    ensureLoaded()
    lock.lock(); defer { lock.unlock() }
    return Array(records.values)
  }

  func localMedia(for track: EPTrack) -> EPLocalMedia? {
    guard let r = record(track.id), r.state == .completed, let audioPath = r.audioPath else { return nil }
    let audioURL = resolve(audioPath)
    guard FileManager.default.fileExists(atPath: audioURL.path) else { return nil }
    if track.sabr != nil {
      return .sabr(EPLocalSabrMedia(audioURL: audioURL, audioIsOpus: r.audioIsOpus ?? true, videoURL: r.videoPath.map(resolve)))
    }
    return .file(audioURL)
  }

  private func resolve(_ path: String) -> URL {
    if path.hasPrefix("/") { return URL(fileURLWithPath: path) }
    if path.hasPrefix("~/") { return URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(String(path.dropFirst(2))) }
    return directory.appendingPathComponent(path)
  }

  private func fileName(_ trackId: String, _ suffix: String) -> String {
    let safe = trackId.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" ? $0 : "_" }
    return String(safe) + suffix
  }

  func download(_ track: EPTrack, includeVideo: Bool, videoQuality: EPVideoQualityRange) throws -> EPDownloadRecord {
    ensureLoaded()
    if let existing = record(track.id), existing.state == .completed || existing.state == .downloading || existing.state == .queued {
      return existing
    }
    var record = EPDownloadRecord(trackId: track.id, track: track, state: .queued)
    record.includeVideo = includeVideo
    record.videoQuality = videoQuality
    lock.lock()
    records[track.id] = record
    lock.unlock()
    persist()
    onChanged?(record)
    try start(track.id)
    return self.record(track.id) ?? record
  }

  private func start(_ trackId: String) throws {
    guard let r = record(trackId) else { return }
    let track = r.track
    switch track.sourceType {
    case .raw: try startRaw(track)
    case .hls: startHLS(track, includeVideo: r.includeVideo, range: r.videoQuality ?? EPPlayerEngine.shared.getVideoQualityRange())
    case .sabr: startSabr(track, includeVideo: r.includeVideo, range: r.videoQuality ?? EPPlayerEngine.shared.getVideoQualityRange())
    }
    mutate(trackId) { $0.state = .downloading; $0.errorCode = nil; $0.errorMessage = nil }
  }

  func pause(_ trackId: String) {
    lock.lock()
    let raw = rawTasks[trackId]
    let stream = streamTasks.removeValue(forKey: trackId)
    lock.unlock()
    if let raw {
      raw.cancel { [weak self] data in
        guard let self else { return }
        self.lock.lock()
        self.resumeData[trackId] = data
        self.rawTasks[trackId] = nil
        self.lock.unlock()
      }
    }
    stream?.cancel()
    mutate(trackId) { if $0.isLive { $0.state = .paused } }
  }

  func resume(_ trackId: String) {
    guard let r = record(trackId), r.state == .paused || r.state == .failed || r.state == .cancelled else { return }
    do { try start(trackId) } catch { fail(trackId, EPError.from(error, default: .sourceError)) }
  }

  func cancel(_ trackId: String) {
    lock.lock()
    let raw = rawTasks.removeValue(forKey: trackId)
    let stream = streamTasks.removeValue(forKey: trackId)
    resumeData[trackId] = nil
    lock.unlock()
    raw?.cancel()
    stream?.cancel()
    mutate(trackId) { if $0.state != .completed { $0.state = .cancelled } }
  }

  func remove(_ trackId: String) {
    cancel(trackId)
    lock.lock()
    let r = records.removeValue(forKey: trackId)
    lock.unlock()
    if let r {
      [r.audioPath, r.videoPath].compactMap { $0 }.forEach { path in
        let url = resolve(path)
        let parent = url.deletingLastPathComponent()
        try? FileManager.default.removeItem(at: parent.pathExtension == "hls" ? parent : url)
      }
      try? FileManager.default.removeItem(at: directory.appendingPathComponent(fileName(trackId, ".hls")))
    }
    persist()
  }

  func removeAll() {
    all().forEach { remove($0.trackId) }
  }

  private func fail(_ trackId: String, _ error: EPError) {
    mutate(trackId) {
      $0.state = .failed
      $0.errorCode = error.code.rawValue
      $0.errorMessage = error.message
    }
  }

  private func startRaw(_ track: EPTrack) throws {
    guard let raw = track.url, let url = URL(string: raw) else { throw EPError(.sourceError, "Invalid URL") }
    lock.lock()
    let data = resumeData.removeValue(forKey: track.id)
    lock.unlock()
    let task: URLSessionDownloadTask
    if let data {
      task = rawSession.downloadTask(withResumeData: data)
    } else {
      var request = URLRequest(url: url)
      track.requestHeaders.forEach { request.setValue($1, forHTTPHeaderField: $0) }
      task = rawSession.downloadTask(with: request)
    }
    task.taskDescription = track.id
    lock.lock()
    rawTasks[track.id] = task
    lock.unlock()
    task.resume()
  }

  func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
    guard let id = downloadTask.taskDescription else { return }
    mutate(id) {
      $0.bytesDownloaded = totalBytesWritten
      $0.totalBytes = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : nil
      $0.progress = totalBytesExpectedToWrite > 0 ? Double(totalBytesWritten) / Double(totalBytesExpectedToWrite) : 0
    }
  }

  func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
    guard let id = downloadTask.taskDescription else { return }
    if let http = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
      fail(id, EPError(.networkError, "HTTP \(http.statusCode)"))
      return
    }
    let ext = downloadTask.response?.suggestedFilename.flatMap { URL(fileURLWithPath: $0).pathExtension }
      ?? downloadTask.originalRequest?.url?.pathExtension ?? "m4a"
    let name = fileName(id, "." + (ext.isEmpty ? "m4a" : ext))
    let dest = directory.appendingPathComponent(name)
    try? FileManager.default.removeItem(at: dest)
    do {
      try FileManager.default.moveItem(at: location, to: dest)
      mutate(id) {
        $0.audioPath = name
        $0.state = .completed
        $0.progress = 1
      }
    } catch {
      fail(id, EPError.from(error, default: .sourceError))
    }
    lock.lock(); rawTasks[id] = nil; lock.unlock()
  }

  func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
    guard let id = task.taskDescription else { return }
    if let error {
      let ns = error as NSError
      if ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled { return }
      fail(id, EPError.from(error, default: .networkError))
    }
    lock.lock(); rawTasks[id] = nil; lock.unlock()
  }

  private func startHLS(_ track: EPTrack, includeVideo: Bool, range: EPVideoQualityRange) {
    let id = track.id
    let folderName = fileName(id, ".hls")
    let folder = directory.appendingPathComponent(folderName, isDirectory: true)
    runStreamTask(id) {
      let master = try await EPHLSDownloader.download(track: track, includeVideo: includeVideo, range: range, folder: folder) { p in
        self.mutate(id) {
          $0.bytesDownloaded = p.bytes
          $0.totalBytes = nil
          $0.progress = p.segmentsTotal > 0 ? min(0.99, Double(p.segmentsDone) / Double(p.segmentsTotal)) : 0
        }
      }
      self.mutate(id) {
        $0.audioPath = folderName + "/" + master
        $0.videoPath = nil
        $0.totalBytes = $0.bytesDownloaded
        $0.state = .completed
        $0.progress = 1
      }
    }
  }

  private func runStreamTask(_ id: String, _ body: @escaping () async throws -> Void) {
    let task = Task.detached(priority: .utility) { [weak self] in
      guard let self else { return }
      do {
        try await body()
      } catch is CancellationError {
      } catch {
        if !Task.isCancelled { self.fail(id, EPError.from(error, default: .sourceError)) }
      }
      self.lock.sync { self.streamTasks[id] = nil }
    }
    lock.lock()
    streamTasks[id] = task
    lock.unlock()
  }

  private func startSabr(_ track: EPTrack, includeVideo: Bool, range: EPVideoQualityRange) {
    guard let sabr = track.sabr else { return }
    let timeout = EPPlayerEngine.shared.setupOptions.sabrCallbackTimeoutMs
    runStreamTask(track.id) {
      try await self.runSabr(track: track, sabr: sabr, includeVideo: includeVideo, range: range, timeoutMs: timeout)
    }
  }

  private func runSabr(track: EPTrack, sabr: EPSabrInfo, includeVideo: Bool, range: EPVideoQualityRange, timeoutMs: Double) async throws {
    guard let audio = EPSabr.pickAudio(sabr.formats) else {
      throw EPError(.sabrStreamFailed, "No downloadable audio format")
    }
    let video = includeVideo ? EPSabr.pickVideo(sabr.formats, range: range) : nil
    let id = track.id
    let provider = EPPlayerEngine.shared.sabrCallbacks
    let callbackFailure = EPErrorBox()
    let callbacks = SabrStreamCallbacks(
      onReloadPlayerResponse: { context in
        guard let provider else { throw EPError(.sabrCallbackFailed, "No SABR callback provider") }
        do {
          let r = try await epWithTimeout(timeoutMs, "onReloadPlayerResponse") {
            try await provider.reloadPlayerResponse(trackId: id, token: context?.reloadPlaybackParams.token)
          }
          return ReloadResponse(serverAbrStreamingUrl: r.serverAbrStreamingUrl, videoPlaybackUstreamerConfig: r.videoPlaybackUstreamerConfig)
        } catch {
          callbackFailure.set(EPError(.sabrCallbackFailed, String(describing: error)))
          throw error
        }
      },
      onMintPoToken: {
        guard let provider else { throw EPError(.sabrCallbackFailed, "No SABR callback provider") }
        do {
          return try await epWithTimeout(timeoutMs, "onMintPoToken") { try await provider.mintPoToken(trackId: id) }
        } catch {
          callbackFailure.set(EPError(.sabrCallbackFailed, String(describing: error)))
          throw error
        }
      })
    let stream = SabrStream(SabrStreamConfig(
      videoId: sabr.videoId,
      fetchFunction: EPSabr.fetchFunction(headers: track.requestHeaders),
      serverAbrStreamingUrl: sabr.serverAbrStreamingUrl,
      videoPlaybackUstreamerConfig: sabr.videoPlaybackUstreamerConfig,
      poToken: sabr.poToken,
      clientInfo: EPSabr.clientInfo(sabr),
      formats: sabr.formats.map(EPSabr.googleFormat),
      callbacks: callbacks,
      stripDuplicateInit: true))
    let result = try stream.start(SabrPlaybackOptions(
      videoFormat: video.map { .itag($0.itag) },
      audioFormat: .itag(audio.itag),
      enabledTrackTypes: video == nil ? .audioOnly : .videoAndAudio,
      startTimeMs: 0,
      isPostLiveDvr: false))

    let isOpus = EPSabr.isOpus(audio)
    let audioName = fileName(id, isOpus ? ".webm" : ".m4a")
    let videoName = video.map { _ in fileName(id, ".video.mp4") }
    let audioPart = directory.appendingPathComponent(audioName + ".part")
    let videoPart = videoName.map { directory.appendingPathComponent($0 + ".part") }
    let expected = Int64((audio.contentLength ?? 0) + (video?.contentLength ?? 0))
    let counter = EPByteCounter()

    try await withTaskCancellationHandler {
      try await withThrowingTaskGroup(of: Void.self) { group in
        group.addTask {
          try await Self.drain(EPSabr.streamReader(result.audioStream), to: audioPart, counter: counter) { total in
            self.reportSabrProgress(id, total, expected)
          }
        }
        if let videoPart {
          group.addTask {
            try await Self.drain(EPSabr.streamReader(result.videoStream), to: videoPart, counter: counter) { total in
              self.reportSabrProgress(id, total, expected)
            }
          }
        }
        do {
          try await group.waitForAll()
          await stream.abort()
        } catch {
          await stream.abort()
          throw callbackFailure.get() ?? error
        }
      }
    } onCancel: {
      Task { await stream.abort() }
    }
    try Task.checkCancellation()

    let fm = FileManager.default
    let audioDest = directory.appendingPathComponent(audioName)
    try? fm.removeItem(at: audioDest)
    try fm.moveItem(at: audioPart, to: audioDest)
    if let videoPart, let videoName {
      let videoDest = directory.appendingPathComponent(videoName)
      try? fm.removeItem(at: videoDest)
      try fm.moveItem(at: videoPart, to: videoDest)
    }
    let total = counter.add(0)
    mutate(id) {
      $0.bytesDownloaded = total
      $0.totalBytes = total
      $0.audioPath = audioName
      $0.videoPath = videoName
      $0.audioIsOpus = isOpus
      $0.state = .completed
      $0.progress = 1
    }
  }

  private func reportSabrProgress(_ id: String, _ total: Int64, _ expected: Int64) {
    mutate(id) {
      $0.bytesDownloaded = total
      $0.totalBytes = expected > 0 ? expected : nil
      $0.progress = expected > 0 ? min(0.99, Double(total) / Double(expected)) : 0
    }
  }

  private static func drain(_ reader: EPChunkReader, to file: URL, counter: EPByteCounter, progress: (Int64) -> Void) async throws {
    FileManager.default.createFile(atPath: file.path, contents: nil)
    let handle = try FileHandle(forWritingTo: file)
    defer { try? handle.close() }
    var lastReport = Date.distantPast
    while let chunk = try await reader() {
      try Task.checkCancellation()
      try handle.write(contentsOf: chunk)
      let total = counter.add(Int64(chunk.count))
      if Date().timeIntervalSince(lastReport) > 0.5 {
        lastReport = Date()
        progress(total)
      }
    }
  }
}

final class EPByteCounter: @unchecked Sendable {
  private let lock = NSLock()
  private var value: Int64 = 0

  func add(_ n: Int64) -> Int64 {
    lock.lock(); defer { lock.unlock() }
    value += n
    return value
  }
}

final class EPErrorBox: @unchecked Sendable {
  private let lock = NSLock()
  private var error: EPError?

  func set(_ e: EPError) {
    lock.lock(); defer { lock.unlock() }
    if error == nil { error = e }
  }

  func get() -> EPError? {
    lock.lock(); defer { lock.unlock() }
    return error
  }
}
