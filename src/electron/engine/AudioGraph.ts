import {
  EQUALIZER_FREQUENCIES,
  EQUALIZER_MAX_GAIN,
  EQUALIZER_MIN_GAIN,
} from '../../types/enums'

const EQ_Q = 1.41

export class AudioGraph {
  private context: AudioContext | undefined
  private filters: BiquadFilterNode[] = []
  private input: GainNode | undefined
  private gains: number[] = EQUALIZER_FREQUENCIES.map(() => 0)

  private ensure(): AudioContext {
    if (this.context) return this.context
    const context = new AudioContext({ latencyHint: 'playback' })
    const input = context.createGain()
    let previous: AudioNode = input
    this.filters = EQUALIZER_FREQUENCIES.map((frequency, i) => {
      const filter = context.createBiquadFilter()
      filter.type = 'peaking'
      filter.frequency.value = frequency
      filter.Q.value = EQ_Q
      filter.gain.value = this.gains[i] ?? 0
      previous.connect(filter)
      previous = filter
      return filter
    })
    previous.connect(context.destination)
    this.context = context
    this.input = input
    return context
  }

  connect(element: HTMLMediaElement): GainNode {
    const context = this.ensure()
    const source = context.createMediaElementSource(element)
    const gain = context.createGain()
    source.connect(gain)
    gain.connect(this.input!)
    return gain
  }

  resume(): void {
    if (this.context && this.context.state !== 'running') {
      this.context.resume().catch(() => {})
    }
  }

  setEqualizer(bands: number[]): void {
    this.gains = EQUALIZER_FREQUENCIES.map((_, i) =>
      Math.min(EQUALIZER_MAX_GAIN, Math.max(EQUALIZER_MIN_GAIN, bands[i] ?? 0))
    )
    const now = this.context?.currentTime ?? 0
    this.filters.forEach((filter, i) => {
      filter.gain.setTargetAtTime(this.gains[i] ?? 0, now, 0.02)
    })
  }

  getEqualizer(): number[] {
    return [...this.gains]
  }

  get currentTime(): number {
    return this.context?.currentTime ?? 0
  }
}

export const audioGraph = new AudioGraph()
