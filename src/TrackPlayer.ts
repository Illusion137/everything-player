import { nativePlayer } from './internal/native'
import { Emitter } from './internal/Emitter'
import {
  dispatchMintPoToken,
  dispatchReloadPlayerResponse,
  fromNativeTrack,
  lookupTrack,
  pruneRegistry,
  registerTrack,
  setSabrCallbackTimeout,
  toNativeTrack,
} from './internal/tracks'
import { liveDownloadTrackIds } from './internal/downloadIds'
import type {
  NativeRemoteEvent,
  NativeUpdateOptions,
  NativeVideoQualityState,
} from './specs/EverythingPlayer.nitro'
import {
  EQUALIZER_FREQUENCIES,
  EQUALIZER_MAX_GAIN,
  EQUALIZER_MIN_GAIN,
  RepeatMode,
  SourceType,
  State,
} from './types/enums'
import {
  Event,
  type EmitterSubscription,
  type EventPayloadByEvent,
} from './types/Event'
import type {
  PlaybackError,
  PlaybackState,
  PlayerOptions,
  Progress,
  UpdateOptions,
  VideoQualities,
  VideoQualityRange,
} from './types/Options'
import type { QueuedTrack, Track } from './types/Track'

let bound = false
let setupDone = false
let setupPromise: Promise<void> | undefined
let currentUpdateOptions: NativeUpdateOptions = {
  capabilities: [],
  progressUpdateEventInterval: 0,
  forwardJumpInterval: 15,
  backwardJumpInterval: 15,
}

const emitter = new Emitter<EventPayloadByEvent>(bindNative)

function bindNative(): void {
  if (bound) return
  bound = true
  const native = nativePlayer()
  native.setSabrCallbacks(dispatchMintPoToken, dispatchReloadPlayerResponse)
  native.setOnPlaybackState((e) => {
    emitter.emit(Event.PlaybackState, toPlaybackState(e.state, e.error))
  })
  native.setOnActiveTrackChanged((e) => {
    emitter.emit(Event.PlaybackActiveTrackChanged, {
      lastIndex: e.lastIndex,
      lastTrack: lookupTrack(e.lastTrackId),
      lastPosition: e.lastPosition,
      index: e.index,
      track: lookupTrack(e.trackId),
    })
  })
  native.setOnProgress((e) => {
    emitter.emit(Event.PlaybackProgressUpdated, {
      position: e.position,
      duration: e.duration,
      buffered: e.buffered,
      track: e.trackIndex,
    })
  })
  native.setOnPlaybackError((e) => {
    emitter.emit(Event.PlaybackError, e)
  })
  native.setOnQueueEnded((e) => {
    emitter.emit(Event.PlaybackQueueEnded, {
      track: e.trackIndex,
      position: e.position,
    })
  })
  native.setOnRemoteEvent(emitRemote)
  native.setOnVideoQualityChanged((s) => {
    emitter.emit(Event.PlaybackVideoQualityChanged, {
      ...fromNativeQualities(s),
      track: lookupTrack(s.trackId),
    })
  })
}

function fromNativeQualities(s: NativeVideoQualityState): VideoQualities {
  return {
    qualities: s.qualities,
    selected: s.qualities.find((q) => q.id === s.selectedId),
    auto: s.automatic,
  }
}

export function ensureNativeBindings(): void {
  bindNative()
}

function emitRemote(e: NativeRemoteEvent): void {
  switch (e.type) {
    case 'remote-seek':
      emitter.emit(Event.RemoteSeek, { position: e.position ?? 0 })
      break
    case 'remote-jump-forward':
      emitter.emit(Event.RemoteJumpForward, {
        interval: e.interval ?? currentUpdateOptions.forwardJumpInterval,
      })
      break
    case 'remote-jump-backward':
      emitter.emit(Event.RemoteJumpBackward, {
        interval: e.interval ?? currentUpdateOptions.backwardJumpInterval,
      })
      break
    case 'remote-duck':
      emitter.emit(Event.RemoteDuck, {
        paused: e.paused ?? false,
        permanent: e.permanent ?? false,
      })
      break
    case 'remote-play-id':
      emitter.emit(Event.RemotePlayId, { id: e.id ?? '', index: e.index })
      break
    case 'remote-play-search':
      emitter.emit(Event.RemotePlaySearch, { query: e.query ?? '' })
      break
    case 'remote-skip':
      emitter.emit(Event.RemoteSkip, { index: e.index ?? 0 })
      break
    default:
      emitter.emit(e.type as Event.RemotePlay, undefined)
  }
}

function toPlaybackState(
  state: string,
  error: PlaybackError | undefined
): PlaybackState {
  if (state === State.Error) {
    return {
      state: State.Error,
      error: error ?? { code: 'unknown', message: 'Unknown error' },
    }
  }
  return { state: state as Exclude<State, State.Error> }
}

function prune(): void {
  const native = nativePlayer()
  pruneRegistry([
    ...native.getQueue().map((t) => t.id),
    ...liveDownloadTrackIds(),
  ])
}

export function isSetup(): boolean {
  return setupDone && nativePlayer().isSetup()
}

export function setupPlayer(options: PlayerOptions = {}): Promise<void> {
  if (setupPromise) return setupPromise
  bindNative()
  const timeout = options.sabrCallbackTimeoutMs ?? 20000
  setSabrCallbackTimeout(timeout)
  setupPromise = nativePlayer()
    .setupPlayer({
      cacheConfig: {
        maxSizeMB: options.cacheConfig?.maxSizeMB ?? 256,
        maxAgeSeconds: options.cacheConfig?.maxAgeSeconds ?? 7 * 24 * 3600,
        preloadNext: options.cacheConfig?.preloadNext ?? 1,
        persistent: options.cacheConfig?.persistent ?? true,
      },
      bufferConfig: {
        forwardBufferSeconds: options.bufferConfig?.forwardBufferSeconds ?? 30,
        maxBufferBytes:
          options.bufferConfig?.maxBufferBytes ?? 16 * 1024 * 1024,
      },
      enableVideo: options.enableVideo ?? false,
      videoQuality: options.videoQuality ?? { maxHeight: 720 },
      autoHandleRemoteEvents: options.autoHandleRemoteEvents ?? true,
      autoHandleInterruptions: options.autoHandleInterruptions ?? true,
      sabrCallbackTimeoutMs: timeout + 1000,
      sabrPoolAhead: options.sabrPoolAhead ?? 1,
    })
    .then(
      () => {
        setupDone = true
      },
      (e) => {
        setupPromise = undefined
        throw e
      }
    )
  return setupPromise
}

export function updateOptions(options: UpdateOptions = {}): Promise<void> {
  currentUpdateOptions = {
    capabilities: options.capabilities ?? currentUpdateOptions.capabilities,
    progressUpdateEventInterval:
      options.progressUpdateEventInterval ??
      currentUpdateOptions.progressUpdateEventInterval,
    forwardJumpInterval:
      options.forwardJumpInterval ?? currentUpdateOptions.forwardJumpInterval,
    backwardJumpInterval:
      options.backwardJumpInterval ?? currentUpdateOptions.backwardJumpInterval,
    appKilledPlaybackBehavior:
      options.android?.appKilledPlaybackBehavior ??
      currentUpdateOptions.appKilledPlaybackBehavior,
  }
  return nativePlayer().updateOptions(currentUpdateOptions)
}

export function registerPlaybackService(factory: () => () => Promise<void>) {
  bindNative()
  factory()()
}

export function setRepeatMode(mode: RepeatMode): void {
  nativePlayer().setRepeatMode(mode)
}

export function getRepeatMode(): RepeatMode {
  return nativePlayer().getRepeatMode() as RepeatMode
}

export function setEqualizer(bands: number[]): void {
  if (bands.length !== EQUALIZER_FREQUENCIES.length) {
    throw new Error(
      `setEqualizer expects ${EQUALIZER_FREQUENCIES.length} bands, got ${bands.length}`
    )
  }
  nativePlayer().setEqualizer(
    bands.map((g) =>
      Math.min(EQUALIZER_MAX_GAIN, Math.max(EQUALIZER_MIN_GAIN, g))
    )
  )
}

export function getEqualizer(): number[] {
  return nativePlayer().getEqualizer()
}

export function setCrossFade(seconds: number): void {
  nativePlayer().setCrossFade(Math.max(0, seconds))
}

export function setVolume(volume: number): void {
  nativePlayer().setVolume(Math.min(1, Math.max(0, volume)))
}

export function getVolume(): number {
  return nativePlayer().getVolume()
}

export function setRate(rate: number): void {
  nativePlayer().setRate(rate)
}

export function getRate(): number {
  return nativePlayer().getRate()
}

export function getVideoQualities(): VideoQualities {
  return fromNativeQualities(nativePlayer().getVideoQualities())
}

export function setVideoQuality(id: string | undefined): void {
  nativePlayer().setVideoQuality(id)
}

export function setVideoQualityRange(range: VideoQualityRange): void {
  nativePlayer().setVideoQualityRange(range)
}

export function getVideoQualityRange(): VideoQualityRange {
  return nativePlayer().getVideoQualityRange()
}

export function add(
  tracks: Track | Track[],
  insertBeforeIndex?: number
): number | undefined {
  const list = (Array.isArray(tracks) ? tracks : [tracks]).map(registerTrack)
  if (list.length === 0) return undefined
  const native = nativePlayer()
  const before = native.getQueue().length
  native.add(list.map(toNativeTrack), insertBeforeIndex)
  return insertBeforeIndex === undefined || insertBeforeIndex < 0
    ? before
    : Math.min(insertBeforeIndex, before)
}

export function addTrack(track: Track, insertBeforeIndex?: number) {
  return add(track, insertBeforeIndex)
}

export function addTracks(tracks: Track[], insertBeforeIndex?: number) {
  return add(tracks, insertBeforeIndex)
}

export function remove(indexes: number | number[]): void {
  nativePlayer().remove(Array.isArray(indexes) ? indexes : [indexes])
  prune()
}

export function removeTrack(index: number): void {
  remove(index)
}

export function removeUpcomingTracks(): void {
  nativePlayer().removeUpcomingTracks()
  prune()
}

export function move(fromIndex: number, toIndex: number): void {
  nativePlayer().move(fromIndex, toIndex)
}

export function setQueue(tracks: Track[]): void {
  const list = tracks.map(registerTrack)
  nativePlayer().setQueue(list.map(toNativeTrack))
  prune()
}

export function updateMetadataForTrack(
  index: number,
  metadata: Partial<Omit<Track, 'id' | 'streamingInfo'>>
): void {
  const native = nativePlayer()
  const current = native.getQueue()[index]
  if (!current) throw new Error(`No track at index ${index}`)
  const track = fromNativeTrack(current)
  Object.assign(track, metadata)
  native.updateMetadataForTrack(index, toNativeTrack(track))
}

export function getQueue(): QueuedTrack[] {
  return nativePlayer().getQueue().map(fromNativeTrack)
}

export function getTrack(index: number): QueuedTrack | undefined {
  const t = nativePlayer().getQueue()[index]
  return t ? fromNativeTrack(t) : undefined
}

export function getActiveTrackIndex(): number | undefined {
  return nativePlayer().getActiveTrackIndex()
}

export function getActiveTrack(): QueuedTrack | undefined {
  const index = getActiveTrackIndex()
  return index === undefined ? undefined : getTrack(index)
}

export function getSourceType(index: number): SourceType | undefined {
  return nativePlayer().getSourceType(index) as SourceType | undefined
}

export function skip(index: number, initialPosition?: number): Promise<void> {
  return nativePlayer().skip(index, initialPosition)
}

export function skipToNext(initialPosition?: number): Promise<void> {
  return nativePlayer().skipToNext(initialPosition)
}

export function skipToPrevious(initialPosition?: number): Promise<void> {
  return nativePlayer().skipToPrevious(initialPosition)
}

export function play(): void {
  nativePlayer().play()
}

export function pause(): void {
  nativePlayer().pause()
}

export function stop(): void {
  nativePlayer().stop()
}

export function reset(): void {
  nativePlayer().reset()
  prune()
}

export function retry(): void {
  nativePlayer().retry()
}

export function seekTo(seconds: number): void {
  nativePlayer().seekTo(seconds)
}

export function seekBy(offset: number): void {
  nativePlayer().seekBy(offset)
}

export function getProgress(): Progress {
  return nativePlayer().getProgress()
}

export function getPlaybackState(): PlaybackState {
  const s = nativePlayer().getPlaybackState()
  return toPlaybackState(s.state, s.error)
}

export function addEventListener<E extends Event>(
  event: E,
  listener: (payload: EventPayloadByEvent[E]) => void
): EmitterSubscription {
  return emitter.on(event, listener)
}

export function removeAllListeners(event?: Event): void {
  emitter.removeAll(event)
}

const TrackPlayer = {
  isSetup,
  setupPlayer,
  updateOptions,
  registerPlaybackService,
  setRepeatMode,
  getRepeatMode,
  setEqualizer,
  getEqualizer,
  setCrossFade,
  setVolume,
  getVolume,
  setRate,
  getRate,
  getVideoQualities,
  setVideoQuality,
  setVideoQualityRange,
  getVideoQualityRange,
  add,
  addTrack,
  addTracks,
  remove,
  removeTrack,
  removeUpcomingTracks,
  move,
  setQueue,
  updateMetadataForTrack,
  getQueue,
  getTrack,
  getActiveTrackIndex,
  getActiveTrack,
  getSourceType,
  skip,
  skipToNext,
  skipToPrevious,
  play,
  pause,
  stop,
  reset,
  retry,
  seekTo,
  seekBy,
  getProgress,
  getPlaybackState,
  addEventListener,
  removeAllListeners,
}

export default TrackPlayer
