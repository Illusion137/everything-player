import { nativeDownloads } from './internal/native'
import { Emitter } from './internal/Emitter'
import { markDownloadLive } from './internal/downloadIds'
import {
  fromNativeTrack,
  lookupTrack,
  registerTrack,
  toNativeTrack,
} from './internal/tracks'
import { ensureNativeBindings } from './TrackPlayer'
import type { NativeDownload } from './specs/DownloadManager.nitro'
import { DownloadState } from './types/enums'
import {
  DownloadEvent,
  type Download,
  type DownloadEventPayloadByEvent,
  type EmitterSubscription,
} from './types/Event'
import type { DownloadOptions } from './types/Options'
import type { Track } from './types/Track'

let bound = false

const emitter = new Emitter<DownloadEventPayloadByEvent>(bind)

function isLive(state: string): boolean {
  return (
    state === DownloadState.Queued ||
    state === DownloadState.Downloading ||
    state === DownloadState.Paused
  )
}

function fromNative(d: NativeDownload): Download {
  return {
    trackId: d.trackId,
    state: d.state as DownloadState,
    progress: d.progress,
    bytesDownloaded: d.bytesDownloaded,
    totalBytes: d.totalBytes,
    localPath: d.localPath,
    audioPath: d.audioPath,
    videoPath: d.videoPath,
    error:
      d.errorCode !== undefined
        ? { code: d.errorCode, message: d.errorMessage ?? '' }
        : undefined,
    track: lookupTrack(d.trackId) ?? fromNativeTrack(d.track),
  }
}

function bind(): void {
  if (bound) return
  bound = true
  ensureNativeBindings()
  nativeDownloads().setOnDownloadChanged((d) => {
    markDownloadLive(d.trackId, isLive(d.state))
    emitter.emit(DownloadEvent.DownloadChanged, fromNative(d))
  })
}

export async function download(
  track: Track,
  options: DownloadOptions = {}
): Promise<Download> {
  if (track.id === undefined) {
    throw new Error(
      'DownloadManager.download requires a track with a stable id'
    )
  }
  bind()
  const queued = registerTrack(track)
  markDownloadLive(queued.id, true)
  try {
    const result = await nativeDownloads().download(toNativeTrack(queued), {
      includeVideo: options.includeVideo ?? false,
      videoQuality: options.videoQuality,
    })
    markDownloadLive(queued.id, isLive(result.state))
    return fromNative(result)
  } catch (e) {
    markDownloadLive(queued.id, false)
    throw e
  }
}

export function pause(trackId: string): void {
  nativeDownloads().pause(trackId)
}

export function resume(trackId: string): void {
  bind()
  nativeDownloads().resume(trackId)
}

export function cancel(trackId: string): void {
  nativeDownloads().cancel(trackId)
}

export function remove(trackId: string): Promise<void> {
  markDownloadLive(trackId, false)
  return nativeDownloads().remove(trackId)
}

export function removeAll(): Promise<void> {
  for (const d of nativeDownloads().getDownloads()) {
    markDownloadLive(d.trackId, false)
  }
  return nativeDownloads().removeAll()
}

export function getDownload(trackId: string): Download | undefined {
  const d = nativeDownloads().getDownload(trackId)
  return d ? fromNative(d) : undefined
}

export function getDownloads(): Download[] {
  return nativeDownloads().getDownloads().map(fromNative)
}

export function addEventListener<E extends DownloadEvent>(
  event: E,
  listener: (payload: DownloadEventPayloadByEvent[E]) => void
): EmitterSubscription {
  return emitter.on(event, listener)
}

const DownloadManager = {
  download,
  pause,
  resume,
  cancel,
  remove,
  removeAll,
  getDownload,
  getDownloads,
  addEventListener,
}

export default DownloadManager
