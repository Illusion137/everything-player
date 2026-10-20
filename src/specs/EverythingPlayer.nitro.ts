import type { HybridObject } from 'react-native-nitro-modules'

export type NativeState =
  | 'none'
  | 'ready'
  | 'playing'
  | 'paused'
  | 'stopped'
  | 'buffering'
  | 'loading'
  | 'error'
  | 'ended'

export type NativeRepeatMode = 'off' | 'track' | 'queue'

export type NativeCapability =
  | 'play'
  | 'pause'
  | 'stop'
  | 'skip'
  | 'skip-to-next'
  | 'skip-to-previous'
  | 'seek-to'
  | 'jump-forward'
  | 'jump-backward'
  | 'play-from-id'
  | 'play-from-search'
  | 'set-rating'
  | 'like'
  | 'dislike'
  | 'bookmark'

export type NativeSourceType = 'raw' | 'hls' | 'sabr'

export type NativeAppKilledPlaybackBehavior =
  | 'continue-playback'
  | 'pause-playback'
  | 'stop-playback-and-remove-notification'

export interface NativeSabrFormat {
  itag: number
  lastModified: string
  xtags?: string
  mimeType?: string
  bitrate: number
  averageBitrate?: number
  approxDurationMs: number
  contentLength?: number
  width?: number
  height?: number
  fps?: number
  quality?: string
  qualityLabel?: string
  audioQuality?: string
  audioSampleRate?: number
  audioChannels?: number
  audioTrackId?: string
  language?: string
  isDrc?: boolean
  isVb?: boolean
  isSr?: boolean
  isHdr?: boolean
  isDubbed?: boolean
  isAutoDubbed?: boolean
  isDescriptive?: boolean
  isSecondary?: boolean
  isOriginal?: boolean
}

export interface NativeSabrClientInfo {
  clientName: number
  clientVersion: string
}

export interface NativeSabrInfo {
  videoId: string
  serverAbrStreamingUrl: string
  videoPlaybackUstreamerConfig: string
  formats: NativeSabrFormat[]
  poToken: string
  clientInfo: NativeSabrClientInfo
  cookie?: string
  duration: number
}

export interface NativeTrack {
  id: string
  title: string
  artist: string
  album?: string
  artwork?: string
  duration?: number
  startTime?: number
  endTime?: number
  url?: string
  sabr?: NativeSabrInfo
  userAgent?: string
  contentType?: string
  headers?: Record<string, string>
}

export interface NativeCacheConfig {
  maxSizeMB: number
  maxAgeSeconds: number
  preloadNext: number
  persistent: boolean
}

export interface NativeBufferConfig {
  forwardBufferSeconds: number
  maxBufferBytes: number
}

export interface NativeVideoQualityRange {
  minHeight?: number
  maxHeight?: number
  maxBitrate?: number
}

export interface NativeVideoQuality {
  id: string
  width?: number
  height?: number
  fps?: number
  bitrate: number
  label: string
  codec?: string
}

export interface NativeVideoQualityState {
  qualities: NativeVideoQuality[]
  selectedId?: string
  automatic: boolean
  trackId?: string
}

export interface NativeSetupOptions {
  cacheConfig: NativeCacheConfig
  bufferConfig: NativeBufferConfig
  enableVideo: boolean
  videoQuality: NativeVideoQualityRange
  autoHandleRemoteEvents: boolean
  autoHandleInterruptions: boolean
  sabrCallbackTimeoutMs: number
  sabrPoolAhead: number
}

export interface NativeUpdateOptions {
  capabilities: NativeCapability[]
  progressUpdateEventInterval: number
  forwardJumpInterval: number
  backwardJumpInterval: number
  appKilledPlaybackBehavior?: NativeAppKilledPlaybackBehavior
}

export interface NativeProgress {
  position: number
  duration: number
  buffered: number
}

export interface NativePlaybackError {
  code: string
  message: string
  trackId?: string
}

export interface NativePlaybackStateEvent {
  state: NativeState
  error?: NativePlaybackError
}

export interface NativeActiveTrackChangedEvent {
  lastIndex?: number
  lastTrackId?: string
  lastPosition: number
  index?: number
  trackId?: string
}

export interface NativeProgressEvent {
  position: number
  duration: number
  buffered: number
  trackIndex?: number
  trackId?: string
}

export interface NativeQueueEndedEvent {
  trackIndex?: number
  trackId?: string
  position: number
}

export type NativeRemoteEventType =
  | 'remote-play'
  | 'remote-pause'
  | 'remote-stop'
  | 'remote-next'
  | 'remote-previous'
  | 'remote-seek'
  | 'remote-jump-forward'
  | 'remote-jump-backward'
  | 'remote-duck'
  | 'remote-play-id'
  | 'remote-play-search'
  | 'remote-skip'
  | 'remote-like'
  | 'remote-dislike'
  | 'remote-bookmark'

export interface NativeRemoteEvent {
  type: NativeRemoteEventType
  position?: number
  interval?: number
  paused?: boolean
  permanent?: boolean
  id?: string
  index?: number
  query?: string
}

export interface NativeReloadPlaybackParams {
  token?: string
}

export interface NativeReloadPlaybackContext {
  reloadPlaybackParams?: NativeReloadPlaybackParams
}

export interface NativeReloadPlayerResponse {
  videoPlaybackUstreamerConfig: string
  serverAbrStreamingUrl: string
}

export interface EverythingPlayer extends HybridObject<{
  ios: 'swift'
  android: 'kotlin'
}> {
  isSetup(): boolean
  setupPlayer(options: NativeSetupOptions): Promise<void>
  updateOptions(options: NativeUpdateOptions): Promise<void>

  setRepeatMode(mode: NativeRepeatMode): void
  getRepeatMode(): NativeRepeatMode
  setEqualizer(bands: number[]): void
  getEqualizer(): number[]
  setCrossFade(seconds: number): void
  setVolume(volume: number): void
  getVolume(): number
  setRate(rate: number): void
  getRate(): number

  getVideoQualities(): NativeVideoQualityState
  setVideoQuality(id?: string): void
  setVideoQualityRange(range: NativeVideoQualityRange): void
  getVideoQualityRange(): NativeVideoQualityRange

  add(tracks: NativeTrack[], insertBeforeIndex?: number): void
  remove(indexes: number[]): void
  move(fromIndex: number, toIndex: number): void
  setQueue(tracks: NativeTrack[]): void
  updateMetadataForTrack(index: number, track: NativeTrack): void
  getQueue(): NativeTrack[]
  getActiveTrackIndex(): number | undefined
  skip(index: number, initialPosition?: number): Promise<void>
  skipToNext(initialPosition?: number): Promise<void>
  skipToPrevious(initialPosition?: number): Promise<void>
  removeUpcomingTracks(): void

  play(): void
  pause(): void
  stop(): void
  reset(): void
  seekTo(seconds: number): void
  seekBy(offset: number): void
  retry(): void

  getProgress(): NativeProgress
  getPlaybackState(): NativePlaybackStateEvent
  getSourceType(index: number): NativeSourceType | undefined

  setOnPlaybackState(callback: (event: NativePlaybackStateEvent) => void): void
  setOnActiveTrackChanged(
    callback: (event: NativeActiveTrackChangedEvent) => void
  ): void
  setOnProgress(callback: (event: NativeProgressEvent) => void): void
  setOnPlaybackError(callback: (error: NativePlaybackError) => void): void
  setOnQueueEnded(callback: (event: NativeQueueEndedEvent) => void): void
  setOnRemoteEvent(callback: (event: NativeRemoteEvent) => void): void
  setOnVideoQualityChanged(
    callback: (state: NativeVideoQualityState) => void
  ): void

  setSabrCallbacks(
    onMintPoToken: (trackId: string) => Promise<string>,
    onReloadPlayerResponse: (
      trackId: string,
      context: NativeReloadPlaybackContext
    ) => Promise<NativeReloadPlayerResponse>
  ): void
}
