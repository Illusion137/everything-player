import { EPError, requestHeaders } from '../models'
import { Pipeline } from './Pipeline'

export class RawPipeline extends Pipeline {
  private initialSeek: number | undefined

  protected async start(at: number): Promise<void> {
    const local = this.ctx.local
    let url: string
    if (local) {
      url = this.ctx.host.fileUrl(local.path)
    } else {
      if (!this.track.url) throw new EPError('source-error', 'Track has no URL')
      url = this.track.url
      await this.ctx.host.prepare(url, requestHeaders(this.track))
    }
    if (this.disposed) return
    this.initialSeek = at > 0 ? at : undefined
    if (this.initialSeek !== undefined) this.frozenPosition = this.initialSeek
    this.element.addEventListener('loadedmetadata', this.applyInitialSeek, { once: true })
    this.element.src = url
    this.sourceAttached = true
    this.element.load()
    if (this.wantsPlay) this.resumeElement()
  }

  private readonly applyInitialSeek = () => {
    if (this.disposed || this.initialSeek === undefined) return
    this.element.currentTime = this.initialSeek
    this.initialSeek = undefined
  }

  protected performSeek(seconds: number): void {
    if (this.initialSeek !== undefined) {
      this.initialSeek = seconds
      return
    }
    this.element.currentTime = seconds
  }

  protected isSeekPending(): boolean {
    return this.initialSeek !== undefined
  }

  protected release(): void {
    this.element.removeEventListener('loadedmetadata', this.applyInitialSeek)
  }
}
