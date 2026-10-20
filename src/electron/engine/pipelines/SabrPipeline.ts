import type {
  NativeSabrFormat,
  NativeSabrInfo,
  NativeVideoQualityRange,
} from '../../../specs/EverythingPlayer.nitro'
import { streamReader } from '../MseSink'
import { EPError, type QualityState } from '../models'
import {
  pickAudio,
  pickVideo,
  qualityOf,
  SabrSession,
  videoFormats,
  type SabrSessionOwner,
} from '../sabr'
import type { StreamStartResult } from '../../vendor/googlevideo/src/types/sabrStreamTypes'
import { MsePipeline } from './MsePipeline'

export class SabrPipeline extends MsePipeline implements SabrSessionOwner {
  private session: SabrSession | undefined
  private audioFormat: NativeSabrFormat | undefined
  private videoFormat: NativeSabrFormat | undefined
  private manualItag: number | undefined
  private range: NativeVideoQualityRange = this.ctx.range
  private reused = false
  private retried = false
  private adopted: SabrSession | undefined

  private get info(): NativeSabrInfo {
    return this.track.sabr!
  }

  protected audioMime(): string {
    return this.audioFormat?.mimeType ?? ''
  }

  protected videoMime(): string | undefined {
    return this.videoFormat?.mimeType
  }

  protected knownDuration(): number | undefined {
    if (this.info.duration > 0) return this.info.duration
    return this.track.duration
  }

  protected async start(at: number): Promise<void> {
    this.audioFormat = pickAudio(this.info.formats)
    if (!this.audioFormat) {
      throw new EPError('sabr-stream-failed', 'No playable SABR audio format')
    }
    this.videoFormat = this.ctx.options.enableVideo ? this.chooseVideo() : undefined
    this.adopted = this.ctx.sabr.pool.take(this.track.id, this.audioFormat.itag, this.videoFormat?.itag)
    if (!(await this.attachSink())) return
    this.frozenPosition = at
    this.open(at, true, at)
    this.delegate?.pipelineQuality(this)
  }

  private chooseVideo(): NativeSabrFormat | undefined {
    if (this.manualItag !== undefined) {
      const pinned = videoFormats(this.info.formats).find((f) => f.itag === this.manualItag)
      if (pinned) return pinned
    }
    return pickVideo(this.info.formats, this.range)
  }

  private open(at: number, allowWarm: boolean, seekTo: number | undefined): void {
    const generation = this.nextGeneration()
    const audioItag = this.audioFormat!.itag
    const videoItag = this.videoFormat?.itag
    let session: SabrSession | undefined
    let result: StreamStartResult | undefined
    if (allowWarm) {
      const warm = this.adopted
      this.adopted = undefined
      result = warm?.stream.seek(at * 1000)
      if (warm && result) session = warm
      else warm?.abort()
    }
    this.reused = session !== undefined
    if (!session || !result) {
      session = new SabrSession(this.track, this.info, this.ctx.sabr, audioItag, videoItag, this.ctx.options)
      result = session.start(at)
    }
    if (this.session && this.session !== session) this.session.abort()
    this.session = session
    session.owner = this
    this.consume(result, generation, seekTo)
  }

  private consume(result: StreamStartResult, generation: number, seekTo: number | undefined): void {
    this.feed(
      {
        audio: streamReader(result.audioStream),
        video: this.videoFormat ? streamReader(result.videoStream) : undefined,
      },
      generation,
      seekTo
    ).catch((e) => this.streamError(e))
  }

  protected reopen(at: number): void {
    const session = this.session
    if (session?.isUsable) {
      const generation = this.nextGeneration()
      const result = session.stream.seek(at * 1000)
      if (result) {
        this.consume(result, generation, at)
        return
      }
    }
    this.open(at, false, at)
  }

  sessionCallbackFailed(session: SabrSession, error: EPError): void {
    if (session !== this.session) return
    this.fail(error)
  }

  sessionFailed(session: SabrSession, error: Error): void {
    if (session !== this.session || this.disposed) return
    if (this.reused && !this.producedAudio && !this.retried) {
      this.retried = true
      this.open(this.currentTime, false, this.currentTime)
      return
    }
    this.fail(new EPError('sabr-stream-failed', error.message))
  }

  sessionFinished(): void {}

  get hasVideo(): boolean {
    return this.videoFormat !== undefined && this.element.videoWidth > 0
  }

  videoQuality(): QualityState {
    if (!this.ctx.options.enableVideo) return { qualities: [], automatic: true }
    return {
      qualities: videoFormats(this.info.formats).map(qualityOf),
      selectedId: this.videoFormat ? String(this.videoFormat.itag) : undefined,
      automatic: this.manualItag === undefined,
    }
  }

  setVideoQuality(id: string | undefined, range: NativeVideoQualityRange): void {
    this.range = range
    if (id !== undefined) {
      const format = videoFormats(this.info.formats).find((f) => String(f.itag) === id)
      if (!format) throw new EPError('unknown', `Unknown video quality ${id}`)
      this.manualItag = format.itag
    } else {
      this.manualItag = undefined
    }
    if (!this.ctx.options.enableVideo || !this.sink) {
      this.delegate?.pipelineQuality(this)
      return
    }
    const next = this.chooseVideo()
    if (!next || next.itag === this.videoFormat?.itag || !this.videoFeeder) {
      this.delegate?.pipelineQuality(this)
      return
    }
    this.videoFormat = next
    const at = this.currentTime
    this.delegate?.pipelineQuality(this)
    this.switchVideo(next.mimeType ?? '', at)
      .then(() => {
        if (!this.disposed) this.open(at, false, undefined)
      })
      .catch((e) => this.streamError(e))
  }

  protected release(): void {
    this.adopted?.abort()
    this.adopted = undefined
    this.releaseSink()
    this.session?.abort()
    this.session = undefined
  }
}
