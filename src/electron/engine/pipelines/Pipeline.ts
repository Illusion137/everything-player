import type {
  NativeSetupOptions,
  NativeTrack,
  NativeVideoQualityRange,
} from '../../../specs/EverythingPlayer.nitro'
import { audioGraph } from '../AudioGraph'
import type { Host } from '../host'
import { EPError, trimEnd, type QualityState } from '../models'
import { videoHub } from '../VideoHub'
import type { SabrServices } from '../sabr'

export type PipelineStatus =
  | 'idle'
  | 'loading'
  | 'buffering'
  | 'ready'
  | 'playing'
  | 'ended'
  | 'failed'

export interface PipelineDelegate {
  pipelineStatus(pipeline: Pipeline, status: PipelineStatus): void
  pipelineFailed(pipeline: Pipeline, error: EPError): void
  pipelineDuration(pipeline: Pipeline): void
  pipelineQuality(pipeline: Pipeline): void
}

export interface LocalMedia {
  kind: 'file' | 'hls' | 'sabr'
  path: string
  videoPath?: string
}

export interface PipelineContext {
  options: NativeSetupOptions
  range: NativeVideoQualityRange
  host: Host
  sabr: SabrServices
  local?: LocalMedia
}

interface PooledElement {
  element: HTMLVideoElement
  gain: GainNode
  busy: boolean
}

const pool: PooledElement[] = []

function acquire(): PooledElement {
  let entry = pool.find((p) => !p.busy)
  if (!entry) {
    const element = document.createElement('video')
    element.preload = 'auto'
    element.crossOrigin = 'anonymous'
    element.playsInline = true
    element.disableRemotePlayback = true
    element.preservesPitch = true
    entry = { element, gain: audioGraph.connect(element), busy: false }
    pool.push(entry)
  }
  entry.busy = true
  entry.gain.gain.value = 1
  videoHub.park(entry.element)
  return entry
}

function mediaError(error: MediaError | null): EPError {
  const message = error?.message || 'Media playback failed'
  switch (error?.code) {
    case MediaError.MEDIA_ERR_NETWORK:
      return new EPError('network-error', message)
    case MediaError.MEDIA_ERR_DECODE:
      return new EPError('decode-error', message)
    default:
      return new EPError('source-error', message)
  }
}

export abstract class Pipeline {
  delegate: PipelineDelegate | undefined
  status: PipelineStatus = 'idle'
  readonly element: HTMLVideoElement

  protected disposed = false
  protected wantsPlay = false
  protected sourceAttached = false
  protected frozenPosition: number | undefined
  private readonly pooled: PooledElement
  private volumeValue = 1
  private rateValue = 1
  private readonly listeners: [string, EventListener][] = []

  constructor(
    readonly track: NativeTrack,
    protected readonly ctx: PipelineContext
  ) {
    this.pooled = acquire()
    this.element = this.pooled.element
    this.listen('playing', () => {
      this.frozenPosition = undefined
      if (this.wantsPlay) this.setStatus('playing')
    })
    this.listen('waiting', () => {
      if (this.status !== 'loading' && this.status !== 'ended') {
        this.setStatus('buffering')
      }
    })
    this.listen('seeked', () => {
      if (!this.isSeekPending()) this.frozenPosition = undefined
      if (this.element.paused && this.status !== 'loading') {
        this.setStatus(this.wantsPlay ? 'buffering' : 'ready')
      }
    })
    this.listen('canplay', () => {
      if (this.disposed) return
      if (this.element.paused) {
        if (this.wantsPlay) this.resumeElement()
        else if (this.status === 'loading' || this.status === 'buffering') {
          this.setStatus('ready')
        }
      }
    })
    this.listen('pause', () => {
      if (this.status === 'playing' && !this.element.ended) this.setStatus('ready')
    })
    this.listen('ended', () => {
      if (!this.isSeekPending()) this.setStatus('ended')
    })
    this.listen('loadedmetadata', () => this.delegate?.pipelineDuration(this))
    this.listen('durationchange', () => this.delegate?.pipelineDuration(this))
    this.listen('resize', () => this.delegate?.pipelineQuality(this))
    this.listen('error', () => {
      if (this.disposed || !this.sourceAttached) return
      this.onElementError(this.element.error)
    })
  }

  private listen(type: string, fn: () => void): void {
    const listener = () => {
      if (!this.disposed) fn()
    }
    this.element.addEventListener(type, listener)
    this.listeners.push([type, listener])
  }

  protected onElementError(error: MediaError | null): void {
    this.fail(mediaError(error))
  }

  protected isSeekPending(): boolean {
    return false
  }

  load(at: number): void {
    this.setStatus('loading')
    this.element.playbackRate = this.rateValue
    this.element.defaultPlaybackRate = this.rateValue
    this.start(at).catch((e) => this.fail(EPError.from(e, 'source-error')))
  }

  protected abstract start(at: number): Promise<void>

  protected abstract release(): void | Promise<void>

  play(): void {
    this.wantsPlay = true
    audioGraph.resume()
    if (this.status === 'ended') return
    if (this.status === 'ready') this.setStatus('buffering')
    this.resumeElement()
  }

  protected resumeElement(): void {
    if (this.disposed || !this.sourceAttached) return
    this.element.play().catch((e: DOMException) => {
      if (e?.name === 'NotAllowedError') {
        this.fail(new EPError('unknown', e.message))
      }
    })
  }

  pause(): void {
    this.wantsPlay = false
    this.element.pause()
    if (this.status === 'playing' || this.status === 'buffering') {
      this.setStatus(this.status === 'buffering' && this.element.readyState < 3 ? 'buffering' : 'ready')
    }
  }

  seek(seconds: number): void {
    this.frozenPosition = seconds
    if (this.status === 'ended') {
      this.setStatus(this.wantsPlay ? 'buffering' : 'ready')
    }
    this.performSeek(seconds)
  }

  protected performSeek(seconds: number): void {
    this.element.currentTime = seconds
  }

  get currentTime(): number {
    if (this.frozenPosition !== undefined) return this.frozenPosition
    const t = this.element.currentTime
    return Number.isFinite(t) ? t : 0
  }

  get mediaDuration(): number | undefined {
    const d = this.element.duration
    return Number.isFinite(d) && d > 0 ? d : undefined
  }

  get bufferedTime(): number {
    const position = this.currentTime
    const ranges = this.element.buffered
    for (let i = 0; i < ranges.length; i++) {
      if (ranges.start(i) <= position + 0.25 && position <= ranges.end(i)) {
        return ranges.end(i)
      }
    }
    return position
  }

  get volume(): number {
    return this.volumeValue
  }

  set volume(value: number) {
    this.volumeValue = value
    this.pooled.gain.gain.value = value
  }

  get rate(): number {
    return this.rateValue
  }

  set rate(value: number) {
    this.rateValue = value
    this.element.playbackRate = value
    this.element.defaultPlaybackRate = value
  }

  get hasVideo(): boolean {
    return this.ctx.options.enableVideo && this.element.videoWidth > 0
  }

  videoQuality(): QualityState {
    return { qualities: [], automatic: true }
  }

  setVideoQuality(id: string | undefined, _range: NativeVideoQualityRange): void {
    if (id !== undefined) throw new EPError('unknown', `Unknown video quality ${id}`)
  }

  poll(): void {
    if (this.status !== 'playing' || this.track.endTime === undefined) return
    const end = trimEnd(this.track, this.mediaDuration)
    if (end !== undefined && this.element.currentTime >= end - 0.02) {
      this.element.pause()
      this.setStatus('ended')
    }
  }

  teardown(): void {
    if (this.disposed) return
    this.disposed = true
    this.delegate = undefined
    for (const [type, listener] of this.listeners) {
      this.element.removeEventListener(type, listener)
    }
    this.element.pause()
    this.pooled.gain.gain.value = 0
    const element = this.element
    const pooled = this.pooled
    const recycle = () => {
      element.pause()
      element.removeAttribute('src')
      element.querySelectorAll('source').forEach((s) => s.remove())
      element.load()
      pooled.gain.gain.value = 1
      videoHub.park(element)
      pooled.busy = false
    }
    let pending: void | Promise<void> = undefined
    try {
      pending = this.release()
    } catch {}
    if (pending) pending.catch(() => {}).finally(recycle)
    else recycle()
  }

  protected setStatus(status: PipelineStatus): void {
    if (this.disposed || this.status === status) return
    if (this.status === 'failed') return
    this.status = status
    this.delegate?.pipelineStatus(this, status)
  }

  protected fail(error: EPError): void {
    if (this.disposed || this.status === 'failed') return
    error.trackId ??= this.track.id
    this.status = 'failed'
    this.delegate?.pipelineFailed(this, error)
  }
}
