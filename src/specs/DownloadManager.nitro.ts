import type { HybridObject } from 'react-native-nitro-modules'
import type {
  NativeTrack,
  NativeVideoQualityRange,
} from './EverythingPlayer.nitro'

export type NativeDownloadState =
  'queued' | 'downloading' | 'paused' | 'completed' | 'failed' | 'cancelled'

export interface NativeDownloadOptions {
  includeVideo: boolean
  videoQuality?: NativeVideoQualityRange
}

export interface NativeDownload {
  trackId: string
  state: NativeDownloadState
  progress: number
  bytesDownloaded: number
  totalBytes?: number
  localPath?: string
  audioPath?: string
  videoPath?: string
  errorCode?: string
  errorMessage?: string
  track: NativeTrack
}

export interface DownloadManager extends HybridObject<{
  ios: 'swift'
  android: 'kotlin'
}> {
  download(
    track: NativeTrack,
    options: NativeDownloadOptions
  ): Promise<NativeDownload>
  pause(trackId: string): void
  resume(trackId: string): void
  cancel(trackId: string): void
  remove(trackId: string): Promise<void>
  removeAll(): Promise<void>
  getDownload(trackId: string): NativeDownload | undefined
  getDownloads(): NativeDownload[]

  setOnDownloadChanged(callback: (download: NativeDownload) => void): void
}
