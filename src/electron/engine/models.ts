import type {
  NativeBufferConfig,
  NativeCacheConfig,
  NativePlaybackError,
  NativeSetupOptions,
  NativeSourceType,
  NativeTrack,
  NativeUpdateOptions,
  NativeVideoQuality,
  NativeVideoQualityRange,
} from '../../specs/EverythingPlayer.nitro'
import type { PlaybackErrorCode } from '../../types/enums'

export type ErrorCode = `${PlaybackErrorCode}`

export class EPError extends Error {
  constructor(
    readonly code: ErrorCode,
    message: string,
    public trackId?: string
  ) {
    super(message)
  }

  static from(error: unknown, code: ErrorCode = 'unknown'): EPError {
    if (error instanceof EPError) return error
    const message =
      error instanceof Error ? error.message : String(error ?? 'Unknown error')
    if (error instanceof TypeError && /fetch|network/i.test(message)) {
      return new EPError('network-error', message)
    }
    return new EPError(code, message)
  }

  toNative(trackId?: string): NativePlaybackError {
    return {
      code: this.code,
      message: this.message,
      trackId: this.trackId ?? trackId,
    }
  }
}

export function sourceTypeOf(track: NativeTrack): NativeSourceType {
  if (track.sabr) return 'sabr'
  const contentType = track.contentType?.toLowerCase()
  if (
    contentType === 'application/vnd.apple.mpegurl' ||
    contentType === 'application/x-mpegurl'
  ) {
    return 'hls'
  }
  if (track.url) {
    try {
      if (new URL(track.url).pathname.toLowerCase().endsWith('.m3u8')) {
        return 'hls'
      }
    } catch {
      if (/\.m3u8($|[?#])/i.test(track.url)) return 'hls'
    }
  }
  return 'raw'
}

export function requestHeaders(track: NativeTrack): Record<string, string> {
  const headers: Record<string, string> = { ...(track.headers ?? {}) }
  const has = (name: string) =>
    Object.keys(headers).some((k) => k.toLowerCase() === name.toLowerCase())
  if (track.userAgent && !has('user-agent')) {
    headers['User-Agent'] = track.userAgent
  }
  if (track.sabr?.cookie && !has('cookie')) headers.Cookie = track.sabr.cookie
  return headers
}

export function trimStart(track: NativeTrack): number {
  return Math.max(0, track.startTime ?? 0)
}

export function trimEnd(
  track: NativeTrack,
  mediaDuration: number | undefined
): number | undefined {
  const known = track.duration ?? mediaDuration
  if (track.endTime !== undefined && known !== undefined) {
    return Math.min(track.endTime, known)
  }
  return track.endTime ?? known
}

export function inRange(
  range: NativeVideoQualityRange,
  height: number | undefined,
  bitrate: number
): boolean {
  const h = height ?? 0
  if (range.minHeight !== undefined && h < range.minHeight) return false
  if (range.maxHeight !== undefined && h > range.maxHeight) return false
  if (range.maxBitrate !== undefined && range.maxBitrate > 0 && bitrate > range.maxBitrate) {
    return false
  }
  return true
}

export function pickInRange<T>(
  range: NativeVideoQualityRange,
  items: T[],
  height: (item: T) => number | undefined,
  bitrate: (item: T) => number
): T | undefined {
  if (items.length === 0) return undefined
  const sorted = [...items].sort(
    (a, b) => (height(a) ?? 0) - (height(b) ?? 0) || bitrate(a) - bitrate(b)
  )
  const matching = sorted.filter((i) => inRange(range, height(i), bitrate(i)))
  const best = matching[matching.length - 1]
  if (best !== undefined) return best
  const { maxHeight, maxBitrate, minHeight } = range
  if (maxHeight !== undefined && sorted.every((i) => (height(i) ?? 0) > maxHeight)) {
    return sorted[0]
  }
  if (maxBitrate !== undefined && maxBitrate > 0) {
    const fitting = sorted.filter((i) => bitrate(i) <= maxBitrate)
    const last = fitting[fitting.length - 1]
    if (last !== undefined) return last
  }
  if (minHeight !== undefined && sorted.every((i) => (height(i) ?? 0) < minHeight)) {
    return sorted[sorted.length - 1]
  }
  return sorted[0]
}

export interface QualityState {
  qualities: NativeVideoQuality[]
  selectedId?: string
  automatic: boolean
}

export const DEFAULT_CACHE: NativeCacheConfig = {
  maxSizeMB: 256,
  maxAgeSeconds: 7 * 24 * 3600,
  preloadNext: 1,
  persistent: true,
}

export const DEFAULT_BUFFER: NativeBufferConfig = {
  forwardBufferSeconds: 30,
  maxBufferBytes: 16 * 1024 * 1024,
}

export const DEFAULT_SETUP: NativeSetupOptions = {
  cacheConfig: DEFAULT_CACHE,
  bufferConfig: DEFAULT_BUFFER,
  enableVideo: false,
  videoQuality: { maxHeight: 720 },
  autoHandleRemoteEvents: true,
  autoHandleInterruptions: true,
  sabrCallbackTimeoutMs: 21000,
  sabrPoolAhead: 1,
}

export const DEFAULT_UPDATE: NativeUpdateOptions = {
  capabilities: [],
  progressUpdateEventInterval: 0,
  forwardJumpInterval: 15,
  backwardJumpInterval: 15,
}

export function withTimeout<T>(
  promise: Promise<T>,
  ms: number,
  what: string
): Promise<T> {
  if (!(ms > 0)) return promise
  return new Promise<T>((resolve, reject) => {
    const timer = setTimeout(
      () => reject(new EPError('sabr-callback-failed', `${what} timed out after ${Math.round(ms)}ms`)),
      ms
    )
    promise.then(
      (v) => {
        clearTimeout(timer)
        resolve(v)
      },
      (e) => {
        clearTimeout(timer)
        reject(e)
      }
    )
  })
}

export function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms))
}
