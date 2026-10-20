import Foundation

protocol EPSabrSessionOwner: AnyObject {
  func session(_ session: EPSabrSession, didReload serverAbrStreamingUrl: String, config: String)
  func session(_ session: EPSabrSession, didMint token: Data)
  func session(_ session: EPSabrSession, callbackFailed error: EPError)
  func session(_ session: EPSabrSession, streamFailed error: Error)
}

final class EPSabrSession: @unchecked Sendable {
  let trackId: String
  let audioItag: Int
  let videoItag: Int?
  let created = Date()
  private(set) var stream: SabrStream!
  private let lock = NSLock()
  private weak var ownerRef: EPSabrSessionOwner?
  private var failed = false

  init(track: EPTrack, info: EPSabrInfo, poToken: String, options: EPSetupOptions, provider: EPSabrCallbackProvider?, audioItag: Int, videoItag: Int?) {
    trackId = track.id
    self.audioItag = audioItag
    self.videoItag = videoItag
    let trackId = track.id
    let timeout = options.sabrCallbackTimeoutMs
    let callbacks = SabrStreamCallbacks(
      onReloadPlayerResponse: { [weak self, weak provider] context in
        guard let provider else { throw EPError(.sabrCallbackFailed, "No SABR callback provider") }
        do {
          let token = context?.reloadPlaybackParams.token
          let response = try await epWithTimeout(timeout, "onReloadPlayerResponse") {
            try await provider.reloadPlayerResponse(trackId: trackId, token: token)
          }
          if let self { self.owner?.session(self, didReload: response.serverAbrStreamingUrl, config: response.videoPlaybackUstreamerConfig) }
          return ReloadResponse(serverAbrStreamingUrl: response.serverAbrStreamingUrl, videoPlaybackUstreamerConfig: response.videoPlaybackUstreamerConfig)
        } catch {
          self?.callbackFailed(error)
          throw error
        }
      },
      onMintPoToken: { [weak self, weak provider] in
        guard let provider else { throw EPError(.sabrCallbackFailed, "No SABR callback provider") }
        do {
          let token = try await epWithTimeout(timeout, "onMintPoToken") {
            try await provider.mintPoToken(trackId: trackId)
          }
          if let self { self.owner?.session(self, didMint: token) }
          return token
        } catch {
          self?.callbackFailed(error)
          throw error
        }
      })
    stream = SabrStream(SabrStreamConfig(
      videoId: info.videoId,
      fetchFunction: EPSabr.fetchFunction(headers: track.requestHeaders),
      serverAbrStreamingUrl: info.serverAbrStreamingUrl,
      videoPlaybackUstreamerConfig: info.videoPlaybackUstreamerConfig,
      poToken: poToken,
      clientInfo: EPSabr.clientInfo(info),
      formats: info.formats.map(EPSabr.googleFormat),
      callbacks: callbacks,
      stripDuplicateInit: true,
      videoHighWaterMark: max(1 << 20, options.maxBufferBytes),
      audioHighWaterMark: max(512 << 10, min(3 << 20, options.maxBufferBytes / 4))))
    stream.on(.error) { [weak self] (error: any Error) in
      guard let self else { return }
      self.lock.sync { self.failed = true }
      self.owner?.session(self, streamFailed: error)
    }
  }

  var owner: EPSabrSessionOwner? {
    get { lock.sync { ownerRef } }
    set { lock.sync { ownerRef = newValue } }
  }

  var isUsable: Bool {
    !lock.sync { failed } && !stream.isAborted && !stream.isErrored
  }

  var age: TimeInterval { Date().timeIntervalSince(created) }

  func start(at seconds: Double) throws -> StreamStartResult {
    try stream.start(playbackOptions(at: seconds))
  }

  func warm(at seconds: Double) throws {
    try stream.warm(playbackOptions(at: seconds))
  }

  func abort() {
    let s = stream
    Task { await s?.abort() }
  }

  private func playbackOptions(at seconds: Double) -> SabrPlaybackOptions {
    SabrPlaybackOptions(
      videoFormat: videoItag.map { .itag($0) },
      audioFormat: .itag(audioItag),
      enabledTrackTypes: videoItag == nil ? .audioOnly : .videoAndAudio,
      startTimeMs: Int(seconds * 1000),
      isPostLiveDvr: false)
  }

  private func callbackFailed(_ error: Error) {
    lock.sync { failed = true }
    let message = (error as? EPError)?.message ?? String(describing: error)
    owner?.session(self, callbackFailed: EPError(.sabrCallbackFailed, message))
  }
}

final class EPSabrWarmPool: @unchecked Sendable {
  static let maxAge: TimeInterval = 240

  private let lock = NSLock()
  private let queue = DispatchQueue(label: "everythingplayer.sabr.warm", qos: .utility)
  private var entries: [String: EPSabrSession] = [:]

  static func itags(_ info: EPSabrInfo, options: EPSetupOptions) -> (audio: Int, video: Int?)? {
    guard let audio = EPSabr.pickAudio(info.formats) else { return nil }
    let video = options.enableVideo ? EPSabr.pickVideo(info.formats, range: options.videoQualityRange)?.itag : nil
    return (audio.itag, video)
  }

  func warm(_ tracks: [EPTrack], options: EPSetupOptions, provider: EPSabrCallbackProvider?) {
    queue.async { [weak self, weak provider] in self?.warmNow(tracks, options: options, provider: provider) }
  }

  private func warmNow(_ tracks: [EPTrack], options: EPSetupOptions, provider: EPSabrCallbackProvider?) {
    var stale: [EPSabrSession] = []
    var keep = Set<String>()
    for track in tracks {
      guard let info = track.sabr, let itags = Self.itags(info, options: options) else { continue }
      keep.insert(track.id)
      let existing = lock.sync { entries[track.id] }
      if let existing, existing.isUsable, existing.age < Self.maxAge,
         existing.audioItag == itags.audio, existing.videoItag == itags.video { continue }
      let session = EPSabrSession(
        track: track, info: info, poToken: info.poToken, options: options, provider: provider,
        audioItag: itags.audio, videoItag: itags.video)
      guard (try? session.warm(at: track.trimStart)) != nil else { continue }
      lock.sync { entries[track.id] = session }
      if let existing { stale.append(existing) }
    }
    lock.sync {
      for (id, session) in entries where !keep.contains(id) {
        stale.append(session)
        entries[id] = nil
      }
    }
    stale.forEach { $0.abort() }
  }

  func take(_ trackId: String, audioItag: Int, videoItag: Int?) -> EPSabrSession? {
    guard let session = lock.sync({ entries.removeValue(forKey: trackId) }) else { return nil }
    guard session.isUsable, session.age < Self.maxAge, session.audioItag == audioItag, session.videoItag == videoItag else {
      session.abort()
      return nil
    }
    return session
  }

  func clear() {
    let all = lock.sync { () -> [EPSabrSession] in
      let all = Array(entries.values)
      entries.removeAll()
      return all
    }
    all.forEach { $0.abort() }
  }
}
