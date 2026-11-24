const HOP = 0.005

export interface BeatGrid {
  period: number
  anchor: number
  confidence: number
}

export function downbeatAtOrAfter(grid: BeatGrid, time: number): number {
  const bars = Math.ceil((time - grid.anchor) / (4 * grid.period) - 1e-6)
  return grid.anchor + bars * 4 * grid.period
}

export function downbeatAtOrBefore(grid: BeatGrid, time: number): number {
  const bars = Math.floor((time - grid.anchor) / (4 * grid.period) + 1e-6)
  return grid.anchor + bars * 4 * grid.period
}

export class BeatAnalyzer {
  private readonly full = new Map<number, number>()
  private readonly bass = new Map<number, number>()
  private latest = 0
  private expected = -1
  private sampleRate = 0
  private accFull = 0
  private accBass = 0
  private accCount = 0
  private accStart = 0
  private low = 0
  private alpha = 0

  push(channels: Float32Array[], frames: number, sampleRate: number, at: number, tolerance = 0.02): void {
    if (channels.length === 0 || frames <= 0 || !(sampleRate > 0) || !Number.isFinite(at)) return
    if (sampleRate !== this.sampleRate || Math.abs(at - this.expected) > tolerance) {
      this.sampleRate = sampleRate
      this.alpha = 1 - Math.exp((-2 * Math.PI * 150) / sampleRate)
      this.accFull = 0
      this.accBass = 0
      this.accCount = 0
      this.accStart = at
      this.low = 0
    }
    const per = Math.max(1, Math.floor(sampleRate * HOP))
    const scale = 1 / channels.length
    for (let f = 0; f < frames; f++) {
      let x = 0
      for (const c of channels) x += c[f] ?? 0
      x *= scale
      this.low += this.alpha * (x - this.low)
      this.accFull += x * x
      this.accBass += this.low * this.low
      this.accCount += 1
      if (this.accCount === per) {
        const key = Math.round(this.accStart / HOP)
        this.full.set(key, this.accFull / per)
        this.bass.set(key, this.accBass / per)
        this.latest = Math.max(this.latest, key)
        this.accStart += per / sampleRate
        this.accFull = 0
        this.accBass = 0
        this.accCount = 0
      }
    }
    this.expected = this.accStart + this.accCount / sampleRate
    if (this.full.size > 120_000) {
      const floor = this.latest - 60_000
      for (const key of this.full.keys()) {
        if (key < floor) {
          this.full.delete(key)
          this.bass.delete(key)
        }
      }
    }
  }

  covered(from: number, to: number): boolean {
    const a = Math.round(from / HOP)
    const b = Math.round(to / HOP)
    if (b <= a) return false
    let present = 0
    for (let i = a; i < b; i++) if (this.full.has(i)) present++
    return present >= 0.9 * (b - a)
  }

  grid(from: number, to: number): BeatGrid | undefined {
    const a = Math.round(from / HOP)
    const n = Math.round((to - from) / HOP)
    if (n < 2000) return undefined
    const full = new Float64Array(n)
    const bass = new Float64Array(n)
    let present = 0
    let lastFull = 0
    let lastBass = 0
    for (let i = 0; i < n; i++) {
      const f = this.full.get(a + i)
      if (f !== undefined) {
        lastFull = f
        lastBass = this.bass.get(a + i) ?? 0
        present++
      }
      full[i] = Math.log(1e-7 + lastFull)
      bass[i] = Math.log(1e-7 + lastBass)
    }
    if (present < 2000) return undefined
    return estimate(full, bass, a * HOP)
  }
}

function estimate(full: Float64Array, bass: Float64Array, origin: number): BeatGrid | undefined {
  const n = full.length
  const onset = new Float64Array(n)
  const bassOnset = new Float64Array(n)
  for (let i = 2; i < n; i++) {
    const b = Math.max(0, bass[i]! - bass[i - 2]!)
    bassOnset[i] = b
    onset[i] = b + 0.5 * Math.max(0, full[i]! - full[i - 2]!)
  }
  const prefix = new Float64Array(n + 1)
  for (let i = 0; i < n; i++) prefix[i + 1] = prefix[i]! + onset[i]!
  const radius = 50
  const env = new Float64Array(n)
  let total = 0
  for (let i = 0; i < n; i++) {
    const lo = Math.max(0, i - radius)
    const hi = Math.min(n, i + radius + 1)
    env[i] = Math.max(0, onset[i]! - (prefix[hi]! - prefix[lo]!) / (hi - lo))
    total += env[i]!
  }
  if (!(total > 0)) return undefined

  const minLag = Math.floor(60 / 180 / HOP)
  const maxLag = Math.ceil(60 / 70 / HOP)
  if (n <= maxLag * 4) return undefined
  let bestLag = 0
  let bestScore = -Infinity
  for (let lag = minLag; lag <= maxLag; lag++) {
    let sum = 0
    for (let i = 0; i < n - lag; i++) sum += env[i]! * env[i + lag]!
    const bpm = 60 / (lag * HOP)
    const prior = Math.exp(-0.5 * Math.pow(Math.log2(bpm / 120) / 0.8, 2))
    const score = (sum / (n - lag)) * prior
    if (score > bestScore) {
      bestScore = score
      bestLag = lag
    }
  }
  if (bestLag === 0) return undefined

  const comb = (period: number): [number, number] => {
    const w = (2 * Math.PI * HOP) / period
    const cr = Math.cos(w)
    const ci = Math.sin(w)
    let zr = 1
    let zi = 0
    let re = 0
    let im = 0
    for (let i = 0; i < n; i++) {
      re += env[i]! * zr
      im += env[i]! * zi
      const nr = zr * cr - zi * ci
      zi = zr * ci + zi * cr
      zr = nr
    }
    return [Math.sqrt(re * re + im * im) / total, Math.atan2(im, re)]
  }

  let period = bestLag * HOP
  let best = comb(period)
  for (const [span, step] of [
    [0.04, 0.0005],
    [0.0006, 0.00002],
  ] as const) {
    const center = period
    for (let k = -span; k <= span; k += step) {
      const p = center * (1 + k)
      const r = comb(p)
      if (r[0] > best[0]) {
        best = r
        period = p
      }
    }
  }

  let phase = ((best[1] / (2 * Math.PI)) * period) % period
  if (phase < 0) phase += period

  let bestBar = 0
  let barScore = -1
  for (let k = 0; k < 4; k++) {
    let sum = 0
    for (let t = phase + k * period; t < n * HOP; t += 4 * period) {
      const c = Math.round(t / HOP)
      let peak = 0
      for (let j = Math.max(0, c - 2); j <= Math.min(n - 1, c + 2); j++) peak = Math.max(peak, bassOnset[j]!)
      sum += peak
    }
    if (sum > barScore) {
      barScore = sum
      bestBar = k
    }
  }
  return { period, anchor: origin + phase + bestBar * period, confidence: best[0] }
}
