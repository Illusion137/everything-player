import { BufferFeeder, MseSink, type ChunkReader } from '../MseSink'
import { EPError } from '../models'
import { Pipeline } from './Pipeline'

export interface MseStreams {
  audio: ChunkReader
  video?: ChunkReader
}

export abstract class MsePipeline extends Pipeline {
  protected sink: MseSink | undefined
  protected audioFeeder: BufferFeeder | undefined
  protected videoFeeder: BufferFeeder | undefined
  protected generation = 0
  protected producedAudio = false

  protected abstract audioMime(): string
  protected abstract videoMime(): string | undefined
  protected abstract knownDuration(): number | undefined

  protected async attachSink(): Promise<boolean> {
    const sink = new MseSink(this.element)
    this.sink = sink
    await sink.attach()
    if (this.disposed) return false
    this.sourceAttached = true
    const duration = this.knownDuration()
    if (duration !== undefined) sink.setDuration(duration)
    this.audioFeeder = sink.addBuffer(this.audioMime())
    const video = this.videoMime()
    if (video) this.videoFeeder = sink.addBuffer(video)
    this.delegate?.pipelineDuration(this)
    return true
  }

  protected forwardSeconds(): number {
    return Math.max(5, this.ctx.options.bufferConfig.forwardBufferSeconds)
  }

  protected nextGeneration(): number {
    this.generation += 1
    this.producedAudio = false
    return this.generation
  }

  protected async feed(streams: MseStreams, generation: number, seekTo: number | undefined): Promise<void> {
    const isCurrent = () => !this.disposed && this.generation === generation
    const forward = () => this.forwardSeconds()
    await Promise.all([this.audioFeeder?.reset(), this.videoFeeder?.reset()])
    if (!isCurrent()) {
      streams.audio.release()
      streams.video?.release()
      return
    }
    if (seekTo !== undefined) this.element.currentTime = seekTo
    const jobs: Promise<'done' | 'superseded'>[] = []
    if (this.audioFeeder) {
      jobs.push(
        this.audioFeeder.consume(streams.audio, isCurrent, forward, () => {
          this.producedAudio = true
        })
      )
    } else {
      streams.audio.release()
    }
    if (this.videoFeeder && streams.video) {
      jobs.push(this.videoFeeder.consume(streams.video, isCurrent, forward))
    } else {
      streams.video?.release()
    }
    try {
      const results = await Promise.all(jobs)
      if (isCurrent() && results.every((r) => r === 'done')) await this.sink?.end()
    } catch (e) {
      if (isCurrent()) this.streamError(e)
    }
  }

  protected streamError(error: unknown): void {
    const message = error instanceof Error ? error.message : String(error)
    if (/SourceBuffer|append|decode/i.test(message)) {
      this.fail(new EPError('decode-error', message))
    }
  }

  protected isBuffered(seconds: number): boolean {
    const feeders = [this.audioFeeder, this.videoFeeder].filter((f): f is BufferFeeder => !!f)
    return feeders.length > 0 && feeders.every((f) => f.bufferedAhead(seconds) > 1)
  }

  protected abstract reopen(at: number): void

  protected performSeek(seconds: number): void {
    if (this.isBuffered(seconds)) {
      this.element.currentTime = seconds
      return
    }
    this.reopen(seconds)
  }

  protected isSeekPending(): boolean {
    return this.frozenPosition !== undefined && !this.isBuffered(this.frozenPosition)
  }

  get mediaDuration(): number | undefined {
    return this.knownDuration() ?? super.mediaDuration
  }

  get bufferedTime(): number {
    const position = this.currentTime
    const ends = [this.audioFeeder, this.videoFeeder]
      .filter((f): f is BufferFeeder => !!f)
      .map((f) => f.bufferedEnd(position))
    return ends.length ? Math.min(...ends) : position
  }

  protected async switchVideo(mime: string, at: number): Promise<void> {
    const feeder = this.videoFeeder
    if (!feeder) return
    await feeder.changeType(mime)
    await feeder.removeFrom(at + 0.25)
  }

  protected releaseSink(): void {
    this.generation += 1
    this.sink?.dispose()
    this.sink = undefined
    this.audioFeeder = undefined
    this.videoFeeder = undefined
  }
}
