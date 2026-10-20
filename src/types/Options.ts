import type { AppKilledPlaybackBehavior, Capability, State } from './enums'

export interface CacheConfig {
  maxSizeMB?: number
  maxAgeSeconds?: number
  preloadNext?: number
  persistent?: boolean
}

export interface BufferConfig {
  forwardBufferSeconds?: number
  maxBufferBytes?: number
}

export interface VideoQualityRange {
  minHeight?: number
  maxHeight?: number
  maxBitrate?: number
}

export interface VideoQuality {
  id: string
  width?: number
  height?: number
  fps?: number
  bitrate: number
  label: string
  codec?: string
}

export interface VideoQualities {
  qualities: VideoQuality[]
  selected?: VideoQuality
  auto: boolean
}

export interface PlayerOptions {
  cacheConfig?: CacheConfig
  bufferConfig?: BufferConfig
  enableVideo?: boolean
  videoQuality?: VideoQualityRange
  autoHandleRemoteEvents?: boolean
  autoHandleInterruptions?: boolean
  sabrCallbackTimeoutMs?: number
  sabrPoolAhead?: number
}

export interface UpdateOptions {
  capabilities?: Capability[]
  progressUpdateEventInterval?: number
  forwardJumpInterval?: number
  backwardJumpInterval?: number
  android?: {
    appKilledPlaybackBehavior?: AppKilledPlaybackBehavior
  }
}

export interface Progress {
  position: number
  duration: number
  buffered: number
}

export interface PlaybackError {
  code: string
  message: string
  trackId?: string
}

export type PlaybackState =
  | { state: Exclude<State, State.Error> }
  | { state: State.Error; error: PlaybackError }

export interface DownloadOptions {
  includeVideo?: boolean
  videoQuality?: VideoQualityRange
}
