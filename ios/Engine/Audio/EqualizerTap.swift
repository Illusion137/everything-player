import AVFoundation
import MediaToolbox

final class EPEqualizerSettings {
  static let shared = EPEqualizerSettings()

  private let lock = NSLock()
  private var gains = [Float](repeating: 0, count: EPEqualizer.frequencies.count)
  private(set) var version = 0

  var bands: [Float] {
    lock.lock(); defer { lock.unlock() }
    return gains
  }

  func set(_ newGains: [Float]) {
    lock.lock()
    for i in 0..<gains.count { gains[i] = i < newGains.count ? max(EPEqualizer.minGain, min(EPEqualizer.maxGain, newGains[i])) : 0 }
    version += 1
    lock.unlock()
    EPAudioGraph.shared.setEqualizer(bands)
  }

  func snapshot() -> (Int, [Float]) {
    lock.lock(); defer { lock.unlock() }
    return (version, gains)
  }
}

final class EPBlendControl {
  var level: Float = 0
  var metered = false
  var bassCut: Float = 0
}

private final class EPTapContext {
  let blend: EPBlendControl
  let bandCount = EPEqualizer.frequencies.count
  var sampleRate: Double = 44100
  var channels = 2
  var version = -1
  var flat = true
  var coeffs: UnsafeMutablePointer<Double>
  var state: UnsafeMutablePointer<Double>
  var shelf: UnsafeMutablePointer<Double>
  var shelfState: UnsafeMutablePointer<Double>
  var shelfCut: Float = -1
  var shelving = false

  init(blend: EPBlendControl) {
    self.blend = blend
    coeffs = .allocate(capacity: bandCount * 5)
    coeffs.initialize(repeating: 0, count: bandCount * 5)
    state = .allocate(capacity: 8 * bandCount * 4)
    state.initialize(repeating: 0, count: 8 * bandCount * 4)
    shelf = .allocate(capacity: 5)
    shelf.initialize(repeating: 0, count: 5)
    shelfState = .allocate(capacity: 8 * 4)
    shelfState.initialize(repeating: 0, count: 8 * 4)
  }

  deinit {
    coeffs.deallocate()
    state.deallocate()
    shelf.deallocate()
    shelfState.deallocate()
  }

  func refreshShelf() -> Bool {
    let cut = blend.bassCut
    let active = cut > 0.001
    if active && !shelving { shelfState.update(repeating: 0, count: 8 * 4) }
    shelving = active
    guard active, cut != shelfCut else { return active }
    shelfCut = cut
    let a: Double = Foundation.pow(10.0, Double(EPBlend.bassCutGain * cut) / 40.0)
    let w: Double = 2.0 * Double.pi * Double(EPBlend.bassFrequency) / sampleRate
    let cw: Double = Foundation.cos(w)
    let beta: Double = 2.0 * Foundation.sqrt(a) * Foundation.sin(w) / 2.0 * Foundation.sqrt(2.0)
    let a0: Double = (a + 1) + (a - 1) * cw + beta
    shelf[0] = a * ((a + 1) - (a - 1) * cw + beta) / a0
    shelf[1] = 2 * a * ((a - 1) - (a + 1) * cw) / a0
    shelf[2] = a * ((a + 1) - (a - 1) * cw - beta) / a0
    shelf[3] = -2 * ((a - 1) + (a + 1) * cw) / a0
    shelf[4] = ((a + 1) + (a - 1) * cw - beta) / a0
    return true
  }

  func meter(_ buffers: UnsafeMutableAudioBufferListPointer, frames: Int) {
    var sum: Double = 0
    var count = 0
    for buffer in buffers {
      guard let raw = buffer.mData else { continue }
      let samples = raw.assumingMemoryBound(to: Float.self)
      let total = frames * max(1, Int(buffer.mNumberChannels))
      for i in 0..<total { sum += Double(samples[i] * samples[i]) }
      count += total
    }
    guard count > 0 else { return }
    blend.level = Float(Foundation.sqrt(sum / Double(count)))
    blend.metered = true
  }

  func refresh() {
    guard EPEqualizerSettings.shared.version != version else { return }
    let (v, gains) = EPEqualizerSettings.shared.snapshot()
    version = v
    flat = gains.allSatisfy { Swift.abs($0) < 0.01 }
    for (i, f) in EPEqualizer.frequencies.enumerated() {
      let g = Double(gains[i])
      let a: Double = Foundation.pow(10.0, g / 40.0)
      let w: Double = 2.0 * Double.pi * Double(f) / sampleRate
      let alpha: Double = Foundation.sin(w) / (2.0 * 1.41)
      let cw: Double = Foundation.cos(w)
      let a0: Double = 1.0 + alpha / a
      let base = i * 5
      coeffs[base] = (1 + alpha * a) / a0
      coeffs[base + 1] = (-2 * cw) / a0
      coeffs[base + 2] = (1 - alpha * a) / a0
      coeffs[base + 3] = (-2 * cw) / a0
      coeffs[base + 4] = (1 - alpha / a) / a0
    }
  }
}

enum EPEqualizerTap {
  static func audioMix(for item: AVPlayerItem, blend: EPBlendControl) -> AVAudioMix? {
    guard let audioTrack = item.asset.tracks(withMediaType: .audio).first else { return nil }
    let context = EPTapContext(blend: blend)
    var callbacks = MTAudioProcessingTapCallbacks(
      version: kMTAudioProcessingTapCallbacksVersion_0,
      clientInfo: Unmanaged.passRetained(context).toOpaque(),
      init: { _, clientInfo, storageOut in storageOut.pointee = clientInfo },
      finalize: { tap in Unmanaged<EPTapContext>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).release() },
      prepare: { tap, _, format in
        let ctx = Unmanaged<EPTapContext>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
        ctx.sampleRate = format.pointee.mSampleRate
        ctx.channels = min(8, max(1, Int(format.pointee.mChannelsPerFrame)))
        ctx.version = -1
        ctx.state.update(repeating: 0, count: 8 * ctx.bandCount * 4)
        ctx.shelfState.update(repeating: 0, count: 8 * 4)
        ctx.shelfCut = -1
      },
      unprepare: nil,
      process: { tap, frames, _, bufferList, framesOut, flagsOut in
        guard MTAudioProcessingTapGetSourceAudio(tap, frames, bufferList, flagsOut, nil, framesOut) == noErr else { return }
        let ctx = Unmanaged<EPTapContext>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
        ctx.refresh()
        let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
        let n = Int(framesOut.pointee)
        ctx.meter(buffers, frames: n)
        let shelving = ctx.refreshShelf()
        guard !ctx.flat || shelving else { return }
        let bands = ctx.bandCount
        let flat = ctx.flat
        let sh = ctx.shelf
        for (bi, buffer) in buffers.enumerated() {
          guard let raw = buffer.mData else { continue }
          let samples = raw.assumingMemoryBound(to: Float.self)
          let interleavedChannels = Int(buffer.mNumberChannels)
          for ch in 0..<max(1, interleavedChannels) {
            let channel = min(7, bi * max(1, interleavedChannels) + ch)
            let st = ctx.state.advanced(by: channel * bands * 4)
            let ss = ctx.shelfState.advanced(by: channel * 4)
            var i = ch
            let stride = max(1, interleavedChannels)
            while i < n * stride {
              var x = Double(samples[i])
              for b in 0..<bands where !flat {
                let c = ctx.coeffs.advanced(by: b * 5)
                let s = st.advanced(by: b * 4)
                let y = c[0] * x + c[1] * s[0] + c[2] * s[1] - c[3] * s[2] - c[4] * s[3]
                s[1] = s[0]; s[0] = x
                s[3] = s[2]; s[2] = y
                x = y
              }
              if shelving {
                let y = sh[0] * x + sh[1] * ss[0] + sh[2] * ss[1] - sh[3] * ss[2] - sh[4] * ss[3]
                ss[1] = ss[0]; ss[0] = x
                ss[3] = ss[2]; ss[2] = y
                x = y
              }
              samples[i] = Float(max(-1, min(1, x)))
              i += stride
            }
          }
        }
      })
    var tap: MTAudioProcessingTap?
    guard MTAudioProcessingTapCreate(kCFAllocatorDefault, &callbacks, kMTAudioProcessingTapCreationFlag_PreEffects, &tap) == noErr,
          let tap else {
      Unmanaged<EPTapContext>.fromOpaque(callbacks.clientInfo!).release()
      return nil
    }
    let params = AVMutableAudioMixInputParameters(track: audioTrack)
    params.audioTapProcessor = tap
    let mix = AVMutableAudioMix()
    mix.inputParameters = [params]
    return mix
  }
}
