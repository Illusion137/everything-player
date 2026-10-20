import type {
  NativeReloadPlaybackContext,
  NativeReloadPlayerResponse,
  NativeSabrFormat,
  NativeTrack,
} from '../specs/EverythingPlayer.nitro'
import {
  isSabrStreamingInfo,
  type Artwork,
  type QueuedTrack,
  type SabrFormat,
  type Track,
} from '../types/Track'
import { resolveArtworkSource } from './native'

const registry = new Map<string, QueuedTrack>()
let idCounter = 0

function generateId(): string {
  idCounter += 1
  return `rnep-${Date.now().toString(36)}-${idCounter.toString(36)}-${Math.random()
    .toString(36)
    .slice(2, 8)}`
}

function toNumber(value: number | string | undefined): number | undefined {
  if (value === undefined) return undefined
  const n = typeof value === 'number' ? value : Number(value)
  return Number.isFinite(n) ? n : undefined
}

function resolveArtwork(artwork: Artwork | undefined): string | undefined {
  if (artwork === undefined) return undefined
  if (typeof artwork === 'string') return artwork
  return resolveArtworkSource(artwork)
}

function toNativeFormat(f: SabrFormat): NativeSabrFormat {
  return {
    ...f,
    approxDurationMs: toNumber(f.approxDurationMs) ?? 0,
    contentLength: toNumber(f.contentLength),
    audioSampleRate: toNumber(f.audioSampleRate),
  }
}

export function registerTrack(track: Track): QueuedTrack {
  const queued: QueuedTrack =
    track.id !== undefined
      ? (track as QueuedTrack)
      : { ...track, id: generateId() }
  registry.set(queued.id, queued)
  return queued
}

export function lookupTrack(id: string | undefined): QueuedTrack | undefined {
  return id === undefined ? undefined : registry.get(id)
}

export function pruneRegistry(liveIds: Iterable<string>): void {
  const live = new Set(liveIds)
  for (const id of registry.keys()) {
    if (!live.has(id)) registry.delete(id)
  }
}

export function toNativeTrack(track: QueuedTrack): NativeTrack {
  const info = track.streamingInfo
  const base: NativeTrack = {
    id: track.id,
    title: track.title,
    artist: track.artist,
    album: track.album,
    artwork: resolveArtwork(track.artwork),
    duration: track.duration,
    startTime: track.startTime,
    endTime: track.endTime,
    userAgent: track.userAgent,
    contentType: track.contentType,
    headers: track.headers,
  }
  if (isSabrStreamingInfo(info)) {
    base.sabr = {
      videoId: info.videoId,
      serverAbrStreamingUrl: info.serverAbrStreamingUrl,
      videoPlaybackUstreamerConfig: info.videoPlaybackUstreamerConfig,
      formats: info.formats.map(toNativeFormat),
      poToken: info.poToken,
      clientInfo: info.clientInfo,
      cookie: info.cookie,
      duration: info.duration,
    }
    base.duration ??= info.duration
  } else {
    base.url = info
  }
  return base
}

export function fromNativeTrack(native: NativeTrack): QueuedTrack {
  const known = registry.get(native.id)
  if (known) return known
  return {
    id: native.id,
    title: native.title,
    artist: native.artist,
    album: native.album,
    artwork: native.artwork,
    duration: native.duration,
    startTime: native.startTime,
    endTime: native.endTime,
    streamingInfo: native.url ?? '',
    userAgent: native.userAgent,
    contentType: native.contentType,
    headers: native.headers,
  }
}

function withTimeout<T>(promise: Promise<T>, ms: number, what: string) {
  if (ms <= 0) return promise
  return new Promise<T>((resolve, reject) => {
    const timer = setTimeout(
      () => reject(new Error(`${what} timed out after ${ms}ms`)),
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

function sabrCallbacksFor(trackId: string) {
  const track = registry.get(trackId)
  const info = track?.streamingInfo
  if (!info || !isSabrStreamingInfo(info)) {
    throw new Error(`No SABR track registered for id ${trackId}`)
  }
  return info.callbacks
}

let callbackTimeoutMs = 20000

export function setSabrCallbackTimeout(ms: number): void {
  callbackTimeoutMs = ms
}

const B64 = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'

function toBase64(bytes: Uint8Array): string {
  let out = ''
  for (let i = 0; i < bytes.length; i += 3) {
    const a = bytes[i]!
    const b = bytes[i + 1]
    const c = bytes[i + 2]
    out += B64[a >> 2]
    out += B64[((a & 3) << 4) | ((b ?? 0) >> 4)]
    out += b === undefined ? '=' : B64[((b & 15) << 2) | ((c ?? 0) >> 6)]
    out += c === undefined ? '=' : B64[c & 63]
  }
  return out
}

export async function dispatchMintPoToken(trackId: string): Promise<string> {
  const bytes = await withTimeout(
    sabrCallbacksFor(trackId).onMintPoToken(),
    callbackTimeoutMs,
    'onMintPoToken'
  )
  return toBase64(bytes)
}

export async function dispatchReloadPlayerResponse(
  trackId: string,
  context: NativeReloadPlaybackContext
): Promise<NativeReloadPlayerResponse> {
  const callbacks = sabrCallbacksFor(trackId)
  const response = await withTimeout(
    callbacks.onReloadPlayerResponse(context),
    callbackTimeoutMs,
    'onReloadPlayerResponse'
  )
  const info = registry.get(trackId)?.streamingInfo
  if (info && isSabrStreamingInfo(info)) {
    info.serverAbrStreamingUrl = response.serverAbrStreamingUrl
    info.videoPlaybackUstreamerConfig = response.videoPlaybackUstreamerConfig
  }
  return {
    serverAbrStreamingUrl: response.serverAbrStreamingUrl,
    videoPlaybackUstreamerConfig: response.videoPlaybackUstreamerConfig,
  }
}
