import type { NativeVideoQuality } from '../../../specs/EverythingPlayer.nitro'
import type { FileStore } from '../host'
import type { ChunkReader } from '../MseSink'
import { EPError, type QualityState } from '../models'
import { MsePipeline } from './MsePipeline'

export type IndexedSegment = [startMs: number, durationMs: number, offset: number, length: number]

export interface SegmentIndex {
  mime: string
  initLength: number
  segments: IndexedSegment[]
  quality?: NativeVideoQuality
}

export function indexPathFor(mediaPath: string): string {
  return `${mediaPath}.idx.json`
}

function fileReader(files: FileStore, path: string, index: SegmentIndex, at: number): ChunkReader {
  const atMs = at * 1000
  let next = index.segments.findIndex(([start, duration]) => start + duration > atMs)
  if (next < 0) next = index.segments.length
  let sentInit = index.initLength <= 0
  let released = false
  return {
    read: async () => {
      if (released) return { done: true }
      if (!sentInit) {
        sentInit = true
        return { done: false, value: await files.read(path, 0, index.initLength) }
      }
      const segment = index.segments[next]
      if (!segment) return { done: true }
      next += 1
      const [, , offset, length] = segment
      return { done: false, value: await files.read(path, offset, offset + length) }
    },
    release: () => {
      released = true
    },
  }
}

export class LocalSabrPipeline extends MsePipeline {
  private audioIndex: SegmentIndex | undefined
  private videoIndex: SegmentIndex | undefined

  protected audioMime(): string {
    return this.audioIndex?.mime ?? ''
  }

  protected videoMime(): string | undefined {
    return this.videoIndex?.mime
  }

  protected knownDuration(): number | undefined {
    const segments = this.audioIndex?.segments
    const last = segments?.[segments.length - 1]
    if (last) return (last[0] + last[1]) / 1000
    return this.track.duration
  }

  private get files(): FileStore {
    const files = this.ctx.host.files
    if (!files) throw new EPError('source-error', 'Downloaded files are unavailable')
    return files
  }

  private async readIndex(path: string): Promise<SegmentIndex> {
    const raw = await this.files.read(indexPathFor(path))
    return JSON.parse(new TextDecoder().decode(raw)) as SegmentIndex
  }

  protected async start(at: number): Promise<void> {
    const local = this.ctx.local
    if (!local) throw new EPError('source-error', 'Missing local media')
    this.audioIndex = await this.readIndex(local.path)
    if (this.ctx.options.enableVideo && local.videoPath) {
      this.videoIndex = await this.readIndex(local.videoPath).catch(() => undefined)
    }
    if (this.disposed) return
    if (!(await this.attachSink())) return
    this.frozenPosition = at
    this.reopen(at)
    this.delegate?.pipelineQuality(this)
  }

  protected reopen(at: number): void {
    const local = this.ctx.local
    const audioIndex = this.audioIndex
    if (!local || !audioIndex) return
    const generation = this.nextGeneration()
    const files = this.files
    const video =
      this.videoIndex && local.videoPath
        ? fileReader(files, local.videoPath, this.videoIndex, at)
        : undefined
    this.feed({ audio: fileReader(files, local.path, audioIndex, at), video }, generation, at).catch((e) =>
      this.streamError(e)
    )
  }

  get hasVideo(): boolean {
    return this.videoIndex !== undefined && this.element.videoWidth > 0
  }

  videoQuality(): QualityState {
    const quality = this.videoIndex?.quality
    if (!quality) return { qualities: [], automatic: true }
    return { qualities: [quality], selectedId: quality.id, automatic: false }
  }

  protected release(): void {
    this.releaseSink()
  }
}
