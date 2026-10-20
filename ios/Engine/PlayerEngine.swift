import AVFoundation

enum EPLocalMedia {
  case file(URL)
  case sabr(EPLocalSabrMedia)
}

struct EPActiveTrackChange {
  var lastIndex: Int?
  var lastTrackId: String?
  var lastPosition: Double
  var index: Int?
  var trackId: String?
}

final class EPPlayerEngine: EPPipelineDelegate {
  static let shared = EPPlayerEngine()

  var onStateChange: ((EPState, EPError?) -> Void)?
  var onActiveTrackChanged: ((EPActiveTrackChange) -> Void)?
  var onProgress: ((EPProgress, Int?, String?) -> Void)?
  var onError: ((EPError) -> Void)?
  var onQueueEnded: ((Int?, String?, Double) -> Void)?
  var onRemote: ((EPRemoteEvent) -> Void)?
  var onVideoQualityChanged: ((EPVideoQualityState, String?) -> Void)?
  var sabrCallbacks: EPSabrCallbackProvider?
  var localMediaResolver: ((EPTrack) -> EPLocalMedia?)?

  private let lock = NSRecursiveLock()
  private(set) var isSetup = false
  private(set) var setupOptions = EPSetupOptions()
  private var updateOptions = EPUpdateOptions()
  private var queue: [EPTrack] = []
  private var activeIndex: Int?
  private var state: EPState = .none
  private var lastError: EPError?
  private var repeatModeValue: EPRepeatMode = .off
  private var crossfadeSeconds: Double = 0
  private var volumeValue: Float = 1
  private var rateValue: Float = 1
  private var playWhenReady = false
  private var hasPlayed = false
  private var pendingSeek: Double?

  private var primary: EPPipeline?
  private var secondary: EPPipeline?
  private let sabrPool = EPSabrWarmPool()
  private var sabrTicks = 0
  private var fading = false
  private var tickTimer: DispatchSourceTimer?
  private var progressTimer: DispatchSourceTimer?
  private var resumeAfterInterruption = false

  private let session = EPAudioSession()
  private let remote = EPRemoteCommands()
  private let nowPlaying = EPNowPlaying()

  private init() {
    remote.handler = { [weak self] event in self?.handleRemote(event) }
    remote.isPlaying = { [weak self] in self?.getState() == .playing }
    session.onInterruption = { [weak self] began, shouldResume in self?.handleInterruption(began: began, shouldResume: shouldResume) }
    session.onOldDeviceUnavailable = { [weak self] in
      guard let self, self.setupOptions.autoHandleInterruptions else { return }
      self.pause()
    }
  }

  private func locked<T>(_ body: () -> T) -> T {
    lock.lock(); defer { lock.unlock() }
    return body()
  }

  func setup(_ options: EPSetupOptions) {
    locked {
      setupOptions = options
      isSetup = true
    }
    EPMediaCache.shared.configure(maxSizeMB: options.cacheMaxSizeMB, maxAgeSeconds: options.cacheMaxAgeSeconds, persistent: options.persistentCache)
    onMain {
      self.session.configure()
      self.startTickTimer()
      self.applyRemoteCommands()
    }
  }

  func update(_ options: EPUpdateOptions) {
    locked { updateOptions = options }
    onMain {
      self.applyRemoteCommands()
      self.restartProgressTimer()
    }
  }

  private func applyRemoteCommands() {
    let o = locked { updateOptions }
    remote.configure(capabilities: Set(o.capabilities), forwardInterval: o.forwardJumpInterval, backwardInterval: o.backwardJumpInterval)
  }

  func getQueue() -> [EPTrack] { locked { queue } }
  func getActiveIndex() -> Int? { locked { activeIndex } }
  func getState() -> EPState { locked { state } }
  func getLastError() -> EPError? { locked { lastError } }
  func getRepeatMode() -> EPRepeatMode { locked { repeatModeValue } }
  func getVolume() -> Float { locked { volumeValue } }
  func getRate() -> Float { locked { rateValue } }

  func getProgress() -> EPProgress {
    locked {
      guard let index = activeIndex, index < queue.count else { return EPProgress(position: 0, duration: 0, buffered: 0) }
      let track = queue[index]
      let duration = track.trimEnd(mediaDuration: primary?.mediaDuration) ?? 0
      let position: Double
      if let pendingSeek { position = pendingSeek } else { position = primary?.currentTime ?? track.trimStart }
      let buffered = primary?.bufferedTime ?? position
      let upper = duration > 0 ? duration : max(position, buffered)
      return EPProgress(position: min(max(0, position), upper), duration: duration, buffered: min(max(position, buffered), upper))
    }
  }

  func setRepeatMode(_ mode: EPRepeatMode) {
    locked { repeatModeValue = mode }
    onMain { self.invalidateSecondaryIfStale() }
  }

  func setCrossFade(_ seconds: Double) {
    locked { crossfadeSeconds = max(0, seconds) }
  }

  func setVolume(_ volume: Float) {
    locked { volumeValue = volume }
    onMain {
      if !self.fading { self.primary?.volume = volume }
    }
  }

  func setRate(_ rate: Float) {
    locked { rateValue = rate }
    onMain {
      self.primary?.rate = rate
      self.secondary?.rate = rate
      self.refreshNowPlaying()
    }
  }

  func setEqualizer(_ gains: [Float]) {
    EPEqualizerSettings.shared.set(gains)
  }

  func getVideoQuality() -> EPVideoQualityState {
    locked { primary }?.videoQuality ?? EPVideoQualityState()
  }

  func getVideoQualityRange() -> EPVideoQualityRange { locked { setupOptions.videoQualityRange } }

  func setVideoQualityRange(_ range: EPVideoQualityRange) {
    locked { setupOptions.videoQualityRange = range }
    onMain {
      let manual = self.primary.flatMap { p in p.videoQuality.auto ? nil : p.videoQuality.selectedId }
      try? self.primary?.setVideoQuality(manual, range: range)
      try? self.secondary?.setVideoQuality(nil, range: range)
    }
  }

  func setVideoQuality(_ id: String?) throws {
    let range = getVideoQualityRange()
    guard let primary = locked({ primary }) else {
      if id != nil { throw EPError(.unknown, "No active track") }
      return
    }
    try primary.setVideoQuality(id, range: range)
  }

  func add(_ tracks: [EPTrack], before: Int?) {
    guard !tracks.isEmpty else { return }
    let needsLoad: Bool = locked {
      let wasEmpty = queue.isEmpty
      let at = before.flatMap { $0 >= 0 && $0 <= queue.count ? $0 : nil } ?? queue.count
      queue.insert(contentsOf: tracks, at: at)
      if let a = activeIndex, at <= a { activeIndex = a + tracks.count }
      if activeIndex == nil && wasEmpty {
        activeIndex = 0
        return true
      }
      return false
    }
    onMain {
      if needsLoad {
        self.emitActiveChange(lastIndex: nil, lastTrackId: nil, lastPosition: 0)
        self.loadActive(at: nil)
      }
      self.invalidateSecondaryIfStale()
      self.preloadUpcoming()
    }
  }

  func remove(_ indexes: [Int]) {
    var removedActive = false
    var lastId: String?
    var lastIndex: Int?
    let lastPosition = getProgress().position
    locked {
      for index in Set(indexes).sorted(by: >) where index >= 0 && index < queue.count {
        queue.remove(at: index)
        guard let a = activeIndex else { continue }
        if index == a {
          removedActive = true
          lastIndex = a
        } else if index < a {
          activeIndex = a - 1
        }
      }
      if removedActive {
        lastId = primary?.track.id
        activeIndex = queue.isEmpty ? nil : min(lastIndex ?? 0, queue.count - 1)
      }
    }
    onMain {
      if removedActive {
        self.emitActiveChange(lastIndex: lastIndex, lastTrackId: lastId, lastPosition: lastPosition)
        if self.getActiveIndex() == nil {
          self.releasePipelines()
          self.setState(.none)
          self.nowPlaying.setTrack(nil)
        } else {
          self.loadActive(at: nil)
        }
      }
      self.invalidateSecondaryIfStale()
    }
  }

  func removeUpcoming() {
    locked {
      guard let a = activeIndex, a + 1 < queue.count else { return }
      queue.removeSubrange((a + 1)...)
    }
    onMain { self.invalidateSecondaryIfStale() }
  }

  func move(from: Int, to: Int) {
    locked {
      guard from >= 0, from < queue.count, to >= 0, to < queue.count, from != to else { return }
      let t = queue.remove(at: from)
      queue.insert(t, at: to)
      guard let a = activeIndex else { return }
      if a == from {
        activeIndex = to
      } else if from < a && to >= a {
        activeIndex = a - 1
      } else if from > a && to <= a {
        activeIndex = a + 1
      }
    }
    onMain { self.invalidateSecondaryIfStale() }
  }

  func setQueue(_ tracks: [EPTrack]) {
    let lastPosition = getProgress().position
    let (keep, lastIndex, lastId): (Bool, Int?, String?) = locked {
      let activeId = activeIndex.flatMap { $0 < queue.count ? queue[$0].id : nil }
      let li = activeIndex
      queue = tracks
      if let activeId, let newIndex = tracks.firstIndex(where: { $0.id == activeId }) {
        activeIndex = newIndex
        return (true, li, activeId)
      }
      activeIndex = tracks.isEmpty ? nil : 0
      return (false, li, activeId)
    }
    onMain {
      self.invalidateSecondaryIfStale()
      guard !keep else { return }
      self.emitActiveChange(lastIndex: lastIndex, lastTrackId: lastId, lastPosition: lastPosition)
      if self.getActiveIndex() == nil {
        self.releasePipelines()
        self.setState(.none)
        self.nowPlaying.setTrack(nil)
      } else {
        self.loadActive(at: nil)
      }
    }
  }

  func updateMetadata(index: Int, track: EPTrack) {
    let isActive: Bool = locked {
      guard index >= 0, index < queue.count else { return false }
      var t = queue[index]
      t.title = track.title
      t.artist = track.artist
      t.album = track.album
      t.artwork = track.artwork
      if let d = track.duration { t.duration = d }
      queue[index] = t
      return index == activeIndex
    }
    if isActive { onMain { self.refreshNowPlaying(trackChanged: true) } }
  }

  func skip(to index: Int, initialPosition: Double?) throws {
    let ok = locked { index >= 0 && index < queue.count }
    guard ok else { throw EPError(.unknown, "Index \(index) is out of bounds") }
    onMain { self.transition(to: index, initialPosition: initialPosition, manual: true) }
  }

  func skipToNext(initialPosition: Double?) throws {
    guard let next = locked({ nextIndex(ignoringRepeatTrack: true) }) else {
      throw EPError(.unknown, "There is no next track")
    }
    onMain { self.transition(to: next, initialPosition: initialPosition, manual: true) }
  }

  func skipToPrevious(initialPosition: Double?) throws {
    let previous: Int? = locked {
      guard let a = activeIndex else { return nil }
      if a > 0 { return a - 1 }
      return repeatModeValue == .queue && !queue.isEmpty ? queue.count - 1 : nil
    }
    guard let previous else {
      guard getActiveIndex() != nil else { throw EPError(.unknown, "There is no previous track") }
      seekTo(initialPosition ?? 0)
      return
    }
    onMain { self.transition(to: previous, initialPosition: initialPosition, manual: true) }
  }

  private func nextIndex(ignoringRepeatTrack: Bool) -> Int? {
    guard let a = activeIndex, !queue.isEmpty else { return nil }
    if !ignoringRepeatTrack && repeatModeValue == .track { return a }
    if a + 1 < queue.count { return a + 1 }
    return repeatModeValue == .queue ? 0 : nil
  }

  func play() {
    locked { playWhenReady = true }
    onMain {
      self.session.activate()
      if self.getState() == .ended || self.getState() == .stopped || self.primary == nil {
        guard self.getActiveIndex() != nil else { return }
        let start = self.getState() == .ended ? nil : self.locked { self.pendingSeek }
        self.loadActive(at: start)
        return
      }
      if case .failed = self.primary?.status { self.retry(); return }
      self.primary?.play()
      if self.fading { self.secondary?.play() }
      self.syncState()
    }
  }

  func pause() {
    locked { playWhenReady = false }
    onMain {
      self.primary?.pause()
      self.secondary?.pause()
      self.syncState()
    }
  }

  func stop() {
    locked {
      playWhenReady = false
      pendingSeek = nil
    }
    onMain {
      self.releasePipelines()
      self.sabrPool.clear()
      self.setState(.stopped)
      self.refreshNowPlaying()
    }
  }

  func reset() {
    locked {
      playWhenReady = false
      pendingSeek = nil
      queue = []
      activeIndex = nil
      hasPlayed = false
    }
    onMain {
      self.releasePipelines()
      self.sabrPool.clear()
      self.setState(.none)
      self.nowPlaying.setTrack(nil)
    }
  }

  func retry() {
    onMain {
      guard self.getActiveIndex() != nil else { return }
      let position = self.primary?.currentTime
      self.loadActive(at: position)
    }
  }

  func seekTo(_ seconds: Double) {
    let target: Double? = locked {
      guard let a = activeIndex, a < queue.count else { return nil }
      let track = queue[a]
      let upper = track.trimEnd(mediaDuration: primary?.mediaDuration) ?? max(seconds, track.trimStart)
      let clamped = min(max(seconds, track.trimStart), upper)
      pendingSeek = clamped
      return clamped
    }
    guard let target else { return }
    let progress = getProgress()
    onProgress?(progress, getActiveIndex(), currentTrackId())
    onMain {
      self.cancelFade()
      if let primary = self.primary {
        primary.seek(to: target)
      } else {
        self.loadActive(at: target)
      }
      self.refreshNowPlaying()
    }
  }

  func seekBy(_ offset: Double) {
    let base = locked { pendingSeek } ?? getProgress().position
    seekTo(base + offset)
  }

  var activeTrackId: String? { currentTrackId() }

  private func currentTrackId() -> String? {
    locked { activeIndex.flatMap { $0 < queue.count ? queue[$0].id : nil } }
  }

  private func makePipeline(for track: EPTrack) -> EPPipeline {
    let options = locked { setupOptions }
    let local = localMediaResolver?(track)
    let pipeline: EPPipeline
    switch (track.sabr, local) {
    case let (sabr?, .sabr(media)):
      pipeline = EPSabrPipeline(track: track, sabr: sabr, options: options, callbacks: sabrCallbacks, local: media)
    case let (_, .file(url)) where track.sourceType == .hls && url.pathExtension.lowercased() == "m3u8":
      pipeline = EPHLSPipeline(track: track, options: options, localURL: url)
    case let (_, .file(url)):
      pipeline = EPAVPlayerPipeline(track: track, options: options, localURL: url)
    case let (sabr?, _):
      pipeline = EPSabrPipeline(track: track, sabr: sabr, options: options, callbacks: sabrCallbacks, local: nil, warmPool: sabrPool)
    case _ where track.sourceType == .hls:
      pipeline = EPHLSPipeline(track: track, options: options, localURL: nil)
    default:
      pipeline = EPAVPlayerPipeline(track: track, options: options, localURL: nil)
    }
    pipeline.delegate = self
    pipeline.rate = locked { rateValue }
    return pipeline
  }

  private func loadActive(at position: Double?) {
    cancelFade()
    releasePipelines()
    let (track, autoplay): (EPTrack?, Bool) = locked {
      guard let a = activeIndex, a < queue.count else { return (nil, false) }
      return (queue[a], playWhenReady)
    }
    guard let track else { return }
    let start = position ?? track.trimStart
    locked {
      pendingSeek = start > track.trimStart ? start : nil
      lastError = nil
    }
    let pipeline = makePipeline(for: track)
    pipeline.volume = locked { volumeValue }
    locked { primary = pipeline }
    setState(.loading)
    refreshNowPlaying(trackChanged: true)
    pipeline.load(at: start)
    if autoplay {
      session.activate()
      pipeline.play()
    }
    preloadUpcoming()
  }

  private func releasePipelines() {
    let (p, s): (EPPipeline?, EPPipeline?) = locked {
      let r = (primary, secondary)
      primary = nil
      secondary = nil
      fading = false
      return r
    }
    p?.delegate = nil
    s?.delegate = nil
    p?.teardown()
    s?.teardown()
    EPVideoHub.shared.setSource(nil)
  }

  private func transition(to index: Int, initialPosition: Double?, manual: Bool) {
    let lastPosition = getProgress().position
    let (lastIndex, lastId): (Int?, String?) = locked { (activeIndex, currentTrackId()) }
    let targetId: String? = locked { index < queue.count ? queue[index].id : nil }
    if let secondary, secondary.track.id == targetId, initialPosition == nil, !(manual && fading) {
      promoteSecondary(lastIndex: lastIndex, lastId: lastId, lastPosition: lastPosition, newIndex: index)
      return
    }
    locked { activeIndex = index }
    emitActiveChange(lastIndex: lastIndex, lastTrackId: lastId, lastPosition: lastPosition)
    loadActive(at: initialPosition)
  }

  private func promoteSecondary(lastIndex: Int?, lastId: String?, lastPosition: Double, newIndex: Int) {
    guard let next = secondary else { return }
    let old: EPPipeline? = locked {
      let o = primary
      primary = next
      secondary = nil
      activeIndex = newIndex
      pendingSeek = nil
      return o
    }
    fading = false
    old?.delegate = nil
    old?.teardown()
    next.volume = locked { volumeValue }
    EPVideoHub.shared.setSource(next.videoSource)
    if locked({ playWhenReady }) { next.play() }
    emitActiveChange(lastIndex: lastIndex, lastTrackId: lastId, lastPosition: lastPosition)
    refreshNowPlaying(trackChanged: true)
    syncState()
    preloadUpcoming()
    onVideoQualityChanged?(next.videoQuality, next.track.id)
  }

  private func cancelFade() {
    guard fading else { return }
    fading = false
    let s = locked { () -> EPPipeline? in
      let s = secondary
      secondary = nil
      return s
    }
    s?.delegate = nil
    s?.teardown()
    primary?.volume = locked { volumeValue }
  }

  private func invalidateSecondaryIfStale() {
    warmUpcomingSabr()
    guard let secondary else { return }
    let nextId: String? = locked { nextIndex(ignoringRepeatTrack: false).flatMap { $0 < queue.count ? queue[$0].id : nil } }
    if secondary.track.id != nextId || locked({ repeatModeValue }) == .track {
      if fading { cancelFade() } else {
        locked { self.secondary = nil }
        secondary.delegate = nil
        secondary.teardown()
      }
    }
  }

  func pipeline(_ pipeline: EPPipeline, didChange status: EPPipelineStatus) {
    if pipeline === secondary {
      if status == .ended, fading { finishFade() }
      return
    }
    guard pipeline === primary else { return }
    switch status {
    case .ready, .playing:
      locked { pendingSeek = nil }
      if let source = pipeline.videoSource { EPVideoHub.shared.setSource(source) }
    case .ended:
      handleTrackEnded()
      return
    default:
      break
    }
    syncState()
  }

  func pipeline(_ pipeline: EPPipeline, didFail error: EPError) {
    if pipeline === secondary {
      if fading { cancelFade() } else {
        locked { secondary = nil }
        pipeline.delegate = nil
        pipeline.teardown()
      }
      return
    }
    guard pipeline === primary else { return }
    locked {
      lastError = error
      pendingSeek = nil
    }
    setState(.error, error: error)
    onError?(error)
  }

  func pipelineDidUpdateDuration(_ pipeline: EPPipeline) {
    if pipeline === primary { refreshNowPlaying() }
  }

  func pipelineDidChangeVideoQuality(_ pipeline: EPPipeline) {
    guard pipeline === primary else { return }
    onVideoQualityChanged?(pipeline.videoQuality, pipeline.track.id)
  }

  private func syncState() {
    guard let primary else { return }
    let (pwr, played) = locked { (playWhenReady, hasPlayed) }
    let newState: EPState
    switch primary.status {
    case .idle, .loading: newState = .loading
    case .buffering: newState = .buffering
    case .ready: newState = pwr ? .buffering : (played ? .paused : .ready)
    case .playing:
      newState = pwr ? .playing : .paused
      locked { hasPlayed = true }
    case .ended: newState = .ended
    case .failed: return
    }
    setState(newState)
    refreshNowPlaying()
  }

  private func setState(_ newState: EPState, error: EPError? = nil) {
    let changed: Bool = locked {
      guard state != newState else { return false }
      state = newState
      if newState != .error { lastError = nil }
      return true
    }
    guard changed else { return }
    onStateChange?(newState, error)
  }

  private func emitActiveChange(lastIndex: Int?, lastTrackId: String?, lastPosition: Double) {
    let (index, id) = locked { (activeIndex, currentTrackId()) }
    onActiveTrackChanged?(EPActiveTrackChange(lastIndex: lastIndex, lastTrackId: lastTrackId, lastPosition: lastPosition, index: index, trackId: id))
  }

  private func handleTrackEnded() {
    let (mode, active) = locked { (repeatModeValue, activeIndex) }
    if mode == .track, let active {
      let start = locked { queue[active].trimStart }
      locked { pendingSeek = nil }
      primary?.seek(to: start)
      if locked({ playWhenReady }) { primary?.play() }
      return
    }
    if fading, secondary != nil {
      finishFade()
      return
    }
    guard let next = locked({ nextIndex(ignoringRepeatTrack: true) }) else {
      let position = getProgress().position
      setState(.ended)
      onQueueEnded?(active, currentTrackId(), position)
      refreshNowPlaying()
      return
    }
    transition(to: next, initialPosition: nil, manual: false)
  }

  private func finishFade() {
    guard let next = locked({ nextIndex(ignoringRepeatTrack: true) }), secondary != nil else {
      cancelFade()
      return
    }
    let lastPosition = getProgress().position
    let (lastIndex, lastId) = locked { (activeIndex, currentTrackId()) }
    promoteSecondary(lastIndex: lastIndex, lastId: lastId, lastPosition: lastPosition, newIndex: next)
  }

  private func startTickTimer() {
    guard tickTimer == nil else { return }
    let timer = DispatchSource.makeTimerSource(queue: .main)
    timer.schedule(deadline: .now() + 0.1, repeating: 0.1)
    timer.setEventHandler { [weak self] in self?.tick() }
    tickTimer = timer
    timer.resume()
  }

  private func restartProgressTimer() {
    progressTimer?.cancel()
    progressTimer = nil
    let interval = locked { updateOptions.progressUpdateEventInterval }
    guard interval > 0 else { return }
    let timer = DispatchSource.makeTimerSource(queue: .main)
    timer.schedule(deadline: .now() + interval, repeating: interval)
    timer.setEventHandler { [weak self] in
      guard let self, self.getState() == .playing else { return }
      self.onProgress?(self.getProgress(), self.getActiveIndex(), self.currentTrackId())
    }
    progressTimer = timer
    timer.resume()
  }

  private func tick() {
    guard let primary, locked({ playWhenReady }) else { return }
    sabrTicks += 1
    if sabrTicks % 300 == 0 { warmUpcomingSabr() }
    let (track, fadeLength, mode, volume) = locked { (primary.track, crossfadeSeconds, repeatModeValue, volumeValue) }
    guard let end = track.trimEnd(mediaDuration: primary.mediaDuration) else { return }
    let position = primary.currentTime
    let remaining = end - position
    let nextIdx = locked { nextIndex(ignoringRepeatTrack: false) }
    let canFade = fadeLength > 0 && mode != .track && (end - track.trimStart) >= 2 * fadeLength

    if secondary == nil, let nextIdx, mode != .track, remaining <= max(fadeLength, 0) + 8, remaining > 0.25 {
      let nextTrack = locked { queue[nextIdx] }
      let pipeline = makePipeline(for: nextTrack)
      pipeline.volume = canFade ? 0 : volume
      locked { secondary = pipeline }
      pipeline.load(at: nextTrack.trimStart)
    }

    guard canFade, let secondary, getState() == .playing else { return }
    if !fading, remaining <= fadeLength, secondary.status == .ready || secondary.status == .playing {
      fading = true
      secondary.volume = 0
      secondary.play()
    }
    guard fading else { return }
    let p = Float(min(1, max(0, 1 - remaining / fadeLength)))
    primary.volume = volume * cos(p * .pi / 2)
    secondary.volume = volume * sin(p * .pi / 2)
    if remaining <= 0.05 { finishFade() }
  }

  private func warmUpcomingSabr() {
    let (tracks, options): ([EPTrack], EPSetupOptions) = locked {
      guard let a = activeIndex, a < queue.count else { return ([], setupOptions) }
      var out: [EPTrack] = []
      var i = a
      for _ in 0..<max(0, min(setupOptions.sabrPoolAhead, queue.count - 1)) {
        i += 1
        if i >= queue.count {
          guard repeatModeValue == .queue else { break }
          i = 0
        }
        out.append(queue[i])
      }
      return (out, setupOptions)
    }
    let candidates = tracks.filter { $0.sabr != nil && localMediaResolver?($0) == nil }
    sabrPool.warm(candidates, options: options, provider: sabrCallbacks)
  }

  private func preloadUpcoming() {
    warmUpcomingSabr()
    let (count, tracks): (Int, [EPTrack]) = locked {
      guard let a = activeIndex else { return (0, []) }
      let n = max(0, setupOptions.preloadNext)
      return (n, Array(queue.dropFirst(a + 1).prefix(n)))
    }
    guard count > 0 else { return }
    let bytes = Int64(512 * 1024)
    for track in tracks where track.sourceType == .raw && localMediaResolver?(track) == nil {
      guard let raw = track.url, let url = URL(string: raw), !url.isFileURL else { continue }
      EPMediaCache.shared.prefetch(url, headers: track.requestHeaders, bytes: bytes)
    }
  }

  private func refreshNowPlaying(trackChanged: Bool = false) {
    let (track, playing, rate): (EPTrack?, Bool, Float) = locked {
      (activeIndex.flatMap { $0 < queue.count ? queue[$0] : nil }, state == .playing, rateValue)
    }
    if trackChanged { nowPlaying.setTrack(track) }
    guard let track else { return }
    let progress = getProgress()
    nowPlaying.update(position: progress.position, duration: track.trimEnd(mediaDuration: primary?.mediaDuration), rate: rate, playing: playing)
  }

  private func handleRemote(_ event: EPRemoteEvent) {
    onRemote?(event)
    guard locked({ setupOptions.autoHandleRemoteEvents }) else { return }
    switch event {
    case .play: play()
    case .pause: pause()
    case .stop: stop()
    case .next: try? skipToNext(initialPosition: nil)
    case .previous: try? skipToPrevious(initialPosition: nil)
    case let .seek(t): seekTo(t)
    case let .jumpForward(i): seekBy(i)
    case let .jumpBackward(i): seekBy(-i)
    default: break
    }
  }

  private func handleInterruption(began: Bool, shouldResume: Bool) {
    let auto = locked { setupOptions.autoHandleInterruptions }
    if began {
      resumeAfterInterruption = getState() == .playing || getState() == .buffering
      if auto { pause() }
      onRemote?(.duck(paused: true, permanent: false))
    } else {
      let resume = shouldResume && resumeAfterInterruption
      resumeAfterInterruption = false
      if resume && auto {
        EPAudioGraph.shared.ensureRunning()
        play()
      }
      onRemote?(.duck(paused: !resume, permanent: !shouldResume))
    }
  }
}
