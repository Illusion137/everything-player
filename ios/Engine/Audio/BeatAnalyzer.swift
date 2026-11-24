import AVFoundation

struct EPBeatGrid {
  var period: Double
  var anchor: Double
  var confidence: Double

  func beats(at time: Double) -> Double { (time - anchor) / period }

  func downbeat(atOrAfter time: Double) -> Double {
    let bars = ((time - anchor) / (4 * period) - 1e-6).rounded(.up)
    return anchor + bars * 4 * period
  }

  func downbeat(atOrBefore time: Double) -> Double {
    let bars = ((time - anchor) / (4 * period) + 1e-6).rounded(.down)
    return anchor + bars * 4 * period
  }
}

final class EPBeatAnalyzer {
  static let hop = 0.005

  private let lock = NSLock()
  private var blocks: [Int: SIMD2<Float>] = [:]
  private var latest = 0
  private var expected = -1.0
  private var sampleRate = 0.0
  private var acc = SIMD2<Float>(0, 0)
  private var accCount = 0
  private var accStart = 0.0
  private var low: Float = 0
  private var alpha: Float = 0

  func push(_ channels: [UnsafePointer<Float>], stride: Int, frames: Int, sampleRate sr: Double, at time: Double) {
    guard !channels.isEmpty, frames > 0, sr > 0, time.isFinite else { return }
    lock.lock(); defer { lock.unlock() }
    if sr != sampleRate || Swift.abs(time - expected) > 0.02 {
      sampleRate = sr
      alpha = Float(1 - Foundation.exp(-2 * Double.pi * 150 / sr))
      acc = .zero
      accCount = 0
      accStart = time
      low = 0
    }
    let per = max(1, Int(sr * Self.hop))
    let scale = 1 / Float(channels.count)
    for f in 0..<frames {
      var x: Float = 0
      for c in channels { x += c[f * stride] }
      x *= scale
      low += alpha * (x - low)
      acc += SIMD2(x * x, low * low)
      accCount += 1
      if accCount == per {
        let key = Int((accStart / Self.hop).rounded())
        blocks[key] = acc / Float(per)
        latest = max(latest, key)
        accStart += Double(per) / sr
        acc = .zero
        accCount = 0
      }
    }
    expected = time + Double(frames) / sr
    if blocks.count > 120_000 {
      let floor = latest - 60_000
      blocks = blocks.filter { $0.key >= floor }
    }
  }

  func push(_ buffer: AVAudioPCMBuffer, at time: Double) {
    guard let data = buffer.floatChannelData else { return }
    let channels = Int(buffer.format.channelCount)
    if buffer.format.isInterleaved {
      push((0..<channels).map { UnsafePointer(data[0].advanced(by: $0)) }, stride: channels, frames: Int(buffer.frameLength), sampleRate: buffer.format.sampleRate, at: time)
    } else {
      push((0..<channels).map { UnsafePointer(data[$0]) }, stride: 1, frames: Int(buffer.frameLength), sampleRate: buffer.format.sampleRate, at: time)
    }
  }

  func push(_ list: UnsafeMutableAudioBufferListPointer, frames: Int, sampleRate: Double, at time: Double) {
    var channels: [UnsafePointer<Float>] = []
    var stride = 1
    for buffer in list {
      guard let raw = buffer.mData else { continue }
      let base = raw.assumingMemoryBound(to: Float.self)
      let n = max(1, Int(buffer.mNumberChannels))
      stride = n
      for c in 0..<n { channels.append(UnsafePointer(base.advanced(by: c))) }
    }
    push(channels, stride: stride, frames: frames, sampleRate: sampleRate, at: time)
  }

  func covered(from start: Double, to end: Double) -> Bool {
    let a = Int((start / Self.hop).rounded())
    let b = Int((end / Self.hop).rounded())
    guard b > a else { return false }
    lock.lock(); defer { lock.unlock() }
    var present = 0
    for i in a..<b where blocks[i] != nil { present += 1 }
    return Double(present) >= 0.9 * Double(b - a)
  }

  func grid(from start: Double, to end: Double) -> EPBeatGrid? {
    let a = Int((start / Self.hop).rounded())
    let n = Int(((end - start) / Self.hop).rounded())
    guard n >= 2000 else { return nil }
    var full = [Float](repeating: 0, count: n)
    var bass = [Float](repeating: 0, count: n)
    var present = 0
    lock.lock()
    var last = SIMD2<Float>(0, 0)
    for i in 0..<n {
      if let v = blocks[a + i] { last = v; present += 1 }
      full[i] = Foundation.log(1e-7 + last.x)
      bass[i] = Foundation.log(1e-7 + last.y)
    }
    lock.unlock()
    guard present >= 2000 else { return nil }
    return Self.estimate(full: full, bass: bass, origin: Double(a) * Self.hop)
  }

  private static func estimate(full: [Float], bass: [Float], origin: Double) -> EPBeatGrid? {
    let n = full.count
    let hop = Self.hop
    var onset = [Double](repeating: 0, count: n)
    var bassOnset = [Double](repeating: 0, count: n)
    for i in 2..<n {
      let b = Double(max(0, bass[i] - bass[i - 2]))
      bassOnset[i] = b
      onset[i] = b + 0.5 * Double(max(0, full[i] - full[i - 2]))
    }
    var prefix = [Double](repeating: 0, count: n + 1)
    for i in 0..<n { prefix[i + 1] = prefix[i] + onset[i] }
    let radius = 50
    var env = [Double](repeating: 0, count: n)
    for i in 0..<n {
      let lo = max(0, i - radius), hi = min(n, i + radius + 1)
      env[i] = max(0, onset[i] - (prefix[hi] - prefix[lo]) / Double(hi - lo))
    }
    let total = env.reduce(0, +)
    guard total > 0 else { return nil }

    let minLag = Int((60.0 / 180.0 / hop).rounded(.down))
    let maxLag = Int((60.0 / 70.0 / hop).rounded(.up))
    guard n > maxLag * 4 else { return nil }
    var bestLag = 0
    var bestScore = -Double.infinity
    for lag in minLag...maxLag {
      var sum = 0.0
      for i in 0..<(n - lag) { sum += env[i] * env[i + lag] }
      let bpm = 60.0 / (Double(lag) * hop)
      let prior = Foundation.exp(-0.5 * Foundation.pow(Foundation.log2(bpm / 120.0) / 0.8, 2))
      let score = sum / Double(n - lag) * prior
      if score > bestScore { bestScore = score; bestLag = lag }
    }
    guard bestLag > 0 else { return nil }

    func comb(_ period: Double) -> (Double, Double) {
      let w = 2 * Double.pi * hop / period
      let (cr, ci) = (Foundation.cos(w), Foundation.sin(w))
      var zr = 1.0, zi = 0.0, re = 0.0, im = 0.0
      for i in 0..<n {
        re += env[i] * zr
        im += env[i] * zi
        let nr = zr * cr - zi * ci
        zi = zr * ci + zi * cr
        zr = nr
      }
      return (Foundation.sqrt(re * re + im * im) / total, Foundation.atan2(im, re))
    }

    var period = Double(bestLag) * hop
    var best = comb(period)
    for (span, step) in [(0.04, 0.0005), (0.0006, 0.00002)] {
      let center = period
      var k = -span
      while k <= span {
        let p = center * (1 + k)
        let r = comb(p)
        if r.0 > best.0 { best = r; period = p }
        k += step
      }
    }

    var phase = best.1 / (2 * Double.pi) * period
    phase = phase.truncatingRemainder(dividingBy: period)
    if phase < 0 { phase += period }
    let first = origin + phase

    var bestBar = 0
    var barScore = -1.0
    for k in 0..<4 {
      var sum = 0.0
      var t = phase + Double(k) * period
      while t < Double(n) * hop {
        let c = Int((t / hop).rounded())
        var peak = 0.0
        for j in max(0, c - 2)...min(n - 1, c + 2) { peak = max(peak, bassOnset[j]) }
        sum += peak
        t += 4 * period
      }
      if sum > barScore { barScore = sum; bestBar = k }
    }
    return EPBeatGrid(period: period, anchor: first + Double(bestBar) * period, confidence: best.0)
  }
}
