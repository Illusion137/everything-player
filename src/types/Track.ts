import type { ImageRequireSource } from 'react-native'

export interface SabrFormat {
  itag: number
  lastModified: string
  xtags?: string
  mimeType?: string
  bitrate: number
  averageBitrate?: number
  approxDurationMs: number | string
  contentLength?: number | string
  width?: number
  height?: number
  fps?: number
  quality?: string
  qualityLabel?: string
  audioQuality?: string
  audioSampleRate?: number | string
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

export interface ReloadPlaybackContext {
  reloadPlaybackParams?: { token?: string }
}

export interface ReloadPlayerResponse {
  videoPlaybackUstreamerConfig: string
  serverAbrStreamingUrl: string
}

export interface SabrCallbacks {
  onMintPoToken: () => Promise<Uint8Array>
  onReloadPlayerResponse: (
    playbackContext: ReloadPlaybackContext
  ) => Promise<ReloadPlayerResponse>
}

export interface SabrStreamingInfo {
  videoId: string
  serverAbrStreamingUrl: string
  videoPlaybackUstreamerConfig: string
  formats: SabrFormat[]
  poToken: string
  clientInfo: { clientName: number; clientVersion: string }
  cookie?: string
  duration: number
  callbacks: SabrCallbacks
}

export type StreamingInfo = string | SabrStreamingInfo

export type Artwork = string | ImageRequireSource

export interface Track {
  id?: string
  title: string
  artist: string
  album?: string
  artwork?: Artwork
  duration?: number
  startTime?: number
  endTime?: number
  streamingInfo: StreamingInfo
  userAgent?: string
  contentType?: string
  headers?: Record<string, string>
  otherData?: Record<string, any>
}

export type QueuedTrack = Track & { id: string }

export function isSabrStreamingInfo(
  info: StreamingInfo
): info is SabrStreamingInfo {
  return (
    typeof info === 'object' &&
    info !== null &&
    typeof info.serverAbrStreamingUrl === 'string'
  )
}
