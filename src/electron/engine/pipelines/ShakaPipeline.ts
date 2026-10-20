import type shakaNamespace from 'shaka-player'
import type { NativeVideoQualityRange } from '../../../specs/EverythingPlayer.nitro'
import { currentHost } from '../host'
import { EPError, requestHeaders, type QualityState } from '../models'
import { Pipeline } from './Pipeline'

type Shaka = typeof shakaNamespace
type ShakaPlayer = InstanceType<Shaka['Player']>
type ShakaTrack = ReturnType<ShakaPlayer['getVariantTracks']>[number]

export const LOCAL_SCHEME = 'everything-player-local'

const LOCAL_TYPES: Record<string, string> = {
  m3u8: 'application/vnd.apple.mpegurl',
  ts: 'video/mp2t',
  aac: 'audio/aac',
  mp3: 'audio/mpeg',
  mp4: 'video/mp4',
  m4s: 'video/mp4',
  m4a: 'audio/mp4',
  m4v: 'video/mp4',
  vtt: 'text/vtt',
  webm: 'video/webm',
}

let shakaPromise: Promise<Shaka> | undefined

export function loadShaka(): Promise<Shaka> {
  shakaPromise ??= import('shaka-player').then((mod) => {
    const shaka = ((mod as { default?: Shaka }).default ?? mod) as Shaka
    shaka.polyfill.installAll()
    shaka.net.NetworkingEngine.registerScheme(LOCAL_SCHEME, localScheme(shaka))
    return shaka
  })
  return shakaPromise
}

function localScheme(shaka: Shaka) {
  return (uri: string, request: { uris: string[] }) => {
    const promise = (async () => {
      const files = currentHost()?.files
      if (!files) throw new Error('Local files are unavailable')
      const path = decodeURIComponent(uri.slice(`${LOCAL_SCHEME}://local/`.length).split(/[?#]/)[0] ?? '')
      const data = await files.read(path)
      return {
        uri,
        originalUri: uri,
        data: data.buffer.slice(data.byteOffset, data.byteOffset + data.byteLength) as ArrayBuffer,
        headers: { 'content-type': LOCAL_TYPES[path.split('.').pop()?.toLowerCase() ?? ''] ?? 'application/octet-stream' },
        originalRequest: request,
        status: 200,
      }
    })()
    return shaka.util.AbortableOperation.notAbortable(promise as never) as never
  }
}

export function localPlaylistUri(path: string): string {
  return `${LOCAL_SCHEME}://local/${path.split(/[\\/]+/).filter(Boolean).map(encodeURIComponent).join('/')}`
}

function restrictions(range: NativeVideoQualityRange) {
  return {
    minHeight: range.minHeight ?? 0,
    maxHeight: range.maxHeight ?? Infinity,
    maxBandwidth: range.maxBitrate && range.maxBitrate > 0 ? range.maxBitrate : Infinity,
  }
}

export class ShakaPipeline extends Pipeline {
  private player: ShakaPlayer | undefined
  private shaka: Shaka | undefined
  private range: NativeVideoQualityRange = this.ctx.range
  private manualId: string | undefined

  protected async start(at: number): Promise<void> {
    const shaka = await loadShaka()
    if (this.disposed) return
    this.shaka = shaka
    const local = this.ctx.local
    const uri = local ? localPlaylistUri(local.path) : this.track.url
    if (!uri) throw new EPError('source-error', 'Track has no URL')
    try {
      await this.loadWith(shaka, uri, at, !this.ctx.options.enableVideo)
    } catch (e) {
      if (this.disposed) return
      if (!this.ctx.options.enableVideo && isNoPlayableVariant(e)) {
        try {
          await this.loadWith(shaka, uri, at, false)
        } catch (retryError) {
          if (!this.disposed) throw shakaError(retryError as ShakaErrorDetail)
        }
        return
      }
      throw shakaError(e as ShakaErrorDetail)
    }
  }

  private async loadWith(shaka: Shaka, uri: string, at: number, disableVideo: boolean): Promise<void> {
    await this.player?.destroy().catch(() => {})
    const player = new shaka.Player()
    this.player = player
    await player.attach(this.element)
    this.sourceAttached = true
    const buffer = this.ctx.options.bufferConfig
    player.configure({
      streaming: {
        bufferingGoal: Math.max(5, buffer.forwardBufferSeconds),
        rebufferingGoal: 1,
        bufferBehind: 30,
      },
      manifest: { disableVideo },
      abr: { enabled: true, restrictions: restrictions(this.range) },
    })
    if (!this.ctx.local) {
      const headers = requestHeaders(this.track)
      const host = this.ctx.host
      player.getNetworkingEngine()?.registerRequestFilter(async (_type, request) => {
        await Promise.all(request.uris.map((u) => host.prepare(u, headers)))
        if (!host.managesHeaders) Object.assign(request.headers, headers)
      })
    }
    player.addEventListener('error', (event) => {
      const detail = (event as unknown as { detail?: ShakaErrorDetail }).detail
      if (detail?.severity === 2) this.fail(shakaError(detail))
    })
    const quality = () => this.delegate?.pipelineQuality(this)
    player.addEventListener('adaptation', quality)
    player.addEventListener('variantchanged', quality)
    player.addEventListener('trackschanged', quality)
    if (at > 0) this.frozenPosition = at
    await player.load(uri, at > 0 ? at : null)
    if (this.disposed) return
    this.frozenPosition = undefined
    this.delegate?.pipelineDuration(this)
    this.delegate?.pipelineQuality(this)
    if (this.manualId !== undefined) this.applyQuality()
    if (this.wantsPlay) this.resumeElement()
  }

  get mediaDuration(): number | undefined {
    if (this.player?.isLive()) return undefined
    return super.mediaDuration
  }

  private variants(): ShakaTrack[] {
    return (this.player?.getVariantTracks() ?? []).filter((t) => (t.height ?? 0) > 0)
  }

  videoQuality(): QualityState {
    const tracks = this.variants()
    const seen = new Set<string>()
    const qualities = tracks
      .sort((a, b) => (b.height ?? 0) - (a.height ?? 0) || b.bandwidth - a.bandwidth)
      .filter((t) => {
        const key = `${t.height}:${t.bandwidth}`
        if (seen.has(key)) return false
        seen.add(key)
        return true
      })
      .map((t) => ({
        id: String(t.id),
        width: t.width ?? undefined,
        height: t.height ?? undefined,
        fps: t.frameRate ?? undefined,
        bitrate: t.videoBandwidth ?? t.bandwidth,
        label: t.height ? `${t.height}p` : `${Math.round(t.bandwidth / 1000)} kbps`,
        codec: t.videoCodec ?? undefined,
      }))
    const active = tracks.find((t) => t.active)
    const automatic = this.manualId === undefined
    return {
      qualities,
      selectedId: active ? String(active.id) : undefined,
      automatic,
    }
  }

  setVideoQuality(id: string | undefined, range: NativeVideoQualityRange): void {
    this.range = range
    if (id !== undefined && !this.variants().some((t) => String(t.id) === id)) {
      throw new EPError('unknown', `Unknown video quality ${id}`)
    }
    this.manualId = id
    this.applyQuality()
    this.delegate?.pipelineQuality(this)
  }

  private applyQuality(): void {
    const player = this.player
    if (!player) return
    if (this.manualId === undefined) {
      player.configure({ abr: { enabled: true, restrictions: restrictions(this.range) } })
      return
    }
    const track = this.variants().find((t) => String(t.id) === this.manualId)
    if (!track) return
    player.configure({ abr: { enabled: false } })
    player.selectVariantTrack(track, true, 1)
  }

  protected release(): Promise<void> | void {
    const player = this.player
    this.player = undefined
    return player?.destroy()
  }

  protected onElementError(error: MediaError | null): void {
    if (this.shaka) return
    super.onElementError(error)
  }
}

function isNoPlayableVariant(error: unknown): boolean {
  const code = (error as { code?: number } | undefined)?.code
  return code === 4032 || code === 4011 || code === 4012
}

interface ShakaErrorDetail {
  code?: number
  severity?: number
  message?: string
}

function shakaError(detail: ShakaErrorDetail | undefined): EPError {
  if (detail instanceof EPError) return detail
  const code = detail?.code ?? 0
  const message = detail?.message || `Shaka error ${code}`
  if (code >= 1000 && code < 2000) return new EPError('network-error', message)
  if (code >= 3000 && code < 4000) return new EPError('decode-error', message)
  return new EPError('source-error', message)
}
