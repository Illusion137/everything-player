import AVFoundation

final class EPAudioGraph {
  static let shared = EPAudioGraph()

  let engine = AVAudioEngine()
  let bus = AVAudioMixerNode()
  let eq = AVAudioUnitEQ(numberOfBands: EPEqualizer.frequencies.count)
  private let renderers = NSHashTable<EPAudioRenderer>.weakObjects()
  private var idleWork: DispatchWorkItem?

  private init() {
    for (i, band) in eq.bands.enumerated() {
      band.filterType = .parametric
      band.frequency = EPEqualizer.frequencies[i]
      band.bandwidth = 1.0
      band.gain = 0
      band.bypass = false
    }
    engine.attach(bus)
    engine.attach(eq)
    engine.connect(bus, to: eq, format: nil)
    engine.connect(eq, to: engine.mainMixerNode, format: nil)
    NotificationCenter.default.addObserver(
      forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
    ) { [weak self] _ in self?.recoverAfterConfigurationChange() }
  }

  func setEqualizer(_ gains: [Float]) {
    for (i, band) in eq.bands.enumerated() where i < gains.count {
      band.gain = max(EPEqualizer.minGain, min(EPEqualizer.maxGain, gains[i]))
    }
  }

  func register(_ renderer: EPAudioRenderer) {
    renderers.add(renderer)
  }

  func unregister(_ renderer: EPAudioRenderer) {
    renderers.remove(renderer)
    scheduleIdleCheck()
  }

  @discardableResult
  func ensureRunning() -> Bool {
    idleWork?.cancel()
    idleWork = nil
    if engine.isRunning { return true }
    do {
      engine.prepare()
      try engine.start()
      return true
    } catch {
      try? AVAudioSession.sharedInstance().setActive(true)
      return (try? engine.start()) != nil
    }
  }

  func scheduleIdleCheck() {
    idleWork?.cancel()
    let work = DispatchWorkItem { [weak self] in
      guard let self else { return }
      if !self.renderers.allObjects.contains(where: { $0.isRendering }) { self.engine.pause() }
    }
    idleWork = work
    DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: work)
  }

  private func recoverAfterConfigurationChange() {
    guard renderers.allObjects.contains(where: { $0.wantsToPlay }) else { return }
    guard ensureRunning() else { return }
    renderers.allObjects.forEach { $0.resumeAfterEngineRestart() }
  }
}

final class EPAudioRenderer {
  private let graph = EPAudioGraph.shared
  private let node = AVAudioPlayerNode()
  private let timePitch = AVAudioUnitTimePitch()
  private let lock = NSLock()
  private var format: AVAudioFormat?
  private var baseSeconds: Double = 0
  private var scheduledFrames: AVAudioFramePosition = 0
  private var lastPlayedFrames: AVAudioFramePosition = 0
  private var generation = 0
  private var starved = false
  private var ended = false
  private(set) var wantsToPlay = false
  private var watchdog: DispatchSourceTimer?

  var onStarved: (() -> Void)?
  var onResumed: (() -> Void)?
  var onFinished: (() -> Void)?

  var volume: Float {
    get { node.volume }
    set { node.volume = newValue }
  }

  var rate: Float {
    get { timePitch.rate }
    set { timePitch.rate = max(0.25, min(4, newValue)) }
  }

  var isRendering: Bool { wantsToPlay && node.isPlaying }

  init() {
    graph.engine.attach(node)
    graph.engine.attach(timePitch)
    graph.register(self)
  }

  deinit {
    watchdog?.cancel()
    node.stop()
    graph.engine.detach(timePitch)
    graph.engine.detach(node)
  }

  func release() {
    watchdog?.cancel()
    watchdog = nil
    wantsToPlay = false
    lock.lock(); generation += 1; lock.unlock()
    node.stop()
    graph.unregister(self)
  }

  func reset(at seconds: Double) {
    lock.lock()
    generation += 1
    baseSeconds = seconds
    scheduledFrames = 0
    lastPlayedFrames = 0
    ended = false
    starved = false
    lock.unlock()
    node.stop()
  }

  var position: Double {
    lock.lock()
    defer { lock.unlock() }
    guard let format else { return baseSeconds }
    let played = min(playedFramesLocked(), scheduledFrames)
    return baseSeconds + Double(max(0, played)) / format.sampleRate
  }

  var aheadSeconds: Double {
    lock.lock()
    defer { lock.unlock() }
    guard let format else { return 0 }
    return Double(max(0, scheduledFrames - playedFramesLocked())) / format.sampleRate
  }

  private func playedFramesLocked() -> AVAudioFramePosition {
    guard node.isPlaying, let renderTime = node.lastRenderTime, renderTime.isSampleTimeValid,
          let playerTime = node.playerTime(forNodeTime: renderTime) else { return lastPlayedFrames }
    lastPlayedFrames = max(lastPlayedFrames, playerTime.sampleTime)
    return lastPlayedFrames
  }

  func schedule(_ buffer: AVAudioPCMBuffer) {
    if format == nil || format!.channelCount != buffer.format.channelCount || format!.sampleRate != buffer.format.sampleRate {
      connect(buffer.format)
    }
    lock.lock()
    scheduledFrames += AVAudioFramePosition(buffer.frameLength)
    lock.unlock()
    node.scheduleBuffer(buffer, completionHandler: nil)
  }

  func finishScheduling() {
    guard let format, let sentinel = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1) else {
      onFinished?()
      return
    }
    sentinel.frameLength = 1
    lock.lock()
    ended = true
    let gen = generation
    lock.unlock()
    if wantsToPlay && !node.isPlaying { startNode() }
    node.scheduleBuffer(sentinel, completionCallbackType: .dataPlayedBack) { [weak self] _ in
      guard let self else { return }
      self.lock.lock()
      let current = self.generation
      self.lock.unlock()
      guard current == gen else { return }
      DispatchQueue.main.async { self.onFinished?() }
    }
  }

  func play() {
    wantsToPlay = true
    startWatchdog()
    if aheadSeconds > 0 || ended { startNode() }
  }

  func pause() {
    wantsToPlay = false
    node.pause()
    graph.scheduleIdleCheck()
  }

  func resumeAfterEngineRestart() {
    if wantsToPlay && !starved { node.play() }
  }

  private func startNode() {
    guard graph.ensureRunning() else { return }
    if !node.isPlaying { node.play() }
  }

  private func connect(_ newFormat: AVAudioFormat) {
    let engine = graph.engine
    engine.disconnectNodeOutput(node)
    engine.disconnectNodeOutput(timePitch)
    engine.connect(node, to: timePitch, format: newFormat)
    engine.connect(timePitch, to: graph.bus, fromBus: 0, toBus: graph.bus.nextAvailableInputBus, format: newFormat)
    lock.lock()
    format = newFormat
    lock.unlock()
  }

  private func startWatchdog() {
    guard watchdog == nil else { return }
    let timer = DispatchSource.makeTimerSource(queue: .main)
    timer.schedule(deadline: .now() + 0.05, repeating: 0.05)
    timer.setEventHandler { [weak self] in self?.tick() }
    watchdog = timer
    timer.resume()
  }

  private func tick() {
    guard wantsToPlay else { return }
    let ahead = aheadSeconds
    lock.lock()
    let isEnded = ended
    lock.unlock()
    if !starved && !isEnded && ahead < 0.03 && format != nil {
      starved = true
      node.pause()
      onStarved?()
    } else if starved && (ahead >= 0.75 || isEnded) {
      starved = false
      startNode()
      onResumed?()
    } else if !starved && !node.isPlaying && (ahead > 0 || isEnded) {
      startNode()
    }
  }
}
