import AVFoundation

final class EPSabrPipeline: EPPipeline {
  let track: EPTrack
  weak var delegate: EPPipelineDelegate?
  private(set) var status: EPPipelineStatus = .idle

  private let options: EPSetupOptions
  private weak var callbacks: EPSabrCallbackProvider?
  private let local: EPLocalSabrMedia?
  private let renderer = EPAudioRenderer()
  private let frames: EPDecodedFrameQueue?
  private let lock = NSLock()

  private var info: EPSabrInfo
  private var poToken: String
  private var session: EPSabrSession?
  private weak var warmPool: EPSabrWarmPool?
  private var tasks: [Task<Void, Never>] = []
  private var generation = 0
  private var frozenPosition: Double?
  private var playWhenReady = false
  private var callbackError: EPError?
  private var knownDuration: Double?
  private var released = false
  private var qualityRange: EPVideoQualityRange
  private var manualItag: Int?
  private var activeVideoItag: Int?
  private var audioScheduledEnd: Double = 0
  private var streamAudioIsOpus = false
  private var reusedSession = false
  private var producedAudio = false

  init(track: EPTrack, sabr: EPSabrInfo, options: EPSetupOptions, callbacks: EPSabrCallbackProvider?, local: EPLocalSabrMedia?, warmPool: EPSabrWarmPool? = nil) {
    self.track = track
    self.warmPool = warmPool
    self.info = sabr
    self.poToken = sabr.poToken
    self.options = options
    self.callbacks = callbacks
    self.local = local
    self.qualityRange = options.videoQualityRange
    let wantsVideo = options.enableVideo && (local != nil ? local?.videoURL != nil : EPSabr.pickVideo(sabr.formats, range: options.videoQualityRange) != nil)
    frames = wantsVideo ? EPDecodedFrameQueue(capacity: 120) : nil
    if sabr.duration > 0 { knownDuration = sabr.duration } else if let d = track.duration { knownDuration = d }
    frames?.clock = { [weak self] in self?.videoClock ?? 0 }
    renderer.onStarved = { [weak self] in self?.setStatus(.buffering) }
    renderer.onResumed = { [weak self] in
      guard let self, self.playWhenReady else { return }
      self.setStatus(.playing)
    }
    renderer.onFinished = { [weak self] in self?.setStatus(.ended) }
  }

  deinit {
    tasks.forEach { $0.cancel() }
  }

  var currentTime: Double {
    lock.lock()
    let frozen = frozenPosition
    lock.unlock()
    return frozen ?? renderer.position
  }

  private var videoClock: Double {
    renderer.position - AVAudioSession.sharedInstance().outputLatency
  }

  var mediaDuration: Double? { knownDuration }

  var bufferedTime: Double { currentTime + renderer.aheadSeconds }

  var volume: Float {
    get { renderer.volume }
    set { renderer.volume = newValue }
  }

  var rate: Float {
    get { renderer.rate }
    set { renderer.rate = newValue }
  }

  var videoSource: EPVideoFrameSource? { frames }

  var videoQuality: EPVideoQualityState {
    guard frames != nil, local == nil else { return EPVideoQualityState() }
    return lock.sync {
      EPVideoQualityState(
        qualities: EPSabr.videoFormats(info.formats).map(EPSabr.quality),
        selectedId: activeVideoItag.map(String.init), auto: manualItag == nil)
    }
  }

  func setVideoQuality(_ id: String?, range: EPVideoQualityRange) throws {
    guard frames != nil, local == nil else {
      if id != nil { throw EPError(.unknown, "Video quality cannot be changed for this track") }
      return
    }
    let modeChanged: Bool = try lock.sync {
      let previousManual = manualItag
      qualityRange = range
      if let id {
        guard let itag = Int(id), EPSabr.videoFormats(info.formats).contains(where: { $0.itag == itag }) else {
          throw EPError(.unknown, "Unknown video quality \(id)")
        }
        manualItag = itag
      } else {
        manualItag = nil
      }
      return previousManual != manualItag
    }
    onMain {
      guard !self.released else { return }
      let needsRestart = self.session != nil && self.lock.sync {
        self.activeVideoItag != nil && self.selectedVideoFormatLocked()?.itag != self.activeVideoItag
      }
      if needsRestart {
        self.restart(at: self.currentTime, keepAudio: self.status == .playing || self.status == .ready || self.status == .buffering)
      }
      if needsRestart || modeChanged { self.delegate?.pipelineDidChangeVideoQuality(self) }
    }
  }

  private func selectedVideoFormatLocked() -> EPSabrFormat? {
    if let manualItag, let f = info.formats.first(where: { $0.itag == manualItag }) { return f }
    return EPSabr.pickVideo(info.formats, range: qualityRange)
  }

  func load(at position: Double) {
    restart(at: position)
  }

  func play() {
    playWhenReady = true
    renderer.play()
    if status == .ready { setStatus(.playing) }
  }

  func pause() {
    playWhenReady = false
    renderer.pause()
    if status == .playing || status == .buffering { setStatus(.ready) }
  }

  func seek(to seconds: Double) {
    if !seekInSession(to: seconds) { restart(at: seconds) }
  }

  func teardown() {
    released = true
    lock.lock()
    generation += 1
    lock.unlock()
    tearDownStream()
    renderer.release()
    frames?.flush()
    if let frames { EPVideoHub.shared.clearSourceIfCurrent(frames) }
  }

  private func setStatus(_ new: EPPipelineStatus) {
    onMain {
      guard !self.released, self.status != new else { return }
      if case .failed = self.status { return }
      self.status = new
      self.delegate?.pipeline(self, didChange: new)
    }
  }

  private func fail(_ error: EPError, generation gen: Int) {
    onMain {
      guard !self.released, self.isCurrent(gen) else { return }
      var e = error
      e.trackId = self.track.id
      self.tearDownStream()
      self.renderer.pause()
      self.status = .failed(e.message)
      self.delegate?.pipeline(self, didFail: e)
    }
  }

  private func isCurrent(_ gen: Int) -> Bool {
    lock.lock(); defer { lock.unlock() }
    return gen == generation
  }

  private func tearDownStream() {
    tasks.forEach { $0.cancel() }
    tasks = []
    session?.owner = nil
    session?.abort()
    session = nil
  }

  private func restart(at requested: Double, keepAudio: Bool = false) {
    let position = max(0, requested)
    lock.lock()
    generation += 1
    let gen = generation
    let audioStart = keepAudio ? max(position, audioScheduledEnd) : position
    if !keepAudio {
      frozenPosition = position
      audioScheduledEnd = position
    }
    callbackError = nil
    lock.unlock()

    tearDownStream()
    frames?.flush()
    if !keepAudio {
      renderer.reset(at: position)
      setStatus(.loading)
    }

    let audioReader: EPChunkReader
    var videoReader: EPChunkReader?
    let audioIsOpus: Bool
    do {
      if let local {
        audioReader = try EPSabr.fileReader(local.audioURL)
        audioIsOpus = local.audioIsOpus
        if frames != nil, let v = local.videoURL { videoReader = try EPSabr.fileReader(v) }
      } else {
        guard let audioFormat = EPSabr.pickAudio(info.formats) else {
          throw EPError(.sabrStreamFailed, "No playable audio format (opus/aac) in SABR formats")
        }
        audioIsOpus = EPSabr.isOpus(audioFormat)
        let videoFormat = frames != nil ? lock.sync { selectedVideoFormatLocked() } : nil
        lock.sync { activeVideoItag = videoFormat?.itag }
        let (result, reused) = try openSession(audioItag: audioFormat.itag, videoItag: videoFormat?.itag, at: position, allowWarm: !keepAudio)
        audioReader = EPSabr.streamReader(result.audioStream)
        if videoFormat != nil { videoReader = EPSabr.streamReader(result.videoStream) }
        lock.sync {
          streamAudioIsOpus = audioIsOpus
          reusedSession = reused
          producedAudio = false
        }
      }
    } catch {
      fail(EPError.from(error, default: .sabrStreamFailed), generation: gen)
      return
    }

    startReaders(audio: audioReader, video: videoReader, audioIsOpus: audioIsOpus, audioStart: audioStart, videoStart: position, resumed: keepAudio, generation: gen)
  }

  private func startReaders(audio: @escaping EPChunkReader, video: EPChunkReader?, audioIsOpus: Bool, audioStart: Double, videoStart: Double, resumed: Bool, generation gen: Int) {
    let decoder: EPAudioPacketDecoder = audioIsOpus ? EPOpusStreamDecoder() : EPAACStreamDecoder()
    let activeStream = session?.stream
    tasks.append(Task.detached(priority: .userInitiated) { [weak self] in
      await self?.runAudio(reader: audio, decoder: decoder, start: audioStart, resumed: resumed, stream: activeStream, generation: gen)
    })
    if let video, frames != nil {
      tasks.append(Task.detached(priority: .userInitiated) { [weak self] in
        await self?.runVideo(reader: video, start: videoStart, generation: gen)
      })
    }
  }

  private func seekInSession(to requested: Double) -> Bool {
    guard let session, local == nil else { return false }
    if case .failed = status { return false }
    let position = max(0, requested)
    let (gen, audioIsOpus, hasVideo): (Int, Bool, Bool) = lock.sync {
      generation += 1
      frozenPosition = position
      audioScheduledEnd = position
      callbackError = nil
      return (generation, streamAudioIsOpus, activeVideoItag != nil)
    }
    tasks.forEach { $0.cancel() }
    tasks = []
    guard let result = session.stream.seek(toMs: Int(position * 1000)) else { return false }
    lock.sync {
      reusedSession = true
      producedAudio = false
    }
    frames?.flush()
    renderer.reset(at: position)
    setStatus(.loading)
    startReaders(
      audio: EPSabr.streamReader(result.audioStream),
      video: hasVideo ? EPSabr.streamReader(result.videoStream) : nil,
      audioIsOpus: audioIsOpus, audioStart: position, videoStart: position, resumed: false, generation: gen)
    return true
  }

  private func openSession(audioItag: Int, videoItag: Int?, at position: Double, allowWarm: Bool) throws -> (StreamStartResult, Bool) {
    if allowWarm, let warm = warmPool?.take(track.id, audioItag: audioItag, videoItag: videoItag) {
      warm.owner = self
      session = warm
      if let result = warm.stream.seek(toMs: Int(position * 1000)) { return (result, true) }
      warm.owner = nil
      warm.abort()
    }
    let (current, token) = lock.sync { (info, poToken) }
    let fresh = EPSabrSession(
      track: track, info: current, poToken: token, options: options, provider: callbacks,
      audioItag: audioItag, videoItag: videoItag)
    fresh.owner = self
    session = fresh
    return (try fresh.start(at: position), false)
  }

  private func activeGeneration(_ session: EPSabrSession) -> Int? {
    lock.sync { session === self.session ? generation : nil }
  }
  private func runAudio(reader: EPChunkReader, decoder: EPAudioPacketDecoder, start: Double, resumed: Bool, stream: SabrStream?, generation gen: Int) async {
    let end = track.trimEnd(mediaDuration: knownDuration)
    var scheduledAny = resumed
    var gated = false
    do {
      while !Task.isCancelled && isCurrent(gen) {
        while renderer.aheadSeconds > options.forwardBufferSeconds && !Task.isCancelled && isCurrent(gen) {
          await epSleep(0.1)
        }
        guard let chunk = try await reader() else { break }
        let decoded = try decoder.feed(chunk, decodeFrom: start)
        var batch: [AVAudioPCMBuffer] = []
        var batchEnd: Double = 0
        for item in decoded {
          let sr = item.buffer.format.sampleRate
          let length = Double(item.buffer.frameLength) / sr
          var buffer = item.buffer
          var ts = item.timestampSeconds
          if ts + length <= start { continue }
          if ts < start {
            let drop = Int((start - ts) * sr)
            guard let trimmed = buffer.dropping(frames: drop) else { continue }
            buffer = trimmed
            ts = start
          }
          if let end, ts + Double(buffer.frameLength) / sr > end {
            let keep = Int((end - ts) * sr)
            if keep > 0, keep < Int(buffer.frameLength) { buffer.frameLength = AVAudioFrameCount(keep) }
            if keep > 0 {
              batch.append(buffer)
              batchEnd = ts + Double(buffer.frameLength) / sr
            }
            gated = true
            break
          }
          batch.append(buffer)
          batchEnd = ts + Double(buffer.frameLength) / sr
        }
        if batchEnd > 0 { lock.sync { audioScheduledEnd = max(audioScheduledEnd, batchEnd) } }
        if let combined = AVAudioPCMBuffer.concatenate(batch), isCurrent(gen) {
          let first = !scheduledAny
          await MainActor.run { self.schedule(combined, generation: gen, first: first) }
          scheduledAny = true
        }
        if !scheduledAny, let s = stream, s.audioEndTimeMs > 0, knownDuration == nil {
          updateDuration(Double(s.audioEndTimeMs) / 1000)
        }
        if gated { break }
      }
    } catch {
      guard !Task.isCancelled, isCurrent(gen) else { return }
      let cbError = lock.sync { callbackError }
      fail(cbError ?? EPError.from(error, default: local != nil ? .decodeError : .sabrStreamFailed), generation: gen)
      return
    }
    guard !Task.isCancelled, isCurrent(gen) else { return }
    let producedAudio = scheduledAny
    await MainActor.run {
      guard self.isCurrent(gen) else { return }
      if !producedAudio {
        self.lock.sync { self.frozenPosition = nil }
      }
      self.renderer.finishScheduling()
    }
  }

  private func schedule(_ buffer: AVAudioPCMBuffer, generation gen: Int, first: Bool) {
    guard isCurrent(gen), !released else { return }
    renderer.schedule(buffer)
    guard first else { return }
    lock.sync { producedAudio = true }
    lock.lock()
    frozenPosition = nil
    lock.unlock()
    if playWhenReady {
      renderer.play()
      setStatus(.playing)
    } else {
      setStatus(.ready)
    }
  }

  private func updateDuration(_ seconds: Double) {
    onMain {
      guard self.knownDuration == nil, seconds > 0 else { return }
      self.knownDuration = seconds
      self.delegate?.pipelineDidUpdateDuration(self)
    }
  }

  private func runVideo(reader: EPChunkReader, start: Double, generation gen: Int) async {
    guard let frames else { return }
    let demuxer = EPFMP4Demuxer()
    var decoder: EPH264Decoder?
    var gop: [EPMP4Sample] = []
    var reachedStart = false
    let end = track.trimEnd(mediaDuration: knownDuration)
    do {
      while !Task.isCancelled && isCurrent(gen) {
        while let last = frames.lastPts, last - videoClock > 1.0, !Task.isCancelled, isCurrent(gen) {
          await epSleep(0.02)
        }
        guard let chunk = try await reader() else { break }
        let samples = demuxer.feed(chunk)
        if decoder == nil, let t = demuxer.track {
          guard case let .avc(avcC, width, height) = t.codec else { return }
          decoder = try EPH264Decoder(avcC: avcC, width: width, height: height, timescale: t.timescale) { [weak frames] frame in
            frames?.push(frame)
          }
        }
        guard let decoder, let timescale = demuxer.track?.timescale else { continue }
        for sample in samples {
          let pts = Double(sample.pts) / Double(timescale)
          if let end, pts > end { return }
          if !reachedStart {
            if sample.isSync { gop.removeAll() }
            gop.append(sample)
            guard pts >= start - 0.001 else { continue }
            reachedStart = true
            gop.forEach { decoder.decode($0) }
            gop.removeAll()
          } else {
            decoder.decode(sample)
          }
        }
      }
      decoder?.flush()
    } catch {
      return
    }
  }
}

extension EPSabrPipeline: EPSabrSessionOwner {
  func session(_ session: EPSabrSession, didReload serverAbrStreamingUrl: String, config: String) {
    lock.sync {
      info.serverAbrStreamingUrl = serverAbrStreamingUrl
      info.videoPlaybackUstreamerConfig = config
    }
  }

  func session(_ session: EPSabrSession, didMint token: Data) {
    lock.sync { poToken = token.base64EncodedString() }
  }

  func session(_ session: EPSabrSession, callbackFailed error: EPError) {
    guard let gen = activeGeneration(session) else { return }
    lock.sync { callbackError = error }
    fail(error, generation: gen)
  }

  func session(_ session: EPSabrSession, streamFailed error: Error) {
    guard let gen = activeGeneration(session) else { return }
    let (retry, cbError): (Bool, EPError?) = lock.sync { (reusedSession && !producedAudio && callbackError == nil, callbackError) }
    if retry {
      onMain {
        guard !self.released, self.isCurrent(gen) else { return }
        self.restart(at: self.currentTime)
      }
      return
    }
    fail(cbError ?? EPError(.sabrStreamFailed, String(describing: error)), generation: gen)
  }
}
