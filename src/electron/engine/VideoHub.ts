import type { ResizeMode } from '../../types/VideoSurface'

interface Surface {
  container: HTMLElement
  resizeMode: ResizeMode
  canvas?: HTMLCanvasElement
}

export interface SurfaceHandle {
  setResizeMode(mode: ResizeMode): void
  dispose(): void
}

const FIT: Record<ResizeMode, string> = {
  contain: 'contain',
  cover: 'cover',
  stretch: 'fill',
}

class VideoHub {
  private surfaces: Surface[] = []
  private active: HTMLVideoElement | null = null
  private holder: HTMLDivElement | undefined
  private frameRequest: number | undefined
  private frameElement: HTMLVideoElement | null = null

  private ensureHolder(): HTMLDivElement {
    if (this.holder && this.holder.isConnected) return this.holder
    const holder = document.createElement('div')
    holder.setAttribute('data-everything-player', 'holder')
    Object.assign(holder.style, {
      position: 'fixed',
      right: '0',
      bottom: '0',
      width: '1px',
      height: '1px',
      overflow: 'hidden',
      opacity: '0',
      pointerEvents: 'none',
    })
    document.body.appendChild(holder)
    this.holder = holder
    return holder
  }

  park(element: HTMLVideoElement): void {
    if (element.parentElement !== this.ensureHolder()) {
      this.ensureHolder().appendChild(element)
    }
  }

  setActive(element: HTMLVideoElement | null): void {
    if (this.active === element) return
    const previous = this.active
    this.active = element
    if (previous) this.park(previous)
    this.layout()
  }

  register(container: HTMLElement, resizeMode: ResizeMode): SurfaceHandle {
    const surface: Surface = { container, resizeMode }
    this.surfaces.push(surface)
    this.layout()
    return {
      setResizeMode: (mode) => {
        surface.resizeMode = mode
        this.layout()
      },
      dispose: () => {
        this.surfaces = this.surfaces.filter((s) => s !== surface)
        surface.canvas?.remove()
        surface.canvas = undefined
        if (this.active && this.active.parentElement === container) {
          this.park(this.active)
        }
        this.layout()
      },
    }
  }

  private layout(): void {
    const primary = this.surfaces[this.surfaces.length - 1]
    const element = this.active
    for (const surface of this.surfaces) {
      if (surface === primary && element) {
        surface.canvas?.remove()
        surface.canvas = undefined
        if (element.parentElement !== surface.container) {
          surface.container.appendChild(element)
        }
        Object.assign(element.style, {
          position: 'absolute',
          left: '0',
          top: '0',
          width: '100%',
          height: '100%',
          objectFit: FIT[surface.resizeMode],
          background: 'black',
        })
        continue
      }
      if (!element) {
        surface.canvas?.remove()
        surface.canvas = undefined
        continue
      }
      if (!surface.canvas) {
        const canvas = document.createElement('canvas')
        Object.assign(canvas.style, {
          position: 'absolute',
          left: '0',
          top: '0',
          width: '100%',
          height: '100%',
        })
        surface.container.appendChild(canvas)
        surface.canvas = canvas
      }
      surface.canvas.style.objectFit = FIT[surface.resizeMode]
    }
    if (element && !primary) this.park(element)
    this.drawMirrors()
    this.scheduleFrames()
  }

  private drawMirrors(): void {
    const element = this.active
    if (!element || element.videoWidth === 0) return
    for (const surface of this.surfaces) {
      const canvas = surface.canvas
      if (!canvas) continue
      if (canvas.width !== element.videoWidth) canvas.width = element.videoWidth
      if (canvas.height !== element.videoHeight) canvas.height = element.videoHeight
      canvas.getContext('2d')?.drawImage(element, 0, 0, canvas.width, canvas.height)
    }
  }

  private scheduleFrames(): void {
    const element = this.active
    const needsMirrors = this.surfaces.some((s) => s.canvas)
    if (this.frameElement && (this.frameElement !== element || !needsMirrors)) {
      if (this.frameRequest !== undefined) {
        this.frameElement.cancelVideoFrameCallback?.(this.frameRequest)
      }
      this.frameElement = null
      this.frameRequest = undefined
    }
    if (!element || !needsMirrors || this.frameElement) return
    this.frameElement = element
    const tick = () => {
      if (this.frameElement !== element) return
      this.drawMirrors()
      this.frameRequest = element.requestVideoFrameCallback(tick)
    }
    this.frameRequest = element.requestVideoFrameCallback(tick)
  }
}

export const videoHub = new VideoHub()
