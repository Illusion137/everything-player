import Foundation
import NitroModules

final class HybridEverythingPlayer: HybridEverythingPlayerSpec {
  private let engine = EPPlayerEngine.shared

  override init() {
    super.init()
    engine.localMediaResolver = { EPDownloads.shared.localMedia(for: $0) }
  }

  func isSetup() throws -> Bool { engine.isSetup }

  func setupPlayer(options: NativeSetupOptions) throws -> Promise<Void> {
    var o = EPSetupOptions()
    o.cacheMaxSizeMB = options.cacheConfig.maxSizeMB
    o.cacheMaxAgeSeconds = options.cacheConfig.maxAgeSeconds
    o.preloadNext = Int(options.cacheConfig.preloadNext)
    o.persistentCache = options.cacheConfig.persistent
    o.forwardBufferSeconds = max(1, options.bufferConfig.forwardBufferSeconds)
    o.maxBufferBytes = Int(max(256 * 1024, options.bufferConfig.maxBufferBytes))
    o.enableVideo = options.enableVideo
    o.autoHandleRemoteEvents = options.autoHandleRemoteEvents
    o.autoHandleInterruptions = options.autoHandleInterruptions
    o.sabrCallbackTimeoutMs = options.sabrCallbackTimeoutMs
    o.sabrPoolAhead = Int(options.sabrPoolAhead)
    o.videoQualityRange = EPVideoQualityRange(native: options.videoQuality)
    engine.setup(o)
    return Promise.resolved()
  }

  func updateOptions(options: NativeUpdateOptions) throws -> Promise<Void> {
    engine.update(EPUpdateOptions(
      capabilities: options.capabilities.map(\.stringValue),
      progressUpdateEventInterval: options.progressUpdateEventInterval,
      forwardJumpInterval: options.forwardJumpInterval,
      backwardJumpInterval: options.backwardJumpInterval))
    return Promise.resolved()
  }

  func setRepeatMode(mode: NativeRepeatMode) throws {
    engine.setRepeatMode(EPRepeatMode(rawValue: mode.stringValue) ?? .off)
  }

  func getRepeatMode() throws -> NativeRepeatMode {
    NativeRepeatMode(fromString: engine.getRepeatMode().rawValue) ?? .off
  }

  func setEqualizer(bands: [Double]) throws { engine.setEqualizer(bands.map { Float($0) }) }
  func getEqualizer() throws -> [Double] { EPEqualizerSettings.shared.bands.map(Double.init) }
  func setCrossFade(seconds: Double) throws { engine.setCrossFade(seconds) }
  func setVolume(volume: Double) throws { engine.setVolume(Float(volume)) }
  func getVolume() throws -> Double { Double(engine.getVolume()) }
  func setRate(rate: Double) throws { engine.setRate(Float(rate)) }
  func getRate() throws -> Double { Double(engine.getRate()) }

  func getVideoQualities() throws -> NativeVideoQualityState {
    engine.getVideoQuality().native(trackId: engine.activeTrackId)
  }

  func setVideoQuality(id: String?) throws { try engine.setVideoQuality(id) }
  func setVideoQualityRange(range: NativeVideoQualityRange) throws { engine.setVideoQualityRange(EPVideoQualityRange(native: range)) }
  func getVideoQualityRange() throws -> NativeVideoQualityRange { engine.getVideoQualityRange().native }

  func setOnVideoQualityChanged(callback: @escaping (NativeVideoQualityState) -> Void) throws {
    engine.onVideoQualityChanged = { state, trackId in callback(state.native(trackId: trackId)) }
  }

  func add(tracks: [NativeTrack], insertBeforeIndex: Double?) throws {
    engine.add(tracks.map(EPTrack.init(native:)), before: insertBeforeIndex.map { Int($0) })
  }

  func remove(indexes: [Double]) throws { engine.remove(indexes.map { Int($0) }) }
  func move(fromIndex: Double, toIndex: Double) throws { engine.move(from: Int(fromIndex), to: Int(toIndex)) }
  func setQueue(tracks: [NativeTrack]) throws { engine.setQueue(tracks.map(EPTrack.init(native:))) }

  func updateMetadataForTrack(index: Double, track: NativeTrack) throws {
    engine.updateMetadata(index: Int(index), track: EPTrack(native: track))
  }

  func getQueue() throws -> [NativeTrack] { engine.getQueue().map(\.native) }
  func getActiveTrackIndex() throws -> Double? { engine.getActiveIndex().map(Double.init) }

  func skip(index: Double, initialPosition: Double?) throws -> Promise<Void> {
    try engine.skip(to: Int(index), initialPosition: initialPosition)
    return Promise.resolved()
  }

  func skipToNext(initialPosition: Double?) throws -> Promise<Void> {
    try engine.skipToNext(initialPosition: initialPosition)
    return Promise.resolved()
  }

  func skipToPrevious(initialPosition: Double?) throws -> Promise<Void> {
    try engine.skipToPrevious(initialPosition: initialPosition)
    return Promise.resolved()
  }

  func removeUpcomingTracks() throws { engine.removeUpcoming() }
  func play() throws { engine.play() }
  func pause() throws { engine.pause() }
  func stop() throws { engine.stop() }
  func reset() throws { engine.reset() }
  func seekTo(seconds: Double) throws { engine.seekTo(seconds) }
  func seekBy(offset: Double) throws { engine.seekBy(offset) }
  func retry() throws { engine.retry() }

  func getProgress() throws -> NativeProgress {
    let p = engine.getProgress()
    return NativeProgress(position: p.position, duration: p.duration, buffered: p.buffered)
  }

  func getPlaybackState() throws -> NativePlaybackStateEvent {
    let state = engine.getState()
    return NativePlaybackStateEvent(
      state: NativeState(fromString: state.rawValue) ?? .none,
      error: state == .error ? engine.getLastError()?.native : nil)
  }

  func getSourceType(index: Double) throws -> NativeSourceType? {
    let queue = engine.getQueue()
    let i = Int(index)
    guard i >= 0, i < queue.count else { return nil }
    return NativeSourceType(fromString: queue[i].sourceType.rawValue)
  }

  func setOnPlaybackState(callback: @escaping (NativePlaybackStateEvent) -> Void) throws {
    engine.onStateChange = { state, error in
      callback(NativePlaybackStateEvent(state: NativeState(fromString: state.rawValue) ?? .none, error: error?.native))
    }
  }

  func setOnActiveTrackChanged(callback: @escaping (NativeActiveTrackChangedEvent) -> Void) throws {
    engine.onActiveTrackChanged = { c in
      callback(NativeActiveTrackChangedEvent(
        lastIndex: c.lastIndex.map(Double.init), lastTrackId: c.lastTrackId, lastPosition: c.lastPosition,
        index: c.index.map(Double.init), trackId: c.trackId))
    }
  }

  func setOnProgress(callback: @escaping (NativeProgressEvent) -> Void) throws {
    engine.onProgress = { p, index, id in
      callback(NativeProgressEvent(position: p.position, duration: p.duration, buffered: p.buffered, trackIndex: index.map(Double.init), trackId: id))
    }
  }

  func setOnPlaybackError(callback: @escaping (NativePlaybackError) -> Void) throws {
    engine.onError = { callback($0.native) }
  }

  func setOnQueueEnded(callback: @escaping (NativeQueueEndedEvent) -> Void) throws {
    engine.onQueueEnded = { index, id, position in
      callback(NativeQueueEndedEvent(trackIndex: index.map(Double.init), trackId: id, position: position))
    }
  }

  func setOnRemoteEvent(callback: @escaping (NativeRemoteEvent) -> Void) throws {
    engine.onRemote = { callback($0.native) }
  }

  func setSabrCallbacks(
    onMintPoToken: @escaping (String) -> Promise<Promise<String>>,
    onReloadPlayerResponse: @escaping (String, NativeReloadPlaybackContext) -> Promise<Promise<NativeReloadPlayerResponse>>
  ) throws {
    engine.sabrCallbacks = EPJSSabrCallbacks(mint: onMintPoToken, reload: onReloadPlayerResponse)
  }
}
