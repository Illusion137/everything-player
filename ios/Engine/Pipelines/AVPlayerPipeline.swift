import AVFoundation

final class EPAVPlayerPipeline: NSObject, EPPipeline, EPVideoFrameSource {
  let track: EPTrack
  weak var delegate: EPPipelineDelegate?
  private(set) var status: EPPipelineStatus = .idle

  private let options: EPSetupOptions
  private let localURL: URL?
  private let player = AVPlayer()
  private var item: AVPlayerItem?
  private var loader: EPResourceLoader?
  private var videoOutput: AVPlayerItemVideoOutput?
  private var observations: [NSKeyValueObservation] = []
  private var notificationTokens: [NSObjectProtocol] = []
  private var pendingSeek: Double?
  private var frozenPosition: Double?
  private var playWhenReady = false
  private var desiredRate: Float = 1
  private var released = false
  private let timeLock = NSLock()
  private var cachedDuration: Double?
  private var qualityRange: EPVideoQualityRange

  init(track: EPTrack, options: EPSetupOptions, localURL: URL?) {
    self.track = track
    self.options = options
    self.localURL = localURL
    self.qualityRange = options.videoQualityRange
    super.init()
    player.automaticallyWaitsToMinimizeStalling = true
    player.allowsExternalPlayback = options.enableVideo
  }

  var currentTime: Double {
    timeLock.lock()
    let frozen = frozenPosition
    timeLock.unlock()
    if let frozen { return frozen }
    let t = player.currentTime().seconds
    return t.isFinite ? t : track.trimStart
  }

  var mediaDuration: Double? {
    timeLock.lock(); defer { timeLock.unlock() }
    return cachedDuration
  }

  var bufferedTime: Double {
    guard let item else { return 0 }
    let now = player.currentTime()
    for value in item.loadedTimeRanges {
      let range = value.timeRangeValue
      if range.containsTime(now) || range.start > now {
        let end = range.end.seconds
        if end.isFinite { return end }
      }
    }
    return currentTime
  }

  var volume: Float {
    get { player.volume }
    set { player.volume = newValue }
  }

  var rate: Float {
    get { desiredRate }
    set {
      desiredRate = newValue
      if #available(iOS 16.0, *) { player.defaultRate = newValue }
      if player.rate != 0 { player.rate = newValue }
    }
  }

  var videoSource: EPVideoFrameSource? { videoOutput != nil ? self : nil }

  var videoQuality: EPVideoQualityState { EPVideoQualityState() }

  func setVideoQuality(_ id: String?, range: EPVideoQualityRange) throws {
    if id != nil { throw EPError(.unknown, "Video quality selection is not available for this track") }
    qualityRange = range
    if let item { applyQualityCaps(item) }
  }

  private func applyQualityCaps(_ item: AVPlayerItem) {
    guard options.enableVideo else { return }
    item.preferredPeakBitRate = Double(qualityRange.maxBitrate ?? 0)
    if #available(iOS 16.0, *) {
      item.preferredMaximumResolution = qualityRange.maxHeight.map { CGSize(width: 16384, height: $0) } ?? .zero
    }
  }

  func load(at position: Double) {
    guard let asset = makeAsset() else {
      fail(EPError(.sourceError, "Invalid URL for track \(track.id)"))
      return
    }
    let start = max(position, track.trimStart)
    setFrozen(start > 0 ? start : nil)
    pendingSeek = start > 0 ? start : nil
    let item = AVPlayerItem(asset: asset)
    item.preferredForwardBufferDuration = options.forwardBufferSeconds
    if let end = track.endTime { item.forwardPlaybackEndTime = CMTime(seconds: end, preferredTimescale: 1000) }
    if #available(iOS 16.0, *), !options.enableVideo { item.preferredMaximumResolution = CGSize(width: 1, height: 1) }
    applyQualityCaps(item)
    if options.enableVideo {
      let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferIOSurfacePropertiesKey as String: [String: Int](),
      ])
      item.add(output)
      videoOutput = output
    }
    self.item = item
    observe(item)
    setStatus(.loading)
    player.replaceCurrentItem(with: item)
  }

  private func makeAsset() -> AVURLAsset? {
    if let localURL { return AVURLAsset(url: localURL) }
    guard let raw = track.url, let url = URL(string: raw) else { return nil }
    let headers = track.requestHeaders
    if url.isFileURL { return AVURLAsset(url: url) }
    if track.sourceType == .raw, let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
       let loaderURL = EPResourceLoader.loaderURL(for: url) {
      let loader = EPResourceLoader(url: url, headers: headers)
      loader.allowedEndOffset = { [weak self] length in
        guard let self, let duration = self.mediaDuration, duration > 0 else { return Int64.max }
        let bytesPerSecond = Double(length) / duration
        let window = min(Double(self.options.maxBufferBytes), self.options.forwardBufferSeconds * bytesPerSecond)
        return Int64(self.currentTime * bytesPerSecond + window)
      }
      let asset = AVURLAsset(url: loaderURL)
      asset.resourceLoader.setDelegate(loader, queue: loader.queue)
      self.loader = loader
      return asset
    }
    var assetOptions: [String: Any] = [:]
    if !headers.isEmpty { assetOptions["AVURLAssetHTTPHeaderFieldsKey"] = headers }
    return AVURLAsset(url: url, options: assetOptions)
  }

  private func observe(_ item: AVPlayerItem) {
    observations = [
      item.observe(\.status, options: [.new]) { [weak self] item, _ in
        DispatchQueue.main.async { self?.itemStatusChanged(item) }
      },
      item.observe(\.duration, options: [.new]) { [weak self] item, _ in
        DispatchQueue.main.async { self?.updateDuration(item.duration) }
      },
      player.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
        DispatchQueue.main.async { self?.timeControlChanged(player.timeControlStatus) }
      },
    ]
    let center = NotificationCenter.default
    notificationTokens = [
      center.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
        self?.setStatus(.ended)
      },
      center.addObserver(forName: .AVPlayerItemFailedToPlayToEndTime, object: item, queue: .main) { [weak self] note in
        let err = note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error
        self?.fail(EPError.from(err ?? EPError(.sourceError, "Failed to play to end"), default: .sourceError))
      },
    ]
  }

  private func itemStatusChanged(_ item: AVPlayerItem) {
    guard !released, item === self.item else { return }
    switch item.status {
    case .readyToPlay:
      updateDuration(item.duration)
      configureTracks(item)
      if let target = pendingSeek {
        pendingSeek = nil
        performSeek(target)
      } else {
        setFrozen(nil)
        becameReady()
      }
    case .failed:
      fail(EPError.from(item.error ?? EPError(.sourceError, "Item failed"), default: .sourceError))
    default:
      break
    }
  }

  private func configureTracks(_ item: AVPlayerItem) {
    if !options.enableVideo {
      for t in item.tracks where t.assetTrack?.mediaType == .video { t.isEnabled = false }
    }
    if track.sourceType != .hls, let mix = EPEqualizerTap.audioMix(for: item) { item.audioMix = mix }
  }

  private func becameReady() {
    if playWhenReady {
      startPlayer()
    } else {
      setStatus(.ready)
    }
  }

  private func startPlayer() {
    if #available(iOS 16.0, *) { player.defaultRate = desiredRate }
    player.playImmediately(atRate: desiredRate)
  }

  private func timeControlChanged(_ control: AVPlayer.TimeControlStatus) {
    guard !released, item?.status == .readyToPlay, pendingSeek == nil, frozenPosition == nil else { return }
    switch control {
    case .playing: setStatus(.playing)
    case .waitingToPlayAtSpecifiedRate:
      if player.reasonForWaitingToPlay != .noItemToPlay { setStatus(.buffering) }
    case .paused:
      if status != .ended && !playWhenReady { setStatus(.ready) }
    @unknown default: break
    }
  }

  private func updateDuration(_ time: CMTime) {
    let seconds = time.seconds
    guard seconds.isFinite, seconds > 0 else { return }
    timeLock.lock()
    let changed = cachedDuration != seconds
    cachedDuration = seconds
    timeLock.unlock()
    if changed { delegate?.pipelineDidUpdateDuration(self) }
  }

  func play() {
    playWhenReady = true
    guard item?.status == .readyToPlay, pendingSeek == nil, frozenPosition == nil else { return }
    if status == .ended { return }
    startPlayer()
  }

  func pause() {
    playWhenReady = false
    player.pause()
    if status == .playing || status == .buffering { setStatus(.ready) }
  }

  func seek(to seconds: Double) {
    let target = max(track.trimStart, seconds)
    setFrozen(target)
    guard item?.status == .readyToPlay else {
      pendingSeek = target
      return
    }
    if status == .ended { status = .ready }
    performSeek(target)
  }

  private func performSeek(_ target: Double) {
    setStatus(.loading)
    let time = CMTime(seconds: target, preferredTimescale: 1000)
    player.currentItem?.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] finished in
      DispatchQueue.main.async {
        guard let self, !self.released, finished else { return }
        guard let frozen = self.frozenPosition, Swift.abs(frozen - target) < 0.0005 else { return }
        self.setFrozen(nil)
        self.becameReady()
      }
    }
  }

  func teardown() {
    released = true
    observations.forEach { $0.invalidate() }
    observations = []
    notificationTokens.forEach { NotificationCenter.default.removeObserver($0) }
    notificationTokens = []
    player.pause()
    player.replaceCurrentItem(with: nil)
    loader?.cancelAll()
    loader = nil
    EPVideoHub.shared.clearSourceIfCurrent(self)
  }

  func pixelBuffer(forHostTime hostTime: CFTimeInterval) -> CVPixelBuffer? {
    guard let videoOutput else { return nil }
    let itemTime = videoOutput.itemTime(forHostTime: hostTime)
    guard videoOutput.hasNewPixelBuffer(forItemTime: itemTime) else { return nil }
    return videoOutput.copyPixelBuffer(forItemTime: itemTime, itemTimeForDisplay: nil)
  }

  private func setFrozen(_ value: Double?) {
    timeLock.lock()
    frozenPosition = value
    timeLock.unlock()
  }

  private func setStatus(_ new: EPPipelineStatus) {
    onMain {
      guard !self.released, self.status != new else { return }
      if case .failed = self.status { return }
      self.status = new
      self.delegate?.pipeline(self, didChange: new)
    }
  }

  private func fail(_ error: EPError) {
    onMain {
      guard !self.released else { return }
      if case .failed = self.status { return }
      var e = error
      e.trackId = self.track.id
      self.player.pause()
      self.status = .failed(e.message)
      self.delegate?.pipeline(self, didFail: e)
    }
  }
}
