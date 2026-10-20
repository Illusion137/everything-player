export enum State {
  None = 'none',
  Ready = 'ready',
  Playing = 'playing',
  Paused = 'paused',
  Stopped = 'stopped',
  Buffering = 'buffering',
  Loading = 'loading',
  Error = 'error',
  Ended = 'ended',
}

export enum RepeatMode {
  Off = 'off',
  Track = 'track',
  Queue = 'queue',
}

export enum Capability {
  Play = 'play',
  Pause = 'pause',
  Stop = 'stop',
  Skip = 'skip',
  SkipToNext = 'skip-to-next',
  SkipToPrevious = 'skip-to-previous',
  SeekTo = 'seek-to',
  JumpForward = 'jump-forward',
  JumpBackward = 'jump-backward',
  PlayFromId = 'play-from-id',
  PlayFromSearch = 'play-from-search',
  SetRating = 'set-rating',
  Like = 'like',
  Dislike = 'dislike',
  Bookmark = 'bookmark',
}

export enum AppKilledPlaybackBehavior {
  ContinuePlayback = 'continue-playback',
  PausePlayback = 'pause-playback',
  StopPlaybackAndRemoveNotification = 'stop-playback-and-remove-notification',
}

export enum SourceType {
  Raw = 'raw',
  Hls = 'hls',
  Sabr = 'sabr',
}

export enum DownloadState {
  Queued = 'queued',
  Downloading = 'downloading',
  Paused = 'paused',
  Completed = 'completed',
  Failed = 'failed',
  Cancelled = 'cancelled',
}

export enum PlaybackErrorCode {
  SabrCallbackFailed = 'sabr-callback-failed',
  SabrUnsupported = 'sabr-unsupported',
  SabrStreamFailed = 'sabr-stream-failed',
  SourceError = 'source-error',
  NetworkError = 'network-error',
  DecodeError = 'decode-error',
  Unknown = 'unknown',
}

export const EQUALIZER_FREQUENCIES = [
  31, 62, 125, 250, 500, 1000, 2000, 4000, 8000, 16000,
] as const

export const EQUALIZER_MIN_GAIN = -12
export const EQUALIZER_MAX_GAIN = 12
