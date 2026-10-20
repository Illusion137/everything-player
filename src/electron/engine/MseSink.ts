import { sleep } from './models'

export interface ChunkReader {
  read(): Promise<{ done: boolean; value?: Uint8Array }>
  release(): void
}

export function streamReader(stream: ReadableStream<ArrayBufferView>): ChunkReader {
  const reader = stream.getReader()
  return {
    read: async () => {
      const { done, value } = await reader.read()
      if (done || !value) return { done: true }
      return { done: false, value: new Uint8Array(value.buffer, value.byteOffset, value.byteLength) }
    },
    release: () => {
      try {
        reader.releaseLock()
      } catch {}
    },
  }
}

const BEHIND_SECONDS = 30
const KEEP_BEHIND_SECONDS = 10

export class BufferFeeder {
  private chain: Promise<void> = Promise.resolve()

  constructor(
    private readonly sink: MseSink,
    readonly buffer: SourceBuffer,
    public mime: string
  ) {}

  private run<T>(op: () => Promise<T> | T): Promise<T> {
    const next = this.chain.then(op)
    this.chain = next.then(
      () => {},
      () => {}
    )
    return next
  }

  private settle(): Promise<void> {
    if (!this.buffer.updating) return Promise.resolve()
    return new Promise((resolve, reject) => {
      const done = () => {
        this.buffer.removeEventListener('updateend', done)
        this.buffer.removeEventListener('error', failed)
        resolve()
      }
      const failed = () => {
        this.buffer.removeEventListener('updateend', done)
        this.buffer.removeEventListener('error', failed)
        reject(new Error('SourceBuffer operation failed'))
      }
      this.buffer.addEventListener('updateend', done)
      this.buffer.addEventListener('error', failed)
    })
  }

  private async append(chunk: Uint8Array): Promise<void> {
    for (let attempt = 0; ; attempt++) {
      if (!this.sink.isOpen && this.sink.mediaSource.readyState !== 'ended') return
      try {
        await this.settle()
        this.buffer.appendBuffer(chunk as BufferSource)
        await this.settle()
        return
      } catch (e) {
        if ((e as DOMException)?.name !== 'QuotaExceededError' || attempt >= 20) throw e
        await this.evictBehind(true)
        await sleep(500)
      }
    }
  }

  private async evictBehind(force = false): Promise<void> {
    const ranges = this.buffer.buffered
    if (ranges.length === 0) return
    const now = this.sink.element.currentTime
    const start = ranges.start(0)
    const limit = force ? KEEP_BEHIND_SECONDS / 2 : BEHIND_SECONDS
    if (now - start <= limit) return
    await this.settle()
    this.buffer.remove(start, Math.max(start, now - KEEP_BEHIND_SECONDS))
    await this.settle()
  }

  bufferedAhead(position: number): number {
    const ranges = this.buffer.buffered
    for (let i = 0; i < ranges.length; i++) {
      if (ranges.start(i) <= position + 0.3 && position < ranges.end(i)) {
        return ranges.end(i) - position
      }
    }
    return 0
  }

  bufferedEnd(position: number): number {
    return position + this.bufferedAhead(position)
  }

  reset(): Promise<void> {
    return this.run(async () => {
      if (this.sink.isOpen) {
        try {
          this.buffer.abort()
        } catch {}
      }
    })
  }

  changeType(mime: string): Promise<void> {
    if (mime === this.mime) return Promise.resolve()
    return this.run(async () => {
      await this.settle()
      this.buffer.changeType(mime)
      this.mime = mime
    })
  }

  removeFrom(position: number): Promise<void> {
    return this.run(async () => {
      if (!this.sink.isOpen) return
      await this.settle()
      this.buffer.remove(position, Infinity)
      await this.settle()
    })
  }

  async consume(
    reader: ChunkReader,
    isCurrent: () => boolean,
    forwardSeconds: () => number,
    onChunk?: (chunk: Uint8Array) => void
  ): Promise<'done' | 'superseded'> {
    try {
      for (;;) {
        while (isCurrent() && this.bufferedAhead(this.sink.element.currentTime) > forwardSeconds()) {
          await sleep(250)
        }
        if (!isCurrent()) return 'superseded'
        const { done, value } = await reader.read()
        if (!isCurrent()) return 'superseded'
        if (done || !value) return 'done'
        if (value.byteLength === 0) continue
        await this.run(() => this.append(value))
        onChunk?.(value)
        await this.run(() => this.evictBehind())
      }
    } finally {
      reader.release()
    }
  }
}

export class MseSink {
  readonly mediaSource = new MediaSource()
  private url: string | undefined
  private feeders: BufferFeeder[] = []

  constructor(readonly element: HTMLMediaElement) {}

  get isOpen(): boolean {
    return this.mediaSource.readyState === 'open'
  }

  async attach(): Promise<void> {
    const opened = new Promise<void>((resolve) => {
      this.mediaSource.addEventListener('sourceopen', () => resolve(), { once: true })
    })
    this.url = URL.createObjectURL(this.mediaSource)
    this.element.src = this.url
    await opened
  }

  addBuffer(mime: string): BufferFeeder {
    const feeder = new BufferFeeder(this, this.mediaSource.addSourceBuffer(mime), mime)
    this.feeders.push(feeder)
    return feeder
  }

  setDuration(seconds: number): void {
    if (!this.isOpen || !(seconds > 0)) return
    if (this.feeders.some((f) => f.buffer.updating)) return
    try {
      this.mediaSource.duration = seconds
    } catch {}
  }

  async end(): Promise<void> {
    for (let i = 0; i < 40 && this.feeders.some((f) => f.buffer.updating); i++) await sleep(50)
    if (!this.isOpen) return
    try {
      this.mediaSource.endOfStream()
    } catch {}
  }

  dispose(): void {
    if (this.url) URL.revokeObjectURL(this.url)
    this.url = undefined
    this.feeders = []
  }
}
