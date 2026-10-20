import type { DownloadState } from './enums'
import type { PlaybackError, PlaybackState, VideoQualities } from './Options'
import type { QueuedTrack } from './Track'

export enum Event {
  PlaybackState = 'playback-state',
  PlaybackActiveTrackChanged = 'playback-active-track-changed',
  PlaybackProgressUpdated = 'playback-progress-updated',
  PlaybackError = 'playback-error',
  PlaybackQueueEnded = 'playback-queue-ended',
  PlaybackVideoQualityChanged = 'playback-video-quality-changed',
  RemotePlay = 'remote-play',
  RemotePause = 'remote-pause',
  RemoteStop = 'remote-stop',
  RemoteNext = 'remote-next',
  RemotePrevious = 'remote-previous',
  RemoteSeek = 'remote-seek',
  RemoteJumpForward = 'remote-jump-forward',
  RemoteJumpBackward = 'remote-jump-backward',
  RemoteDuck = 'remote-duck',
  RemotePlayId = 'remote-play-id',
  RemotePlaySearch = 'remote-play-search',
  RemoteSkip = 'remote-skip',
  RemoteLike = 'remote-like',
  RemoteDislike = 'remote-dislike',
  RemoteBookmark = 'remote-bookmark',
}

export enum DownloadEvent {
  DownloadChanged = 'download-changed',
}

export interface PlaybackActiveTrackChangedEvent {
  lastIndex?: number
  lastTrack?: QueuedTrack
  lastPosition: number
  index?: number
  track?: QueuedTrack
}

export interface PlaybackProgressUpdatedEvent {
  position: number
  duration: number
  buffered: number
  track?: number
}

export interface PlaybackQueueEndedEvent {
  track?: number
  position: number
}

export interface PlaybackVideoQualityChangedEvent extends VideoQualities {
  track?: QueuedTrack
}

export interface RemoteSeekEvent {
  position: number
}

export interface RemoteJumpEvent {
  interval: number
}

export interface RemoteDuckEvent {
  paused: boolean
  permanent: boolean
}

export interface RemotePlayIdEvent {
  id: string
  index?: number
}

export interface RemotePlaySearchEvent {
  query: string
}

export interface RemoteSkipEvent {
  index: number
}

export interface Download {
  trackId: string
  state: DownloadState
  progress: number
  bytesDownloaded: number
  totalBytes?: number
  localPath?: string
  audioPath?: string
  videoPath?: string
  error?: { code: string; message: string }
  track: QueuedTrack
}

export interface EventPayloadByEvent {
  [Event.PlaybackState]: PlaybackState
  [Event.PlaybackActiveTrackChanged]: PlaybackActiveTrackChangedEvent
  [Event.PlaybackProgressUpdated]: PlaybackProgressUpdatedEvent
  [Event.PlaybackError]: PlaybackError
  [Event.PlaybackQueueEnded]: PlaybackQueueEndedEvent
  [Event.PlaybackVideoQualityChanged]: PlaybackVideoQualityChangedEvent
  [Event.RemotePlay]: undefined
  [Event.RemotePause]: undefined
  [Event.RemoteStop]: undefined
  [Event.RemoteNext]: undefined
  [Event.RemotePrevious]: undefined
  [Event.RemoteSeek]: RemoteSeekEvent
  [Event.RemoteJumpForward]: RemoteJumpEvent
  [Event.RemoteJumpBackward]: RemoteJumpEvent
  [Event.RemoteDuck]: RemoteDuckEvent
  [Event.RemotePlayId]: RemotePlayIdEvent
  [Event.RemotePlaySearch]: RemotePlaySearchEvent
  [Event.RemoteSkip]: RemoteSkipEvent
  [Event.RemoteLike]: undefined
  [Event.RemoteDislike]: undefined
  [Event.RemoteBookmark]: undefined
}

export interface DownloadEventPayloadByEvent {
  [DownloadEvent.DownloadChanged]: Download
}

export interface EmitterSubscription {
  remove(): void
}
