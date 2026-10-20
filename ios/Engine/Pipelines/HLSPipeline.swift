import AVFoundation

private struct EPHLSUnsupported: Error {
  let reason: String
}

private final class EPHLSTimeline: @unchecked Sendable {
  private let lock = NSLock()
  private var offsets: [Int: Double] = [:]

  func reset() { lock.sync { offsets.removeAll() } }

  func offset(discontinuity: Int, segmentStart: Double, firstPts: Double, segmentDuration: Double) -> Double {
    lock.sync {
      let tolerance = max(3, segmentDuration * 2)
      if let o = offsets[discontinuity], Swift.abs(firstPts + o - segmentStart) <= tolerance { return o }
      let o = segmentStart - firstPts
      offsets[discontinuity] = o
      return o
    }
  }
}

private final class EPCompressedVideoQueue: @unchecked Sendable {
  struct Item {
    var packet: EPElementaryPacket
    var config: EPVideoConfig
  }

  private let lock = NSLock()
  private var items: [Item] = []
  private var bytes = 0
  private var lastPts: Double = -.infinity
  private var needsSync = false
  private(set) var ended = false

  func push(_ packets: [EPElementaryPacket], config: EPVideoConfig) {
    lock.sync {
      for p in packets {
        if needsSync {
          guard p.isSync, p.pts > lastPts - 0.001 else { continue }
          needsSync = false
        }
        items.append(Item(packet: p, config: config))
        bytes += p.data.count
        lastPts = max(lastPts, p.pts)
      }
    }
  }

  func pop() -> Item? {
    lock.sync {
      guard !items.isEmpty else { return nil }
      let item = items.removeFirst()
      bytes -= item.packet.data.count
      return item
    }
  }

  func requireSync() { lock.sync { needsSync = true } }

  func finish() { lock.sync { ended = true } }

  func flush() {
    lock.sync {
      items.removeAll()
      bytes = 0
      lastPts = -.infinity
      needsSync = false
      ended = false
    }
  }

  var isDrained: Bool { lock.sync { items.isEmpty && ended } }
  var byteCount: Int { lock.sync { bytes } }
  var queuedThrough: Double? { lock.sync { lastPts.isFinite ? lastPts : nil } }
}

private final class EPHLSSegmentDemuxer {
  private var ts = EPMPEGTSDemuxer()
  private var mp4: EPFMP4Demuxer?
  private var map: EPHLSMap?

  func reset() {
    ts = EPMPEGTSDemuxer()
    mp4 = nil
    map = nil
  }

  func needsMap(_ segment: EPHLSSegment) -> Bool {
    guard let m = segment.map else { return false }
    return m != map
  }

  func setMap(_ m: EPHLSMap, data: Data) {
    let d = EPFMP4Demuxer()
    _ = d.feed(data)
    mp4 = d
    map = m
  }

  func demux(_ data: Data) -> EPDemuxedMedia {
    if let mp4, map != nil { return fmp4(mp4, data) }
    if data.count >= 3, data[data.startIndex] == 0x49, data[data.startIndex + 1] == 0x44, data[data.startIndex + 2] == 0x33 {
      return EPADTS.packedAudio(data)
    }
    if data.count >= 2, data[data.startIndex] == 0xFF, data[data.startIndex + 1] & 0xF6 == 0xF0 {
      return EPADTS.packedAudio(data)
    }
    return ts.demux(data)
  }

  private func fmp4(_ demuxer: EPFMP4Demuxer, _ data: Data) -> EPDemuxedMedia {
    var media = EPDemuxedMedia()
    let samples = demuxer.feed(data)
    for track in demuxer.tracks {
      let scale = Double(track.timescale)
      let mine = samples.filter { $0.trackId == track.trackId || demuxer.tracks.count == 1 }
      switch track.codec {
      case let .avc(avcC, width, height):
        media.videoConfig = .avcC(avcC, width: width, height: height)
        media.video = mine.map {
          EPElementaryPacket(pts: Double($0.pts) / scale, dts: Double($0.dts) / scale, duration: Double($0.duration) / scale, isSync: $0.isSync, data: $0.data)
        }
      case let .aac(asc, sampleRate, channels):
        media.audioConfig = EPAACConfig(asc: asc, sampleRate: sampleRate > 0 ? sampleRate : scale, channels: max(1, channels))
        media.audio = mine.map {
          EPElementaryPacket(pts: Double($0.pts) / scale, dts: Double($0.dts) / scale, duration: Double($0.duration) / scale, isSync: true, data: $0.data)
        }
      case let .unsupported(name):
        media.unsupported = name
      }
    }
    return media
  }
}

final class EPHLSPipeline: EPPipeline, EPPipelineDelegate {
  let track: EPTrack
  weak var delegate: EPPipelineDelegate?
  private(set) var status: EPPipelineStatus = .idle

  private let options: EPSetupOptions
  private let localURL: URL?
  private let loader: EPHLSLoader
  private let renderer = EPAudioRenderer()
  private let frames: EPDecodedFrameQueue?
  private let videoQueue = EPCompressedVideoQueue()
  private let timeline = EPHLSTimeline()
  private let lock = NSLock()

  private var inner: EPPipeline?
  private var master: EPHLSMasterPlaylist?
  private var mediaPlaylists: [URL: EPHLSMediaPlaylist] = [:]
  private var lastMainPlaylist: EPHLSMediaPlaylist?
  private var variant: EPHLSVariant?
  private var audioRendition: URL?
  private var mainCarriesAudio = true
  private var qualityRange: EPVideoQualityRange
  private var manualVariant: Int?
  private var mainTask: Task<Void, Never>?
  private var audioTask: Task<Void, Never>?
  private var videoTask: Task<Void, Never>?
  private var audioDecoder: EPAACPacketDecoder?
  private let normalizer = EPPCMNormalizer()
  private var audioScheduledEnd: Double = 0
  private var scheduledAny = false
  private var generation = 0
  private var mainGeneration = 0
  private var frozenPosition: Double?
  private var playWhenReady = false
  private var knownDuration: Double?
  private var released = false
  private var volumeValue: Float = 1
  private var rateValue: Float = 1

  init(track: EPTrack, options: EPSetupOptions, localURL: URL?) {
    self.track = track
    self.options = options
    self.localURL = localURL
    self.qualityRange = options.videoQualityRange
    loader = EPHLSLoader(headers: track.requestHeaders)
    frames = options.enableVideo ? EPDecodedFrameQueue(capacity: 120) : nil
    knownDuration = track.duration
    frames?.clock = { [weak self] in self?.videoClock ?? 0 }
    renderer.onStarved = { [weak self] in self?.setStatus(.buffering) }
    renderer.onResumed = { [weak self] in
      guard let self, self.playWhenReady else { return }
      self.setStatus(.playing)
    }
    renderer.onFinished = { [weak self] in self?.setStatus(.ended) }
  }

  deinit {
    mainTask?.cancel()
    audioTask?.cancel()
    videoTask?.cancel()
  }

  var currentTime: Double {
    if let inner { return inner.currentTime }
    return lock.sync { frozenPosition } ?? renderer.position
  }

  private var videoClock: Double {
    renderer.position - AVAudioSession.sharedInstance().outputLatency
  }

  var mediaDuration: Double? { inner?.mediaDuration ?? lock.sync { knownDuration } }

  var bufferedTime: Double { inner?.bufferedTime ?? currentTime + renderer.aheadSeconds }

  var volume: Float {
    get { inner?.volume ?? volumeValue }
    set {
      volumeValue = newValue
      if let inner { inner.volume = newValue } else { renderer.volume = newValue }
    }
  }

  var rate: Float {
    get { inner?.rate ?? rateValue }
    set {
      rateValue = newValue
      if let inner { inner.rate = newValue } else { renderer.rate = newValue }
    }
  }

  var videoSource: EPVideoFrameSource? { inner.map { $0.videoSource } ?? frames }

  var videoQuality: EPVideoQualityState {
    if let inner { return inner.videoQuality }
    return lock.sync {
      EPVideoQualityState(qualities: videoVariantsLocked().map(Self.quality), selectedId: variant.map { Self.qualityId($0) }, auto: manualVariant == nil)
    }
  }

  func load(at position: Double) {
    restart(at: position)
  }

  func play() {
    playWhenReady = true
    if let inner { inner.play(); return }
    renderer.play()
    if status == .ready { setStatus(.playing) }
  }

  func pause() {
    playWhenReady = false
    if let inner { inner.pause(); return }
    renderer.pause()
    if status == .playing || status == .buffering { setStatus(.ready) }
  }

  func seek(to seconds: Double) {
    if let inner { inner.seek(to: seconds); return }
    restart(at: seconds)
  }

  func teardown() {
    released = true
    lock.sync { generation += 1 }
    cancelTasks()
    renderer.release()
    frames?.flush()
    videoQueue.flush()
    if let frames { EPVideoHub.shared.clearSourceIfCurrent(frames) }
    inner?.delegate = nil
    inner?.teardown()
  }

  func setVideoQuality(_ id: String?, range: EPVideoQualityRange) throws {
    if let inner {
      try inner.setVideoQuality(id, range: range)
      return
    }
    let target: Int? = try lock.sync {
      qualityRange = range
      guard let id else {
        manualVariant = nil
        return nil
      }
      guard let v = videoVariantsLocked().first(where: { Self.qualityId($0) == id }) else {
        throw EPError(.unknown, "Unknown video quality \(id)")
      }
      manualVariant = v.index
      return v.index
    }
    onMain {
      guard !self.released, self.master != nil, self.frames != nil else { return }
      let desired = target ?? self.lock.sync { self.autoVariantLocked()?.index }
      guard let desired, desired != self.lock.sync({ self.variant?.index }) else { return }
      if target != nil || self.scheduledAnyValue { self.switchVariant(to: desired) }
    }
  }

  func pipeline(_ pipeline: EPPipeline, didChange status: EPPipelineStatus) {
    guard !released else { return }
    self.status = status
    delegate?.pipeline(self, didChange: status)
  }

  func pipeline(_ pipeline: EPPipeline, didFail error: EPError) {
    guard !released else { return }
    status = pipeline.status
    delegate?.pipeline(self, didFail: error)
  }

  func pipelineDidUpdateDuration(_ pipeline: EPPipeline) {
    delegate?.pipelineDidUpdateDuration(self)
  }

  func pipelineDidChangeVideoQuality(_ pipeline: EPPipeline) {
    delegate?.pipelineDidChangeVideoQuality(self)
  }

  private static func qualityId(_ v: EPHLSVariant) -> String { "hls-\(v.index)" }

  private static func quality(_ v: EPHLSVariant) -> EPVideoQuality {
    EPVideoQuality(
      id: qualityId(v), width: v.width, height: v.height, fps: v.frameRate, bitrate: v.bandwidth,
      label: v.height.map { "\($0)p" } ?? "\(v.bandwidth / 1000) kbps",
      codec: v.codecs.first(where: EPHLSCodec.isVideo))
  }

  private func videoVariantsLocked() -> [EPHLSVariant] {
    guard frames != nil, let master else { return [] }
    return master.playableVideoVariants
  }

  private func autoVariantLocked() -> EPHLSVariant? {
    let candidates = videoVariantsLocked()
    let estimate = loader.bandwidthEstimate
    let budget = estimate > 0 ? Int(estimate * 0.75) : 2_500_000
    return qualityRange.pick(candidates, height: { $0.height }, bitrate: { $0.bandwidth }, budget: budget)
  }

  private func cancelTasks() {
    mainTask?.cancel()
    audioTask?.cancel()
    videoTask?.cancel()
    mainTask = nil
    audioTask = nil
    videoTask = nil
  }

  private func setStatus(_ new: EPPipelineStatus) {
    onMain {
      guard !self.released, self.inner == nil, self.status != new else { return }
      if case .failed = self.status { return }
      self.status = new
      self.delegate?.pipeline(self, didChange: new)
    }
  }

  private func isCurrent(_ gen: Int) -> Bool { lock.sync { gen == generation } }

  private func isCurrentMain(_ gen: Int, _ main: Int) -> Bool { lock.sync { gen == generation && main == mainGeneration } }

  private func fail(_ error: EPError, generation gen: Int) {
    onMain {
      guard !self.released, self.inner == nil, self.isCurrent(gen) else { return }
      var e = error
      e.trackId = self.track.id
      self.cancelTasks()
      self.renderer.pause()
      self.status = .failed(e.message)
      self.delegate?.pipeline(self, didFail: e)
    }
  }

  private func fallBack(at position: Double, reason: String, generation gen: Int) {
    onMain {
      guard !self.released, self.inner == nil, self.isCurrent(gen) else { return }
      NSLog("[EverythingPlayer] HLS falling back to AVPlayer: %@", reason)
      self.lock.sync { self.generation += 1 }
      self.cancelTasks()
      self.renderer.release()
      self.frames?.flush()
      if let frames = self.frames { EPVideoHub.shared.clearSourceIfCurrent(frames) }
      let fallback = EPAVPlayerPipeline(track: self.track, options: self.options, localURL: self.localURL)
      fallback.delegate = self
      fallback.volume = self.volumeValue
      fallback.rate = self.rateValue
      try? fallback.setVideoQuality(nil, range: self.qualityRange)
      self.inner = fallback
      fallback.load(at: position)
      if self.playWhenReady { fallback.play() }
    }
  }

  private func restart(at requested: Double) {
    let position = max(track.trimStart, requested)
    let gen: Int = lock.sync {
      generation += 1
      mainGeneration += 1
      frozenPosition = position
      audioScheduledEnd = position
      return generation
    }
    cancelTasks()
    lock.sync { scheduledAny = false }
    audioDecoder = nil
    timeline.reset()
    renderer.reset(at: position)
    frames?.flush()
    videoQueue.flush()
    setStatus(.loading)
    mainTask = Task.detached(priority: .userInitiated) { [weak self] in
      await self?.start(at: position, generation: gen)
    }
  }

  private func start(at requested: Double, generation gen: Int) async {
    var position = requested
    do {
      try await prepareRenditions()
      guard isCurrent(gen) else { return }
      let (main, audio, carries) = lock.sync { (variant?.uri ?? playlistURL, audioRendition, mainCarriesAudio) }
      let usesMain = carries || frames != nil
      let reference = try await mediaPlaylist(usesMain ? main : (audio ?? main))
      if usesMain { lock.sync { lastMainPlaylist = reference } }
      if !reference.ended, position <= track.trimStart + 0.001, !reference.segments.isEmpty {
        let edge = reference.segments[max(0, reference.segments.count - 3)].start
        position = edge
        await MainActor.run {
          guard self.isCurrent(gen) else { return }
          self.lock.sync {
            self.frozenPosition = edge
            self.audioScheduledEnd = edge
          }
          self.renderer.reset(at: edge)
        }
      }
      guard isCurrent(gen) else { return }
      let start = position
      if let audio, !carries {
        let t = Task.detached(priority: .userInitiated) { [weak self] in
          guard let self else { return }
          await self.runStream(url: audio, start: start, audioOnly: true, generation: gen, main: -1)
        }
        await MainActor.run { if self.isCurrent(gen) { self.audioTask = t } else { t.cancel() } }
      }
      if frames != nil {
        await MainActor.run {
          guard self.isCurrent(gen) else { return }
          self.videoTask = self.makeVideoTask(start: start, generation: gen)
        }
      }
      if usesMain {
        let mainGen = lock.sync { mainGeneration }
        await runStream(url: main, start: start, audioOnly: false, generation: gen, main: mainGen)
      }
    } catch let e as EPHLSUnsupported {
      fallBack(at: position, reason: e.reason, generation: gen)
    } catch is CancellationError {
    } catch {
      guard isCurrent(gen) else { return }
      fail(EPError.from(error, default: .sourceError), generation: gen)
    }
  }

  private var playlistURL: URL {
    localURL ?? URL(string: track.url ?? "") ?? URL(fileURLWithPath: "/")
  }

  private func prepareRenditions() async throws {
    if lock.sync({ master != nil || !mediaPlaylists.isEmpty }) { return }
    let url = playlistURL
    let parsed = try EPHLSParser.parse(try await loader.text(url), base: url)
    switch parsed {
    case let .media(playlist):
      try validate(playlist)
      lock.sync {
        mediaPlaylists[url] = playlist
        mainCarriesAudio = true
        if playlist.ended, knownDuration == nil { knownDuration = playlist.duration }
      }
    case let .master(m):
      if m.hasSessionKeySampleAES { throw EPHLSUnsupported(reason: "session key") }
      try lock.sync {
        master = m
        try chooseRenditionsLocked()
      }
    }
    onMain { self.delegate?.pipelineDidUpdateDuration(self) }
    if frames != nil { onMain { self.delegate?.pipelineDidChangeVideoQuality(self) } }
  }

  private func chooseRenditionsLocked() throws {
    guard let master else { return }
    if frames != nil, master.variants.contains(where: \.hasVideoCodec) {
      let pick = manualVariant.flatMap { i in master.variants.first { $0.index == i } } ?? autoVariantLocked()
      guard let pick else { throw EPHLSUnsupported(reason: "no H.264/AAC variant") }
      variant = pick
    } else {
      guard let pick = master.audioVariant else { throw EPHLSUnsupported(reason: "no AAC variant") }
      variant = pick
    }
    audioRendition = variant.flatMap { master.audioRendition(for: $0)?.uri }
    mainCarriesAudio = audioRendition == nil
  }

  private func validate(_ playlist: EPHLSMediaPlaylist) throws {
    if playlist.segments.contains(where: { $0.key.map { $0.method != .aes128 } ?? false }) {
      throw EPHLSUnsupported(reason: "encryption method")
    }
  }

  private func mediaPlaylist(_ url: URL, refresh: Bool = false, alignWith reference: EPHLSMediaPlaylist? = nil) async throws -> EPHLSMediaPlaylist {
    if !refresh, let cached = lock.sync({ mediaPlaylists[url] }) { return cached }
    guard case let .media(fresh) = try EPHLSParser.parse(try await loader.text(url), base: url) else {
      throw EPError(.sourceError, "Expected a media playlist")
    }
    try validate(fresh)
    let hadDuration = lock.sync { knownDuration != nil }
    let merged: EPHLSMediaPlaylist = lock.sync {
      var p = fresh
      if mediaPlaylists[url] == nil, !fresh.ended, let reference, !reference.segments.isEmpty {
        let shift: Double
        if let match = fresh.segments.first(where: { s in reference.segments.contains { $0.sequence == s.sequence } }),
           let ref = reference.segments.first(where: { $0.sequence == match.sequence }) {
          shift = ref.start - match.start
        } else {
          shift = reference.duration - fresh.duration
        }
        for i in p.segments.indices { p.segments[i].start += shift }
      } else if let old = mediaPlaylists[url], !fresh.ended || !old.ended {
        let shift: Double
        if let first = fresh.segments.first, let match = old.segments.first(where: { $0.sequence == first.sequence }) {
          shift = match.start - first.start
        } else {
          shift = old.duration - (fresh.segments.first?.start ?? 0)
        }
        for i in p.segments.indices { p.segments[i].start += shift }
      }
      mediaPlaylists[url] = p
      if p.ended, knownDuration == nil { knownDuration = p.duration }
      return p
    }
    if !hadDuration, lock.sync({ knownDuration != nil }) {
      onMain { self.delegate?.pipelineDidUpdateDuration(self) }
    }
    return merged
  }

  private func runStream(url: URL, start: Double, audioOnly: Bool, generation gen: Int, main: Int) async {
    let current: () -> Bool = { [weak self] in
      guard let self else { return false }
      return main < 0 ? self.isCurrent(gen) : self.isCurrentMain(gen, main)
    }
    let demuxer = EPHLSSegmentDemuxer()
    let carriesAudio = audioOnly || lock.sync { mainCarriesAudio }
    let wantsVideo = !audioOnly && frames != nil
    var playlistURL = url
    var currentVariant = lock.sync { variant?.index }
    do {
      var playlist = try await mediaPlaylist(playlistURL, alignWith: lock.sync { lastMainPlaylist })
      var index = playlist.index(containing: start) ?? 0
      var nextStart = playlist.segments.indices.contains(index) ? playlist.segments[index].start : start
      var checkedFirst = false
      while !Task.isCancelled, current() {
        try await waitForRoom(carriesAudio: carriesAudio, wantsVideo: wantsVideo, current: current)
        guard current() else { return }
        if wantsVideo, !audioOnly, let switched = lock.sync({ variantForNextSegmentLocked(current: currentVariant) }) {
          currentVariant = switched.index
          playlistURL = switched.uri
          let previous = playlist
          let nextSequence = index < previous.segments.count ? previous.segments[index].sequence : (previous.segments.last?.sequence ?? 0) + 1
          playlist = try await mediaPlaylist(playlistURL, alignWith: previous)
          index = (playlist.ended ? nil : playlist.segments.firstIndex { $0.sequence == nextSequence })
            ?? playlist.index(containing: nextStart + 0.05) ?? index
          demuxer.reset()
          videoQueue.requireSync()
          onMain { self.delegate?.pipelineDidChangeVideoQuality(self) }
        }
        if index >= playlist.segments.count {
          if playlist.ended { break }
          try await Task.sleep(nanoseconds: UInt64(max(1, playlist.targetDuration / 2) * 1_000_000_000))
          let last = playlist.segments.last?.sequence ?? -1
          playlist = try await mediaPlaylist(playlistURL, refresh: true)
          index = playlist.segments.firstIndex { $0.sequence > last } ?? playlist.segments.count
          continue
        }
        let segment = playlist.segments[index]
        if !audioOnly { lock.sync { lastMainPlaylist = playlist } }
        if demuxer.needsMap(segment), let map = segment.map {
          demuxer.setMap(map, data: try await loader.mapData(map, key: segment.key, sequence: segment.sequence))
        }
        let data = try await loader.segmentData(segment)
        guard current() else { return }
        let media = demuxer.demux(data)
        if let reason = media.unsupported, !scheduledAnyValue { throw EPHLSUnsupported(reason: reason) }
        if !checkedFirst {
          checkedFirst = true
          if carriesAudio, media.audioConfig == nil, media.audio.isEmpty, !scheduledAnyValue {
            throw EPHLSUnsupported(reason: "no AAC audio")
          }
        }
        let firstPts = (media.audio.map(\.pts) + media.video.map(\.pts)).min()
        let offset = firstPts.map {
          timeline.offset(discontinuity: segment.discontinuity, segmentStart: segment.start, firstPts: $0, segmentDuration: segment.duration)
        } ?? 0
        if carriesAudio, let config = media.audioConfig, !media.audio.isEmpty {
          let gated = try await scheduleAudio(media.audio, config: config, offset: offset, start: start, generation: gen)
          if gated { break }
        }
        if wantsVideo, let config = media.videoConfig, !media.video.isEmpty {
          let shifted = media.video.map { p -> EPElementaryPacket in
            var q = p
            q.pts += offset
            q.dts += offset
            return q
          }
          videoQueue.push(shifted, config: config)
        }
        nextStart = segment.start + segment.duration
        index += 1
        if let end = track.trimEnd(mediaDuration: lock.sync { knownDuration }), nextStart >= end + 0.5 { break }
      }
    } catch let e as EPHLSUnsupported {
      fallBack(at: currentTime, reason: e.reason, generation: gen)
      return
    } catch is CancellationError {
      return
    } catch {
      guard !Task.isCancelled, current() else { return }
      fail(EPError.from(error, default: .networkError), generation: gen)
      return
    }
    guard !Task.isCancelled, current() else { return }
    if wantsVideo { videoQueue.finish() }
    if carriesAudio {
      await MainActor.run {
        guard self.isCurrent(gen) else { return }
        if !self.scheduledAnyValue { self.lock.sync { self.frozenPosition = nil } }
        self.renderer.finishScheduling()
      }
    }
  }

  private var scheduledAnyValue: Bool { lock.sync { scheduledAny } }

  private func variantForNextSegmentLocked(current: Int?) -> EPHLSVariant? {
    guard master != nil else { return nil }
    let desired: EPHLSVariant?
    if let manual = manualVariant {
      desired = master?.variants.first { $0.index == manual }
    } else {
      desired = autoVariantLocked()
    }
    guard let desired, desired.index != current else { return nil }
    variant = desired
    return desired
  }

  private func waitForRoom(carriesAudio: Bool, wantsVideo: Bool, current: () -> Bool) async throws {
    let limit = options.forwardBufferSeconds
    while !Task.isCancelled, current() {
      let audioAhead = carriesAudio ? renderer.aheadSeconds : 0
      var videoAhead: Double = 0
      if wantsVideo, let through = videoQueue.queuedThrough { videoAhead = through - renderer.position }
      let bytesFull = wantsVideo && videoQueue.byteCount > options.maxBufferBytes
      if audioAhead <= limit && videoAhead <= limit && !bytesFull { return }
      try await Task.sleep(nanoseconds: 100_000_000)
    }
  }

  private func scheduleAudio(_ packets: [EPElementaryPacket], config: EPAACConfig, offset: Double, start: Double, generation gen: Int) async throws -> Bool {
    if audioDecoder?.config != config {
      let codecs = lock.sync { variant?.codecs ?? [] }
      audioDecoder = try EPAACPacketDecoder(config, heAAC: codecs.contains { $0 == "mp4a.40.5" || $0 == "mp4a.40.29" })
    }
    guard let decoder = audioDecoder else { return false }
    let end = track.trimEnd(mediaDuration: lock.sync { knownDuration })
    var floor = lock.sync { audioScheduledEnd }
    var batch: [AVAudioPCMBuffer] = []
    var gated = false
    for p in packets {
      let ts0 = p.pts + offset
      if ts0 + p.duration <= floor - 0.0005 { continue }
      guard var buffer = decoder.decode(p.data) else { continue }
      let sr = buffer.format.sampleRate
      var ts = ts0
      if ts < floor {
        let drop = Int(((floor - ts) * sr).rounded())
        guard drop < Int(buffer.frameLength), let trimmed = buffer.dropping(frames: drop) else { continue }
        buffer = trimmed
        ts = floor
      }
      if let end, ts + Double(buffer.frameLength) / sr > end {
        let keep = Int((end - ts) * sr)
        if keep > 0, keep < Int(buffer.frameLength) { buffer.frameLength = AVAudioFrameCount(keep) }
        if keep > 0, let n = normalizer.normalize(buffer) { batch.append(n) }
        gated = true
        break
      }
      floor = ts + Double(buffer.frameLength) / sr
      if let n = normalizer.normalize(buffer) { batch.append(n) }
    }
    lock.sync { audioScheduledEnd = max(audioScheduledEnd, floor) }
    if let combined = AVAudioPCMBuffer.concatenate(batch) {
      await MainActor.run { self.schedule(combined, generation: gen) }
    }
    return gated
  }

  private func schedule(_ buffer: AVAudioPCMBuffer, generation gen: Int) {
    guard isCurrent(gen), !released else { return }
    renderer.schedule(buffer)
    let first: Bool = lock.sync {
      defer { scheduledAny = true }
      if !scheduledAny { frozenPosition = nil }
      return !scheduledAny
    }
    guard first else { return }
    if playWhenReady {
      renderer.play()
      setStatus(.playing)
    } else {
      setStatus(.ready)
    }
  }

  private func makeVideoTask(start: Double, generation gen: Int) -> Task<Void, Never>? {
    guard let frames else { return nil }
    let main = lock.sync { mainGeneration }
    return Task.detached(priority: .userInitiated) { [weak self] in
      guard let self else { return }
      var decoder: EPH264Decoder?
      var config: EPVideoConfig?
      var reachedStart = false
      var gop: [EPElementaryPacket] = []
      func sample(_ p: EPElementaryPacket) -> EPMP4Sample {
        EPMP4Sample(dts: Int64((p.dts * 90000).rounded()), pts: Int64((p.pts * 90000).rounded()),
                    duration: Int64((p.duration * 90000).rounded()), isSync: p.isSync, data: p.data)
      }
      while !Task.isCancelled, self.isCurrentMain(gen, main) {
        if let last = frames.lastPts, last - self.videoClock > 1.0 {
          try? await Task.sleep(nanoseconds: 20_000_000)
          continue
        }
        guard let item = self.videoQueue.pop() else {
          if self.videoQueue.isDrained { break }
          try? await Task.sleep(nanoseconds: 20_000_000)
          continue
        }
        if item.config != config {
          decoder?.flush()
          decoder = nil
          config = item.config
          let output: (EPVideoFrame) -> Void = { [weak frames] frame in frames?.push(frame) }
          switch item.config {
          case let .avcC(avcC, width, height):
            decoder = try? EPH264Decoder(avcC: avcC, width: width, height: height, timescale: 90000, output: output)
          case let .parameterSets(sets):
            decoder = try? EPH264Decoder(parameterSets: sets, timescale: 90000, output: output)
          }
          if !item.packet.isSync, reachedStart { continue }
        }
        guard let decoder else { continue }
        let p = item.packet
        if !reachedStart {
          if p.isSync { gop.removeAll() }
          gop.append(p)
          guard p.pts >= start - 0.001 else { continue }
          reachedStart = true
          gop.forEach { decoder.decode(sample($0)) }
          gop.removeAll()
        } else {
          decoder.decode(sample(p))
        }
      }
      decoder?.flush()
    }
  }

  private func switchVariant(to index: Int) {
    let position = currentTime
    let (gen, main, carries): (Int, Int, Bool) = lock.sync {
      mainGeneration += 1
      if let v = master?.variants.first(where: { $0.index == index }) { variant = v }
      return (generation, mainGeneration, mainCarriesAudio)
    }
    mainTask?.cancel()
    videoTask?.cancel()
    videoQueue.flush()
    frames?.flush()
    delegate?.pipelineDidChangeVideoQuality(self)
    let url = lock.sync { variant?.uri ?? playlistURL }
    videoTask = makeVideoTask(start: position, generation: gen)
    _ = carries
    mainTask = Task.detached(priority: .userInitiated) { [weak self] in
      guard let self else { return }
      await self.runStream(url: url, start: position, audioOnly: false, generation: gen, main: main)
    }
  }
}
