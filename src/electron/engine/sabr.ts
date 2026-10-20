import type {
  NativeReloadPlaybackContext,
  NativeReloadPlayerResponse,
  NativeSabrFormat,
  NativeSabrInfo,
  NativeSetupOptions,
  NativeTrack,
  NativeVideoQuality,
  NativeVideoQualityRange,
} from '../../specs/EverythingPlayer.nitro'
import { SabrStream } from '../vendor/googlevideo/src/core/SabrStream'
import type { StreamStartResult } from '../vendor/googlevideo/src/types/sabrStreamTypes'
import type { SabrFormat } from '../vendor/googlevideo/src/types/shared'
import { EnabledTrackTypes } from '../vendor/googlevideo/src/utils/formatUtils'
import { CODEC_CODES } from '../vendor/googlevideo/src/utils/mediaCapabilityUtils'
import { base64ToU8 } from '../vendor/googlevideo/src/utils/uint8arrayUtils'
import type { Host } from './host'
import {
  EPError,
  pickInRange,
  requestHeaders,
  trimStart,
  withTimeout,
} from './models'

export interface SabrCallbackProvider {
  mint(trackId: string): Promise<string>
  reload(
    trackId: string,
    context: NativeReloadPlaybackContext
  ): Promise<NativeReloadPlayerResponse>
}

export class SabrServices {
  provider: SabrCallbackProvider | undefined
  timeoutMs = 21000
  readonly pool = new SabrWarmPool(this)

  constructor(readonly host: () => Host | undefined) {}
}

export function mimeOf(format: NativeSabrFormat): string {
  return format.mimeType ?? ''
}

export function isSupportedMime(mime: string): boolean {
  try {
    return typeof MediaSource !== 'undefined' && MediaSource.isTypeSupported(mime)
  } catch {
    return false
  }
}

export function toGoogleFormat(f: NativeSabrFormat): SabrFormat {
  const mime = mimeOf(f)
  return {
    itag: f.itag,
    lastModified: f.lastModified,
    xtags: f.xtags,
    width: f.width,
    height: f.height,
    fps: f.fps,
    contentLength: f.contentLength,
    audioTrackId: f.audioTrackId,
    mimeType: f.mimeType,
    isDrc: f.isDrc,
    isVb: f.isVb,
    isSr: f.isSr,
    quality: f.quality,
    qualityLabel: f.qualityLabel,
    averageBitrate: f.averageBitrate,
    bitrate: f.bitrate,
    audioQuality: f.audioQuality,
    numChannels: f.audioChannels,
    approxDurationMs: f.approxDurationMs,
    language: f.language,
    isHdr: f.isHdr ?? false,
    isDubbed: f.isDubbed,
    isAutoDubbed: f.isAutoDubbed,
    isDescriptive: f.isDescriptive,
    isSecondary: f.isSecondary,
    isOriginal: f.isOriginal,
    hasAudio: mime.startsWith('audio'),
    hasVideo: mime.startsWith('video'),
    hasText: false,
    codecCode: CODEC_CODES[f.itag as keyof typeof CODEC_CODES] ?? '',
  }
}

function isMainAudio(f: NativeSabrFormat): boolean {
  return !(f.isDrc || f.isDescriptive || f.isAutoDubbed || f.isSecondary)
}

export function pickAudio(formats: NativeSabrFormat[]): NativeSabrFormat | undefined {
  const audio = formats.filter((f) => mimeOf(f).startsWith('audio') && isSupportedMime(mimeOf(f)))
  const preferred = audio.filter(isMainAudio)
  const pool = preferred.length ? preferred : audio
  const original = pool.filter((f) => f.isOriginal !== false)
  const candidates = original.length ? original : pool
  const opus = candidates.filter((f) => mimeOf(f).includes('opus'))
  const aac = candidates.filter((f) => mimeOf(f).includes('mp4a'))
  const chosen = opus.length ? opus : aac.length ? aac : candidates
  return chosen.reduce<NativeSabrFormat | undefined>(
    (best, f) => (!best || f.bitrate > best.bitrate ? f : best),
    undefined
  )
}

const CODEC_RANK = ['avc1', 'avc3', 'vp9', 'vp09', 'av01']

function codecRank(f: NativeSabrFormat): number {
  const mime = mimeOf(f)
  const index = CODEC_RANK.findIndex((c) => mime.includes(c))
  return index < 0 ? CODEC_RANK.length : index
}

export function videoFormats(formats: NativeSabrFormat[]): NativeSabrFormat[] {
  const byHeight = new Map<string, NativeSabrFormat>()
  for (const f of formats) {
    const mime = mimeOf(f)
    if (!mime.startsWith('video') || f.isHdr || !isSupportedMime(mime)) continue
    const key = `${f.height ?? 0}:${f.fps ?? 0}`
    const existing = byHeight.get(key)
    if (
      !existing ||
      codecRank(f) < codecRank(existing) ||
      (codecRank(f) === codecRank(existing) && f.bitrate > existing.bitrate)
    ) {
      byHeight.set(key, f)
    }
  }
  return [...byHeight.values()].sort(
    (a, b) => (b.height ?? 0) - (a.height ?? 0) || (b.fps ?? 0) - (a.fps ?? 0)
  )
}

export function pickVideo(
  formats: NativeSabrFormat[],
  range: NativeVideoQualityRange
): NativeSabrFormat | undefined {
  return pickInRange(range, videoFormats(formats), (f) => f.height, (f) => f.averageBitrate ?? f.bitrate)
}

export function qualityOf(f: NativeSabrFormat): NativeVideoQuality {
  const codec = /codecs="([^"]+)"/.exec(mimeOf(f))?.[1]
  return {
    id: String(f.itag),
    width: f.width,
    height: f.height,
    fps: f.fps,
    bitrate: f.averageBitrate ?? f.bitrate,
    label: f.qualityLabel ?? (f.height ? `${f.height}p` : `itag ${f.itag}`),
    codec,
  }
}

export function selectItags(
  info: NativeSabrInfo,
  options: NativeSetupOptions,
  range: NativeVideoQualityRange
): { audio: NativeSabrFormat; video?: NativeSabrFormat } | undefined {
  const audio = pickAudio(info.formats)
  if (!audio) return undefined
  const video = options.enableVideo ? pickVideo(info.formats, range) : undefined
  return { audio, video }
}

export function sabrFetch(track: NativeTrack, host: Host | undefined): typeof fetch {
  const headers = requestHeaders(track)
  return async (input, init) => {
    const url = typeof input === 'string' ? input : input instanceof URL ? input.toString() : input.url
    await host?.prepare(url, headers)
    const merged = new Headers(init?.headers)
    if (!host?.managesHeaders) {
      for (const [k, v] of Object.entries(headers)) if (!merged.has(k)) merged.set(k, v)
    }
    return fetch(input, { ...init, headers: merged })
  }
}

export interface SabrSessionOwner {
  sessionCallbackFailed(session: SabrSession, error: EPError): void
  sessionFailed(session: SabrSession, error: Error): void
  sessionFinished(session: SabrSession): void
}

export class SabrSession {
  readonly stream: SabrStream
  readonly created = Date.now()
  owner: SabrSessionOwner | undefined
  private failed = false

  constructor(
    readonly track: NativeTrack,
    info: NativeSabrInfo,
    services: SabrServices,
    readonly audioItag: number,
    readonly videoItag: number | undefined,
    options: NativeSetupOptions,
    mode: 'playback' | 'download' = 'playback'
  ) {
    const trackId = track.id
    const fail = (e: unknown) => {
      const error = new EPError('sabr-callback-failed', e instanceof Error ? e.message : String(e), trackId)
      this.failed = true
      this.owner?.sessionCallbackFailed(this, error)
      return error
    }
    const maxBytes = options.bufferConfig.maxBufferBytes
    this.stream = new SabrStream({
      videoId: info.videoId,
      fetchFunction: sabrFetch(track, services.host()),
      serverAbrStreamingUrl: info.serverAbrStreamingUrl,
      videoPlaybackUstreamerConfig: info.videoPlaybackUstreamerConfig,
      poToken: info.poToken || undefined,
      clientInfo: { clientName: info.clientInfo.clientName, clientVersion: info.clientInfo.clientVersion },
      formats: info.formats.map(toGoogleFormat),
      stripDuplicateInit: true,
      videoHighWaterMark: mode === 'download' ? Math.max(1 << 20, maxBytes) : Math.max(256 << 10, Math.floor(maxBytes / 16)),
      audioHighWaterMark: mode === 'download' ? Math.max(512 << 10, Math.min(3 << 20, Math.floor(maxBytes / 4))) : 64 << 10,
      callbacks: {
        onMintPoToken: async () => {
          const provider = services.provider
          if (!provider) throw fail('No SABR callback provider')
          try {
            const token = await withTimeout(provider.mint(trackId), services.timeoutMs, 'onMintPoToken')
            return base64ToU8(token)
          } catch (e) {
            throw fail(e)
          }
        },
        onReloadPlayerResponse: async (context) => {
          const provider = services.provider
          if (!provider) throw fail('No SABR callback provider')
          try {
            const token = context?.reloadPlaybackParams?.token
            const response = await withTimeout(
              provider.reload(trackId, {
                reloadPlaybackParams: context?.reloadPlaybackParams ? { token } : undefined,
              }),
              services.timeoutMs,
              'onReloadPlayerResponse'
            )
            if (track.sabr) {
              track.sabr.serverAbrStreamingUrl = response.serverAbrStreamingUrl
              track.sabr.videoPlaybackUstreamerConfig = response.videoPlaybackUstreamerConfig
            }
            return response
          } catch (e) {
            throw fail(e)
          }
        },
      },
    })
    this.stream.on('error', (e) => {
      this.failed = true
      this.owner?.sessionFailed(this, e)
    })
    this.stream.on('finish', () => this.owner?.sessionFinished(this))
  }

  get isUsable(): boolean {
    return !this.failed && !this.stream.isAborted && !this.stream.isErrored
  }

  get age(): number {
    return Date.now() - this.created
  }

  private options(at: number) {
    return {
      audioFormat: this.audioItag,
      videoFormat: this.videoItag,
      enabledTrackTypes: this.videoItag === undefined ? EnabledTrackTypes.AUDIO_ONLY : EnabledTrackTypes.VIDEO_AND_AUDIO,
      startTimeMs: Math.round(at * 1000),
      isPostLiveDvr: false,
    }
  }

  start(at: number): StreamStartResult {
    return this.stream.start(this.options(at))
  }

  warm(at: number): void {
    this.stream.warm(this.options(at))
  }

  abort(): void {
    this.owner = undefined
    this.stream.abort().catch(() => {})
  }
}

export class SabrWarmPool {
  static readonly maxAgeMs = 240_000
  private entries = new Map<string, SabrSession>()

  constructor(private readonly services: SabrServices) {}

  warm(tracks: NativeTrack[], options: NativeSetupOptions, range: NativeVideoQualityRange): void {
    const keep = new Set<string>()
    for (const track of tracks) {
      const info = track.sabr
      if (!info) continue
      const itags = selectItags(info, options, range)
      if (!itags) continue
      keep.add(track.id)
      const existing = this.entries.get(track.id)
      if (
        existing &&
        existing.isUsable &&
        existing.age < SabrWarmPool.maxAgeMs &&
        existing.audioItag === itags.audio.itag &&
        existing.videoItag === itags.video?.itag
      ) {
        continue
      }
      try {
        const session = new SabrSession(track, info, this.services, itags.audio.itag, itags.video?.itag, options)
        session.warm(trimStart(track))
        this.entries.set(track.id, session)
        existing?.abort()
      } catch {}
    }
    for (const [id, session] of this.entries) {
      if (!keep.has(id)) {
        session.abort()
        this.entries.delete(id)
      }
    }
  }

  take(trackId: string, audioItag: number, videoItag: number | undefined): SabrSession | undefined {
    const session = this.entries.get(trackId)
    if (!session) return undefined
    this.entries.delete(trackId)
    if (
      !session.isUsable ||
      session.age >= SabrWarmPool.maxAgeMs ||
      session.audioItag !== audioItag ||
      session.videoItag !== videoItag
    ) {
      session.abort()
      return undefined
    }
    return session
  }

  clear(): void {
    for (const session of this.entries.values()) session.abort()
    this.entries.clear()
  }
}
