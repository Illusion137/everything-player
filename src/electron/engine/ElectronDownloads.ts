import type {
  NativeDownload,
  NativeDownloadOptions,
  NativeDownloadState,
} from '../../specs/DownloadManager.nitro'
import type {
  NativeTrack,
  NativeVideoQualityRange,
} from '../../specs/EverythingPlayer.nitro'
import type { DownloadBackend } from '../../internal/native'
import type { EmittedSegment } from '../vendor/googlevideo/src/types/sabrStreamTypes'
import { currentSetupOptions, ensureHost, sabrServices } from './ElectronPlayer'
import { downloadHls } from './hls'
import type { FileStore, Host } from './host'
import { EPError, requestHeaders, sourceTypeOf } from './models'
import type { LocalMedia } from './pipelines/Pipeline'
import { indexPathFor, type IndexedSegment, type SegmentIndex } from './pipelines/LocalSabrPipeline'
import { pickAudio, pickVideo, qualityOf, SabrSession } from './sabr'

interface DownloadRecord {
  trackId: string
  track: NativeTrack
  state: NativeDownloadState
  progress: number
  bytesDownloaded: number
  totalBytes?: number
  kind?: 'file' | 'hls' | 'sabr'
  audioPath?: string
  videoPath?: string
  includeVideo: boolean
  videoQuality?: NativeVideoQualityRange
  errorCode?: string
  errorMessage?: string
}

const INDEX = 'index.json'
const WRITE_BATCH = 1 << 20

function isLive(state: NativeDownloadState): boolean {
  return state === 'queued' || state === 'downloading' || state === 'paused'
}

function safeName(trackId: string): string {
  return trackId.replace(/[^A-Za-z0-9_-]/g, '_')
}

function extensionFor(url: string, contentType: string | null): string {
  try {
    const ext = /\.([A-Za-z0-9]{1,5})$/.exec(new URL(url).pathname)?.[1]
    if (ext) return ext.toLowerCase()
  } catch {}
  const type = contentType?.split(';')[0]?.trim().toLowerCase()
  const known: Record<string, string> = {
    'audio/mpeg': 'mp3',
    'audio/mp4': 'm4a',
    'audio/aac': 'aac',
    'audio/ogg': 'ogg',
    'audio/webm': 'webm',
    'audio/flac': 'flac',
    'audio/wav': 'wav',
    'video/mp4': 'mp4',
    'video/webm': 'webm',
  }
  return (type && known[type]) || 'm4a'
}

class ChunkWriter {
  private pending: Uint8Array[] = []
  private size = 0
  written = 0

  constructor(
    private readonly files: FileStore,
    private readonly path: string
  ) {}

  async push(chunk: Uint8Array): Promise<void> {
    this.pending.push(chunk)
    this.size += chunk.byteLength
    this.written += chunk.byteLength
    if (this.size >= WRITE_BATCH) await this.flush()
  }

  async flush(): Promise<void> {
    if (this.size === 0) return
    const out = new Uint8Array(this.size)
    let offset = 0
    for (const c of this.pending) {
      out.set(c, offset)
      offset += c.byteLength
    }
    this.pending = []
    this.size = 0
    await this.files.write(this.path, out, true)
  }
}

export class ElectronDownloads implements DownloadBackend {
  private records = new Map<string, DownloadRecord>()
  private tasks = new Map<string, AbortController>()
  private onChanged: ((download: NativeDownload) => void) | undefined
  private host: Host | undefined
  private persistTimer: ReturnType<typeof setTimeout> | undefined
  readonly ready: Promise<void>

  constructor() {
    this.ready = this.load()
  }

  private async load(): Promise<void> {
    this.host = await ensureHost()
    const files = this.host.files
    if (!files || !(await files.stat(INDEX))) return
    try {
      const raw = await files.read(INDEX)
      const parsed = JSON.parse(new TextDecoder().decode(raw)) as Record<string, DownloadRecord>
      for (const [id, record] of Object.entries(parsed)) {
        if (record.state === 'downloading' || record.state === 'queued') record.state = 'paused'
        if (!this.records.has(id)) this.records.set(id, record)
      }
    } catch {}
  }

  private files(): FileStore {
    const files = this.host?.files
    if (!files) {
      throw new EPError('unknown', 'Downloads need the Electron host (see react-native-everything-player/electron/main)')
    }
    return files
  }

  private persist(immediate = false): void {
    if (this.persistTimer !== undefined) clearTimeout(this.persistTimer)
    this.persistTimer = undefined
    const write = () => {
      const files = this.host?.files
      if (!files) return
      const data = Object.fromEntries(this.records)
      files.write(INDEX, new TextEncoder().encode(JSON.stringify(data))).catch(() => {})
    }
    if (immediate) write()
    else this.persistTimer = setTimeout(write, 1000)
  }

  private mutate(trackId: string, body: (r: DownloadRecord) => void, immediate = true): void {
    const record = this.records.get(trackId)
    if (!record) return
    body(record)
    this.persist(immediate)
    this.onChanged?.(this.toNative(record))
  }

  private absolute(path: string | undefined): string | undefined {
    return path && this.host?.files ? this.host.files.absolute(path) : undefined
  }

  private toNative(r: DownloadRecord): NativeDownload {
    const completed = r.state === 'completed'
    const audio = completed ? this.absolute(r.audioPath) : undefined
    const video = completed ? this.absolute(r.videoPath) : undefined
    return {
      trackId: r.trackId,
      state: r.state,
      progress: r.progress,
      bytesDownloaded: r.bytesDownloaded,
      totalBytes: r.totalBytes,
      localPath: audio,
      audioPath: r.kind === 'sabr' ? audio : undefined,
      videoPath: r.kind === 'sabr' ? video : undefined,
      errorCode: r.errorCode,
      errorMessage: r.errorMessage,
      track: r.track,
    }
  }

  localMedia(track: NativeTrack): LocalMedia | undefined {
    const r = this.records.get(track.id)
    if (!r || r.state !== 'completed' || !r.audioPath || !this.host?.files) return undefined
    if (r.kind === 'sabr' && track.sabr) {
      return { kind: 'sabr', path: r.audioPath, videoPath: r.videoPath }
    }
    if (r.kind === 'hls') return { kind: 'hls', path: r.audioPath }
    return { kind: 'file', path: r.audioPath }
  }

  async download(track: NativeTrack, options: NativeDownloadOptions): Promise<NativeDownload> {
    await this.ready
    this.files()
    const existing = this.records.get(track.id)
    if (existing && (existing.state === 'completed' || existing.state === 'downloading' || existing.state === 'queued')) {
      return this.toNative(existing)
    }
    const record: DownloadRecord = {
      trackId: track.id,
      track: { ...track },
      state: 'queued',
      progress: 0,
      bytesDownloaded: 0,
      includeVideo: options.includeVideo,
      videoQuality: options.videoQuality ?? currentSetupOptions().videoQuality,
    }
    this.records.set(track.id, record)
    this.persist(true)
    this.onChanged?.(this.toNative(record))
    this.start(track.id)
    return this.toNative(this.records.get(track.id) ?? record)
  }

  private start(trackId: string): void {
    const record = this.records.get(trackId)
    if (!record) return
    this.tasks.get(trackId)?.abort()
    const controller = new AbortController()
    this.tasks.set(trackId, controller)
    this.mutate(trackId, (r) => {
      r.state = 'downloading'
      r.errorCode = undefined
      r.errorMessage = undefined
    })
    const run = async () => {
      const track = record.track
      const range = record.videoQuality ?? currentSetupOptions().videoQuality
      switch (sourceTypeOf(track)) {
        case 'sabr':
          return this.runSabr(record, range, controller.signal)
        case 'hls':
          return this.runHls(record, range, controller.signal)
        default:
          return this.runRaw(record, controller.signal)
      }
    }
    run()
      .catch((e) => {
        if (controller.signal.aborted) return
        const error = EPError.from(e, 'source-error')
        this.mutate(trackId, (r) => {
          r.state = 'failed'
          r.errorCode = error.code
          r.errorMessage = error.message
        })
      })
      .finally(() => {
        if (this.tasks.get(trackId) === controller) this.tasks.delete(trackId)
      })
  }

  private progress(trackId: string, bytes: number, total: number | undefined, fraction?: number): void {
    this.mutate(
      trackId,
      (r) => {
        r.bytesDownloaded = bytes
        r.totalBytes = total
        r.progress = fraction ?? (total && total > 0 ? Math.min(0.99, bytes / total) : 0)
      },
      false
    )
  }

  private complete(trackId: string, fields: Partial<DownloadRecord>): void {
    this.mutate(trackId, (r) => {
      Object.assign(r, fields)
      r.state = 'completed'
      r.progress = 1
      r.totalBytes = r.bytesDownloaded
    })
  }

  private async runRaw(record: DownloadRecord, signal: AbortSignal): Promise<void> {
    const files = this.files()
    const host = this.host!
    const track = record.track
    const url = track.url
    if (!url) throw new EPError('source-error', 'Invalid URL')
    const id = record.trackId
    const partName = `${safeName(id)}.download`
    const headers = requestHeaders(track)
    await host.prepare(url, headers)
    const existing = (await files.stat(partName))?.size ?? 0
    const init: Record<string, string> = host.managesHeaders ? {} : { ...headers }
    if (existing > 0) init.Range = `bytes=${existing}-`
    const response = await fetch(url, { headers: init, signal })
    if (!response.ok) throw new EPError('network-error', `HTTP ${response.status}`)
    let offset = existing
    if (response.status !== 206) {
      offset = 0
      await files.remove(partName)
    }
    const totalHeader =
      response.status === 206
        ? response.headers.get('content-range')?.split('/')[1]
        : response.headers.get('content-length')
    const expected = totalHeader && totalHeader !== '*' ? Number(totalHeader) : undefined
    const writer = new ChunkWriter(files, partName)
    const reader = response.body?.getReader()
    if (!reader) throw new EPError('network-error', 'Empty response')
    let last = 0
    for (;;) {
      const { done, value } = await reader.read()
      if (done) break
      await writer.push(value)
      if (Date.now() - last > 500) {
        last = Date.now()
        this.progress(id, offset + writer.written, expected)
      }
    }
    await writer.flush()
    const name = `${safeName(id)}.${extensionFor(url, response.headers.get('content-type'))}`
    await files.rename(partName, name)
    this.mutate(id, (r) => {
      r.bytesDownloaded = offset + writer.written
    })
    this.complete(id, { kind: 'file', audioPath: name, videoPath: undefined })
  }

  private async runHls(record: DownloadRecord, range: NativeVideoQualityRange, signal: AbortSignal): Promise<void> {
    const files = this.files()
    const track = record.track
    if (!track.url) throw new EPError('source-error', 'Invalid URL')
    const folder = `${safeName(record.trackId)}.hls`
    const playlist = await downloadHls({
      url: track.url,
      headers: requestHeaders(track),
      includeVideo: record.includeVideo,
      range,
      folder,
      host: this.host!,
      files,
      signal,
      progress: (p) =>
        this.progress(record.trackId, p.bytes, undefined, p.total > 0 ? Math.min(0.99, p.done / p.total) : 0),
    })
    this.complete(record.trackId, { kind: 'hls', audioPath: `${folder}/${playlist}`, videoPath: undefined })
  }

  private async runSabr(record: DownloadRecord, range: NativeVideoQualityRange, signal: AbortSignal): Promise<void> {
    const files = this.files()
    const track = record.track
    const info = track.sabr
    if (!info) throw new EPError('sabr-stream-failed', 'Missing SABR info')
    const audio = pickAudio(info.formats)
    if (!audio) throw new EPError('sabr-stream-failed', 'No downloadable audio format')
    const video = record.includeVideo ? pickVideo(info.formats, range) : undefined
    const options = { ...currentSetupOptions(), enableVideo: video !== undefined }
    const session = new SabrSession(track, info, sabrServices, audio.itag, video?.itag, options, 'download')
    let failure: Error | undefined
    session.owner = {
      sessionCallbackFailed: (_s, e) => {
        failure ??= e
      },
      sessionFailed: (_s, e) => {
        failure ??= e
      },
      sessionFinished: () => {},
    }
    const base = safeName(record.trackId)
    const audioMime = audio.mimeType ?? ''
    const audioName = `${base}.audio.${audioMime.includes('webm') ? 'webm' : 'm4a'}`
    const videoName = video ? `${base}.video.${(video.mimeType ?? '').includes('webm') ? 'webm' : 'mp4'}` : undefined
    const expected = (audio.contentLength ?? 0) + (video?.contentLength ?? 0)
    const metas: Record<'audio' | 'video', EmittedSegment[]> = { audio: [], video: [] }
    session.stream.on('segment', (s) => metas[s.type].push(s))
    const onAbort = () => session.abort()
    signal.addEventListener('abort', onAbort)
    let total = 0
    let last = 0
    const drain = async (type: 'audio' | 'video', stream: ReadableStream<ArrayBufferView>, name: string, mime: string) => {
      const part = `${name}.part`
      await files.remove(part)
      const writer = new ChunkWriter(files, part)
      const index: SegmentIndex = { mime, initLength: 0, segments: [] }
      const reader = stream.getReader()
      for (;;) {
        const { done, value } = await reader.read()
        if (done) break
        const chunk = new Uint8Array(value.buffer, value.byteOffset, value.byteLength)
        const meta = metas[type].shift()
        const offset = writer.written
        if (meta?.isInit || (!meta && offset === 0)) {
          if (offset === 0) index.initLength = chunk.byteLength
        } else if (meta) {
          const segment: IndexedSegment = [meta.startTimeMs, meta.durationMs, offset, chunk.byteLength]
          index.segments.push(segment)
        }
        await writer.push(chunk)
        total += chunk.byteLength
        if (Date.now() - last > 500) {
          last = Date.now()
          this.progress(record.trackId, total, expected > 0 ? expected : undefined)
        }
      }
      await writer.flush()
      return { part, index }
    }
    try {
      const result = session.start(0)
      const jobs = [drain('audio', result.audioStream, audioName, audioMime)]
      if (video && videoName) jobs.push(drain('video', result.videoStream, videoName, video.mimeType ?? ''))
      const outputs = await Promise.all(jobs)
      session.abort()
      if (signal.aborted) return
      if (failure) throw failure
      const [audioOut, videoOut] = outputs
      await files.rename(audioOut!.part, audioName)
      await files.write(indexPathFor(audioName), new TextEncoder().encode(JSON.stringify(audioOut!.index)))
      if (videoOut && videoName && video) {
        videoOut.index.quality = qualityOf(video)
        await files.rename(videoOut.part, videoName)
        await files.write(indexPathFor(videoName), new TextEncoder().encode(JSON.stringify(videoOut.index)))
      }
      this.mutate(record.trackId, (r) => {
        r.bytesDownloaded = total
      })
      this.complete(record.trackId, { kind: 'sabr', audioPath: audioName, videoPath: videoName })
    } catch (e) {
      session.abort()
      throw failure ?? e
    } finally {
      signal.removeEventListener('abort', onAbort)
    }
  }

  pause(trackId: string): void {
    const task = this.tasks.get(trackId)
    this.tasks.delete(trackId)
    task?.abort()
    this.mutate(trackId, (r) => {
      if (isLive(r.state)) r.state = 'paused'
    })
  }

  resume(trackId: string): void {
    const r = this.records.get(trackId)
    if (!r || !(r.state === 'paused' || r.state === 'failed' || r.state === 'cancelled')) return
    this.start(trackId)
  }

  cancel(trackId: string): void {
    const task = this.tasks.get(trackId)
    this.tasks.delete(trackId)
    task?.abort()
    this.mutate(trackId, (r) => {
      if (r.state !== 'completed') r.state = 'cancelled'
    })
  }

  async remove(trackId: string): Promise<void> {
    await this.ready
    this.cancel(trackId)
    const r = this.records.get(trackId)
    this.records.delete(trackId)
    const files = this.host?.files
    if (files) {
      const base = safeName(trackId)
      const paths = new Set<string>([`${base}.hls`, `${base}.download`])
      for (const p of [r?.audioPath, r?.videoPath]) {
        if (!p) continue
        paths.add(p.includes('/') ? p.split('/')[0]! : p)
        if (!p.includes('/')) {
          paths.add(indexPathFor(p))
          paths.add(`${p}.part`)
        }
      }
      await Promise.all([...paths].map((p) => files.remove(p).catch(() => {})))
    }
    this.persist(true)
  }

  async removeAll(): Promise<void> {
    await this.ready
    for (const id of [...this.records.keys()]) await this.remove(id)
  }

  getDownload(trackId: string): NativeDownload | undefined {
    const r = this.records.get(trackId)
    return r ? this.toNative(r) : undefined
  }

  getDownloads(): NativeDownload[] {
    return [...this.records.values()].map((r) => this.toNative(r))
  }

  setOnDownloadChanged(callback: (download: NativeDownload) => void): void {
    this.onChanged = callback
  }
}

let engine: ElectronDownloads | undefined

export function downloadsEngine(): ElectronDownloads {
  engine ??= new ElectronDownloads()
  return engine
}
