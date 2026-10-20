import type {
  NativeActiveTrackChangedEvent,
  NativePlaybackError,
  NativePlaybackStateEvent,
  NativeProgress,
  NativeProgressEvent,
  NativeQueueEndedEvent,
  NativeReloadPlaybackContext,
  NativeReloadPlayerResponse,
  NativeRemoteEvent,
  NativeRepeatMode,
  NativeSetupOptions,
  NativeSourceType,
  NativeState,
  NativeTrack,
  NativeUpdateOptions,
  NativeVideoQualityRange,
  NativeVideoQualityState,
} from '../../specs/EverythingPlayer.nitro'
import type { PlayerBackend } from '../../internal/native'
import { audioGraph } from './AudioGraph'
import { getHost, type Host } from './host'
import { MediaSessionBridge } from './MediaSession'
import {
  DEFAULT_SETUP,
  DEFAULT_UPDATE,
  EPError,
  requestHeaders,
  sourceTypeOf,
  trimEnd,
  trimStart,
} from './models'
import { LocalSabrPipeline } from './pipelines/LocalSabrPipeline'
import type {
  LocalMedia,
  Pipeline,
  PipelineContext,
  PipelineDelegate,
  PipelineStatus,
} from './pipelines/Pipeline'
import { RawPipeline } from './pipelines/RawPipeline'
import { SabrPipeline } from './pipelines/SabrPipeline'
import { ShakaPipeline } from './pipelines/ShakaPipeline'
import { SabrServices } from './sabr'
import { videoHub } from './VideoHub'

export const sabrServices = new SabrServices(() => currentHostRef)
let currentHostRef: Host | undefined

export type LocalMediaResolver = (track: NativeTrack) => LocalMedia | undefined

let localResolver: LocalMediaResolver = () => undefined
let playerOptions: NativeSetupOptions = DEFAULT_SETUP

export function setLocalMediaResolver(resolver: LocalMediaResolver): void {
  localResolver = resolver
}

export function currentSetupOptions(): NativeSetupOptions {
  return playerOptions
}

export async function ensureHost(): Promise<Host> {
  currentHostRef = await getHost()
  return currentHostRef
}

function copyTrack(track: NativeTrack): NativeTrack {
  return {
    ...track,
    headers: track.headers ? { ...track.headers } : undefined,
    sabr: track.sabr ? { ...track.sabr, clientInfo: { ...track.sabr.clientInfo } } : undefined,
  }
}

export class ElectronPlayer implements PlayerBackend, PipelineDelegate {
  private setup = false
  private options: NativeSetupOptions = DEFAULT_SETUP
  private update: NativeUpdateOptions = DEFAULT_UPDATE
  private queue: NativeTrack[] = []
  private activeIndex: number | undefined
  private state: NativeState = 'none'
  private lastError: EPError | undefined
  private repeatMode: NativeRepeatMode = 'off'
  private crossfadeSeconds = 0
  private volumeValue = 1
  private rateValue = 1
  private playWhenReady = false
  private hasPlayed = false
  private pendingSeek: number | undefined

  private primary: Pipeline | undefined
  private secondary: Pipeline | undefined
  private fading = false
  private ticks = 0
  private tickTimer: ReturnType<typeof setInterval> | undefined
  private progressTimer: ReturnType<typeof setInterval> | undefined
  private readonly media = new MediaSessionBridge()

  private onStateChange: ((e: NativePlaybackStateEvent) => void) | undefined
  private onActiveTrackChanged: ((e: NativeActiveTrackChangedEvent) => void) | undefined
  private onProgress: ((e: NativeProgressEvent) => void) | undefined
  private onError: ((e: NativePlaybackError) => void) | undefined
  private onQueueEnded: ((e: NativeQueueEndedEvent) => void) | undefined
  private onRemote: ((e: NativeRemoteEvent) => void) | undefined
  private onVideoQuality: ((e: NativeVideoQualityState) => void) | undefined

  constructor(private readonly ready: Promise<void> = Promise.resolve()) {
    this.media.handler = (e) => this.handleRemote(e)
    this.media.isPlaying = () => this.state === 'playing'
  }

  isSetup(): boolean {
    return this.setup
  }

  async setupPlayer(options: NativeSetupOptions): Promise<void> {
    await ensureHost()
    await this.ready.catch(() => {})
    this.options = {
      ...options,
      bufferConfig: {
        forwardBufferSeconds: Math.max(1, options.bufferConfig.forwardBufferSeconds),
        maxBufferBytes: Math.max(256 * 1024, options.bufferConfig.maxBufferBytes),
      },
    }
    playerOptions = this.options
    sabrServices.timeoutMs = options.sabrCallbackTimeoutMs
    this.setup = true
    this.startTickTimer()
    this.applyRemoteCommands()
  }

  async updateOptions(options: NativeUpdateOptions): Promise<void> {
    this.update = options
    this.applyRemoteCommands()
    this.restartProgressTimer()
  }

  private applyRemoteCommands(): void {
    const o = this.update
    this.media.configure(o.capabilities, o.forwardJumpInterval, o.backwardJumpInterval)
  }

  private get host(): Host {
    if (!currentHostRef) throw new EPError('unknown', 'Player is not set up')
    return currentHostRef
  }

  private get range(): NativeVideoQualityRange {
    return this.options.videoQuality
  }

  setRepeatMode(mode: NativeRepeatMode): void {
    this.repeatMode = mode
    this.invalidateSecondaryIfStale()
  }

  getRepeatMode(): NativeRepeatMode {
    return this.repeatMode
  }

  setEqualizer(bands: number[]): void {
    audioGraph.setEqualizer(bands)
  }

  getEqualizer(): number[] {
    return audioGraph.getEqualizer()
  }

  setCrossFade(seconds: number): void {
    this.crossfadeSeconds = Math.max(0, seconds)
  }

  setVolume(volume: number): void {
    this.volumeValue = volume
    if (!this.fading && this.primary) this.primary.volume = volume
  }

  getVolume(): number {
    return this.volumeValue
  }

  setRate(rate: number): void {
    this.rateValue = rate
    if (this.primary) this.primary.rate = rate
    if (this.secondary) this.secondary.rate = rate
    this.refreshNowPlaying()
  }

  getRate(): number {
    return this.rateValue
  }

  getVideoQualities(): NativeVideoQualityState {
    const q = this.primary?.videoQuality() ?? { qualities: [], automatic: true }
    return { ...q, trackId: this.currentTrackId() }
  }

  setVideoQuality(id?: string): void {
    const primary = this.primary
    if (!primary) {
      if (id !== undefined) throw new Error('No active track')
      return
    }
    primary.setVideoQuality(id, this.range)
  }

  setVideoQualityRange(range: NativeVideoQualityRange): void {
    this.options = { ...this.options, videoQuality: { ...range } }
    playerOptions = this.options
    const primary = this.primary
    if (primary) {
      const q = primary.videoQuality()
      try {
        primary.setVideoQuality(q.automatic ? undefined : q.selectedId, range)
      } catch {}
    }
    try {
      this.secondary?.setVideoQuality(undefined, range)
    } catch {}
  }

  getVideoQualityRange(): NativeVideoQualityRange {
    return { ...this.range }
  }

  add(tracks: NativeTrack[], insertBeforeIndex?: number): void {
    if (tracks.length === 0) return
    const wasEmpty = this.queue.length === 0
    const before = insertBeforeIndex
    const at =
      before !== undefined && before >= 0 && before <= this.queue.length ? before : this.queue.length
    this.queue.splice(at, 0, ...tracks.map(copyTrack))
    if (this.activeIndex !== undefined && at <= this.activeIndex) this.activeIndex += tracks.length
    if (this.activeIndex === undefined && wasEmpty) {
      this.activeIndex = 0
      this.emitActiveChange(undefined, undefined, 0)
      this.loadActive(undefined)
    }
    this.invalidateSecondaryIfStale()
    this.preloadUpcoming()
  }

  remove(indexes: number[]): void {
    let removedActive = false
    let lastIndex: number | undefined
    let lastId: string | undefined
    const lastPosition = this.getProgress().position
    const sorted = [...new Set(indexes)].sort((a, b) => b - a)
    for (const index of sorted) {
      if (index < 0 || index >= this.queue.length) continue
      this.queue.splice(index, 1)
      const a = this.activeIndex
      if (a === undefined) continue
      if (index === a) {
        removedActive = true
        lastIndex = a
      } else if (index < a) {
        this.activeIndex = a - 1
      }
    }
    if (removedActive) {
      lastId = this.primary?.track.id
      this.activeIndex = this.queue.length === 0 ? undefined : Math.min(lastIndex ?? 0, this.queue.length - 1)
      this.emitActiveChange(lastIndex, lastId, lastPosition)
      if (this.activeIndex === undefined) {
        this.releasePipelines()
        this.setState('none')
        this.media.setTrack(undefined)
      } else {
        this.loadActive(undefined)
      }
    }
    this.invalidateSecondaryIfStale()
  }

  removeUpcomingTracks(): void {
    const a = this.activeIndex
    if (a === undefined || a + 1 >= this.queue.length) return
    this.queue.splice(a + 1)
    this.invalidateSecondaryIfStale()
  }

  move(fromIndex: number, toIndex: number): void {
    const q = this.queue
    if (fromIndex < 0 || fromIndex >= q.length || toIndex < 0 || toIndex >= q.length || fromIndex === toIndex) {
      return
    }
    const [t] = q.splice(fromIndex, 1)
    q.splice(toIndex, 0, t!)
    const a = this.activeIndex
    if (a !== undefined) {
      if (a === fromIndex) this.activeIndex = toIndex
      else if (fromIndex < a && toIndex >= a) this.activeIndex = a - 1
      else if (fromIndex > a && toIndex <= a) this.activeIndex = a + 1
    }
    this.invalidateSecondaryIfStale()
  }

  setQueue(tracks: NativeTrack[]): void {
    const lastPosition = this.getProgress().position
    const activeId = this.currentTrackId()
    const lastIndex = this.activeIndex
    this.queue = tracks.map(copyTrack)
    const newIndex = activeId === undefined ? -1 : this.queue.findIndex((t) => t.id === activeId)
    this.invalidateSecondaryIfStale()
    if (newIndex >= 0) {
      this.activeIndex = newIndex
      return
    }
    this.activeIndex = this.queue.length === 0 ? undefined : 0
    this.emitActiveChange(lastIndex, activeId, lastPosition)
    if (this.activeIndex === undefined) {
      this.releasePipelines()
      this.setState('none')
      this.media.setTrack(undefined)
    } else {
      this.loadActive(undefined)
    }
  }

  updateMetadataForTrack(index: number, track: NativeTrack): void {
    const t = this.queue[index]
    if (!t) return
    t.title = track.title
    t.artist = track.artist
    t.album = track.album
    t.artwork = track.artwork
    if (track.duration !== undefined) t.duration = track.duration
    if (index === this.activeIndex) this.refreshNowPlaying(true)
  }

  getQueue(): NativeTrack[] {
    return this.queue.map(copyTrack)
  }

  getActiveTrackIndex(): number | undefined {
    return this.activeIndex
  }

  async skip(index: number, initialPosition?: number): Promise<void> {
    if (index < 0 || index >= this.queue.length) {
      throw new Error(`Index ${index} is out of bounds`)
    }
    this.transition(index, initialPosition, true)
  }

  async skipToNext(initialPosition?: number): Promise<void> {
    const next = this.nextIndex(true)
    if (next === undefined) throw new Error('There is no next track')
    this.transition(next, initialPosition, true)
  }

  async skipToPrevious(initialPosition?: number): Promise<void> {
    const a = this.activeIndex
    let previous: number | undefined
    if (a !== undefined) {
      if (a > 0) previous = a - 1
      else if (this.repeatMode === 'queue' && this.queue.length > 0) previous = this.queue.length - 1
    }
    if (previous === undefined) {
      if (a === undefined) throw new Error('There is no previous track')
      this.seekTo(initialPosition ?? 0)
      return
    }
    this.transition(previous, initialPosition, true)
  }

  private nextIndex(ignoringRepeatTrack: boolean): number | undefined {
    const a = this.activeIndex
    if (a === undefined || this.queue.length === 0) return undefined
    if (!ignoringRepeatTrack && this.repeatMode === 'track') return a
    if (a + 1 < this.queue.length) return a + 1
    return this.repeatMode === 'queue' ? 0 : undefined
  }

  play(): void {
    this.playWhenReady = true
    audioGraph.resume()
    if (this.state === 'ended' || this.state === 'stopped' || !this.primary) {
      if (this.activeIndex === undefined) return
      this.loadActive(this.state === 'ended' ? undefined : this.pendingSeek)
      return
    }
    if (this.primary.status === 'failed') {
      this.retry()
      return
    }
    this.primary.play()
    if (this.fading) this.secondary?.play()
    this.syncState()
  }

  pause(): void {
    this.playWhenReady = false
    this.primary?.pause()
    this.secondary?.pause()
    this.syncState()
  }

  stop(): void {
    this.playWhenReady = false
    this.pendingSeek = undefined
    this.releasePipelines()
    sabrServices.pool.clear()
    this.setState('stopped')
    this.refreshNowPlaying()
  }

  reset(): void {
    this.playWhenReady = false
    this.pendingSeek = undefined
    this.queue = []
    this.activeIndex = undefined
    this.hasPlayed = false
    this.releasePipelines()
    sabrServices.pool.clear()
    this.setState('none')
    this.media.setTrack(undefined)
  }

  retry(): void {
    if (this.activeIndex === undefined) return
    this.loadActive(this.primary?.currentTime)
  }

  seekTo(seconds: number): void {
    const track = this.activeTrack()
    if (!track) return
    const start = trimStart(track)
    const upper = trimEnd(track, this.primary?.mediaDuration) ?? Math.max(seconds, start)
    const target = Math.min(Math.max(seconds, start), upper)
    this.pendingSeek = target
    this.onProgress?.(this.progressEvent())
    this.cancelFade()
    if (this.primary) this.primary.seek(target)
    else this.loadActive(target)
    this.refreshNowPlaying()
  }

  seekBy(offset: number): void {
    const base = this.pendingSeek ?? this.getProgress().position
    this.seekTo(base + offset)
  }

  getProgress(): NativeProgress {
    const track = this.activeTrack()
    if (!track) return { position: 0, duration: 0, buffered: 0 }
    const duration = trimEnd(track, this.primary?.mediaDuration) ?? 0
    const position = this.pendingSeek ?? this.primary?.currentTime ?? trimStart(track)
    const buffered = this.primary?.bufferedTime ?? position
    const upper = duration > 0 ? duration : Math.max(position, buffered)
    return {
      position: Math.min(Math.max(0, position), upper),
      duration,
      buffered: Math.min(Math.max(position, buffered), upper),
    }
  }

  getPlaybackState(): NativePlaybackStateEvent {
    return {
      state: this.state,
      error: this.state === 'error' ? this.lastError?.toNative(this.currentTrackId()) : undefined,
    }
  }

  getSourceType(index: number): NativeSourceType | undefined {
    const t = this.queue[index]
    return t ? sourceTypeOf(t) : undefined
  }

  setOnPlaybackState(callback: (event: NativePlaybackStateEvent) => void): void {
    this.onStateChange = callback
  }

  setOnActiveTrackChanged(callback: (event: NativeActiveTrackChangedEvent) => void): void {
    this.onActiveTrackChanged = callback
  }

  setOnProgress(callback: (event: NativeProgressEvent) => void): void {
    this.onProgress = callback
  }

  setOnPlaybackError(callback: (error: NativePlaybackError) => void): void {
    this.onError = callback
  }

  setOnQueueEnded(callback: (event: NativeQueueEndedEvent) => void): void {
    this.onQueueEnded = callback
  }

  setOnRemoteEvent(callback: (event: NativeRemoteEvent) => void): void {
    this.onRemote = callback
  }

  setOnVideoQualityChanged(callback: (state: NativeVideoQualityState) => void): void {
    this.onVideoQuality = callback
  }

  setSabrCallbacks(
    onMintPoToken: (trackId: string) => Promise<string>,
    onReloadPlayerResponse: (
      trackId: string,
      context: NativeReloadPlaybackContext
    ) => Promise<NativeReloadPlayerResponse>
  ): void {
    sabrServices.provider = { mint: onMintPoToken, reload: onReloadPlayerResponse }
  }

  private activeTrack(): NativeTrack | undefined {
    return this.activeIndex === undefined ? undefined : this.queue[this.activeIndex]
  }

  private currentTrackId(): string | undefined {
    return this.activeTrack()?.id
  }

  private progressEvent(): NativeProgressEvent {
    const p = this.getProgress()
    return { ...p, trackIndex: this.activeIndex, trackId: this.currentTrackId() }
  }

  private makePipeline(track: NativeTrack): Pipeline {
    const local = localResolver(track)
    const ctx: PipelineContext = {
      options: this.options,
      range: this.range,
      host: this.host,
      sabr: sabrServices,
      local,
    }
    let pipeline: Pipeline
    if (local?.kind === 'sabr') pipeline = new LocalSabrPipeline(track, ctx)
    else if (local?.kind === 'hls') pipeline = new ShakaPipeline(track, ctx)
    else if (local) pipeline = new RawPipeline(track, ctx)
    else if (track.sabr) pipeline = new SabrPipeline(track, ctx)
    else if (sourceTypeOf(track) === 'hls') pipeline = new ShakaPipeline(track, ctx)
    else pipeline = new RawPipeline(track, ctx)
    pipeline.delegate = this
    pipeline.rate = this.rateValue
    return pipeline
  }

  private loadActive(position: number | undefined): void {
    this.cancelFade()
    this.releasePipelines()
    const track = this.activeTrack()
    if (!track) return
    const start = position ?? trimStart(track)
    this.pendingSeek = start > trimStart(track) ? start : undefined
    this.lastError = undefined
    let pipeline: Pipeline
    try {
      pipeline = this.makePipeline(track)
    } catch (e) {
      const error = EPError.from(e)
      this.lastError = error
      this.setState('error', error)
      this.onError?.(error.toNative(track.id))
      return
    }
    pipeline.volume = this.volumeValue
    this.primary = pipeline
    this.setState('loading')
    this.refreshNowPlaying(true)
    pipeline.load(start)
    if (this.playWhenReady) {
      audioGraph.resume()
      pipeline.play()
    }
    this.preloadUpcoming()
  }

  private releasePipelines(): void {
    const p = this.primary
    const s = this.secondary
    this.primary = undefined
    this.secondary = undefined
    this.fading = false
    p?.teardown()
    s?.teardown()
    videoHub.setActive(null)
  }

  private transition(index: number, initialPosition: number | undefined, manual: boolean): void {
    const lastPosition = this.getProgress().position
    const lastIndex = this.activeIndex
    const lastId = this.currentTrackId()
    const targetId = this.queue[index]?.id
    const secondary = this.secondary
    if (secondary && secondary.track.id === targetId && initialPosition === undefined && !(manual && this.fading)) {
      this.promoteSecondary(lastIndex, lastId, lastPosition, index)
      return
    }
    this.activeIndex = index
    this.emitActiveChange(lastIndex, lastId, lastPosition)
    this.loadActive(initialPosition)
  }

  private promoteSecondary(
    lastIndex: number | undefined,
    lastId: string | undefined,
    lastPosition: number,
    newIndex: number
  ): void {
    const next = this.secondary
    if (!next) return
    const old = this.primary
    this.primary = next
    this.secondary = undefined
    this.activeIndex = newIndex
    this.pendingSeek = undefined
    this.fading = false
    old?.teardown()
    next.volume = this.volumeValue
    this.updateVideoSource()
    if (this.playWhenReady) next.play()
    this.emitActiveChange(lastIndex, lastId, lastPosition)
    this.refreshNowPlaying(true)
    this.syncState()
    this.preloadUpcoming()
    this.onVideoQuality?.(this.getVideoQualities())
  }

  private cancelFade(): void {
    if (!this.fading) return
    this.fading = false
    const s = this.secondary
    this.secondary = undefined
    s?.teardown()
    if (this.primary) this.primary.volume = this.volumeValue
  }

  private invalidateSecondaryIfStale(): void {
    this.warmUpcomingSabr()
    const secondary = this.secondary
    if (!secondary) return
    const next = this.nextIndex(false)
    const nextId = next === undefined ? undefined : this.queue[next]?.id
    if (secondary.track.id !== nextId || this.repeatMode === 'track') {
      if (this.fading) this.cancelFade()
      else {
        this.secondary = undefined
        secondary.teardown()
      }
    }
  }

  private updateVideoSource(): void {
    const primary = this.primary
    videoHub.setActive(primary && this.options.enableVideo && primary.hasVideo ? primary.element : null)
  }

  pipelineStatus(pipeline: Pipeline, status: PipelineStatus): void {
    if (pipeline === this.secondary) {
      if (status === 'ended' && this.fading) this.finishFade()
      return
    }
    if (pipeline !== this.primary) return
    switch (status) {
      case 'ready':
      case 'playing':
        this.pendingSeek = undefined
        this.updateVideoSource()
        break
      case 'ended':
        this.handleTrackEnded()
        return
    }
    this.syncState()
  }

  pipelineFailed(pipeline: Pipeline, error: EPError): void {
    if (pipeline === this.secondary) {
      if (this.fading) this.cancelFade()
      else {
        this.secondary = undefined
        pipeline.teardown()
      }
      return
    }
    if (pipeline !== this.primary) return
    this.lastError = error
    this.pendingSeek = undefined
    this.setState('error', error)
    this.onError?.(error.toNative(pipeline.track.id))
  }

  pipelineDuration(pipeline: Pipeline): void {
    if (pipeline === this.primary) this.refreshNowPlaying()
  }

  pipelineQuality(pipeline: Pipeline): void {
    if (pipeline !== this.primary) return
    this.updateVideoSource()
    this.onVideoQuality?.(this.getVideoQualities())
  }

  private syncState(): void {
    const primary = this.primary
    if (!primary) return
    let next: NativeState
    switch (primary.status) {
      case 'idle':
      case 'loading':
        next = 'loading'
        break
      case 'buffering':
        next = 'buffering'
        break
      case 'ready':
        next = this.playWhenReady ? 'buffering' : this.hasPlayed ? 'paused' : 'ready'
        break
      case 'playing':
        next = this.playWhenReady ? 'playing' : 'paused'
        this.hasPlayed = true
        break
      case 'ended':
        next = 'ended'
        break
      default:
        return
    }
    this.setState(next)
    this.refreshNowPlaying()
  }

  private setState(next: NativeState, error?: EPError): void {
    if (this.state === next) return
    this.state = next
    if (next !== 'error') this.lastError = undefined
    this.onStateChange?.({ state: next, error: error?.toNative(this.currentTrackId()) })
  }

  private emitActiveChange(lastIndex: number | undefined, lastTrackId: string | undefined, lastPosition: number): void {
    this.onActiveTrackChanged?.({
      lastIndex,
      lastTrackId,
      lastPosition,
      index: this.activeIndex,
      trackId: this.currentTrackId(),
    })
  }

  private handleTrackEnded(): void {
    const active = this.activeIndex
    if (this.repeatMode === 'track' && active !== undefined) {
      const track = this.queue[active]
      this.pendingSeek = undefined
      this.primary?.seek(track ? trimStart(track) : 0)
      if (this.playWhenReady) this.primary?.play()
      return
    }
    if (this.fading && this.secondary) {
      this.finishFade()
      return
    }
    const next = this.nextIndex(true)
    if (next === undefined) {
      const position = this.getProgress().position
      this.setState('ended')
      this.onQueueEnded?.({ trackIndex: active, trackId: this.currentTrackId(), position })
      this.refreshNowPlaying()
      return
    }
    this.transition(next, undefined, false)
  }

  private finishFade(): void {
    const next = this.nextIndex(true)
    if (next === undefined || !this.secondary) {
      this.cancelFade()
      return
    }
    const lastPosition = this.getProgress().position
    this.promoteSecondary(this.activeIndex, this.currentTrackId(), lastPosition, next)
  }

  private startTickTimer(): void {
    if (this.tickTimer !== undefined) return
    this.tickTimer = setInterval(() => this.tick(), 100)
  }

  private restartProgressTimer(): void {
    if (this.progressTimer !== undefined) clearInterval(this.progressTimer)
    this.progressTimer = undefined
    const interval = this.update.progressUpdateEventInterval
    if (!(interval > 0)) return
    this.progressTimer = setInterval(() => {
      if (this.state === 'playing') this.onProgress?.(this.progressEvent())
    }, interval * 1000)
  }

  private tick(): void {
    const primary = this.primary
    primary?.poll()
    this.secondary?.poll()
    if (!primary || !this.playWhenReady) return
    this.ticks += 1
    if (this.ticks % 300 === 0) this.warmUpcomingSabr()
    if (this.ticks % 10 === 0) this.refreshNowPlaying()
    const track = primary.track
    const fadeLength = this.crossfadeSeconds
    const end = trimEnd(track, primary.mediaDuration)
    if (end === undefined) return
    const remaining = end - primary.currentTime
    const nextIdx = this.nextIndex(false)
    const canFade = fadeLength > 0 && this.repeatMode !== 'track' && end - trimStart(track) >= 2 * fadeLength

    if (!this.secondary && nextIdx !== undefined && this.repeatMode !== 'track' && remaining <= Math.max(fadeLength, 0) + 8 && remaining > 0.25) {
      const nextTrack = this.queue[nextIdx]
      if (nextTrack) {
        try {
          const pipeline = this.makePipeline(nextTrack)
          pipeline.volume = canFade ? 0 : this.volumeValue
          this.secondary = pipeline
          pipeline.load(trimStart(nextTrack))
        } catch {}
      }
    }

    const secondary = this.secondary
    if (!canFade || !secondary || this.state !== 'playing') return
    if (!this.fading && remaining <= fadeLength && (secondary.status === 'ready' || secondary.status === 'playing')) {
      this.fading = true
      secondary.volume = 0
      secondary.play()
    }
    if (!this.fading) return
    const p = Math.min(1, Math.max(0, 1 - remaining / fadeLength))
    primary.volume = this.volumeValue * Math.cos((p * Math.PI) / 2)
    secondary.volume = this.volumeValue * Math.sin((p * Math.PI) / 2)
    if (remaining <= 0.05) this.finishFade()
  }

  private warmUpcomingSabr(): void {
    const a = this.activeIndex
    if (a === undefined || !this.setup) {
      sabrServices.pool.warm([], this.options, this.range)
      return
    }
    const out: NativeTrack[] = []
    let i = a
    const count = Math.max(0, Math.min(this.options.sabrPoolAhead, this.queue.length - 1))
    for (let n = 0; n < count; n++) {
      i += 1
      if (i >= this.queue.length) {
        if (this.repeatMode !== 'queue') break
        i = 0
      }
      const t = this.queue[i]
      if (t) out.push(t)
    }
    const candidates = out.filter((t) => t.sabr && !localResolver(t))
    sabrServices.pool.warm(candidates, this.options, this.range)
  }

  private preloadUpcoming(): void {
    this.warmUpcomingSabr()
    const a = this.activeIndex
    const n = Math.max(0, this.options.cacheConfig.preloadNext)
    if (a === undefined || n === 0) return
    for (const track of this.queue.slice(a + 1, a + 1 + n)) {
      if (sourceTypeOf(track) !== 'raw' || !track.url || localResolver(track)) continue
      prefetch(track, this.host)
    }
  }

  private refreshNowPlaying(trackChanged = false): void {
    const track = this.activeTrack()
    if (trackChanged) this.media.setTrack(track)
    if (!track) return
    const p = this.getProgress()
    this.media.update(p.position, trimEnd(track, this.primary?.mediaDuration), this.rateValue, this.state === 'playing')
  }

  private handleRemote(event: NativeRemoteEvent): void {
    this.onRemote?.(event)
    if (!this.options.autoHandleRemoteEvents) return
    switch (event.type) {
      case 'remote-play':
        this.play()
        break
      case 'remote-pause':
        this.pause()
        break
      case 'remote-stop':
        this.stop()
        break
      case 'remote-next':
        this.skipToNext().catch(() => {})
        break
      case 'remote-previous':
        this.skipToPrevious().catch(() => {})
        break
      case 'remote-seek':
        if (event.position !== undefined) this.seekTo(event.position)
        break
      case 'remote-jump-forward':
        this.seekBy(event.interval ?? this.update.forwardJumpInterval)
        break
      case 'remote-jump-backward':
        this.seekBy(-(event.interval ?? this.update.backwardJumpInterval))
        break
    }
  }
}

const prefetched = new Set<string>()

function prefetch(track: NativeTrack, host: Host): void {
  const url = track.url
  if (!url || prefetched.has(url) || !/^https?:/i.test(url)) return
  prefetched.add(url)
  if (prefetched.size > 64) prefetched.delete(prefetched.values().next().value!)
  const headers = requestHeaders(track)
  host
    .prepare(url, headers)
    .then(() =>
      fetch(url, {
        headers: { ...(host.managesHeaders ? {} : headers), Range: 'bytes=0-524287' },
      })
    )
    .then((r) => r.arrayBuffer())
    .catch(() => {})
}
