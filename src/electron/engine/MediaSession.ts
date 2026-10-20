import type {
  NativeCapability,
  NativeRemoteEvent,
  NativeTrack,
} from '../../specs/EverythingPlayer.nitro'

type Action = MediaSessionAction

const ACTIONS: Action[] = [
  'play',
  'pause',
  'stop',
  'nexttrack',
  'previoustrack',
  'seekto',
  'seekforward',
  'seekbackward',
]

function session(): MediaSession | undefined {
  return typeof navigator !== 'undefined' && 'mediaSession' in navigator
    ? navigator.mediaSession
    : undefined
}

export class MediaSessionBridge {
  handler: ((event: NativeRemoteEvent) => void) | undefined
  isPlaying: () => boolean = () => false

  configure(
    capabilities: NativeCapability[],
    forwardInterval: number,
    backwardInterval: number
  ): void {
    const ms = session()
    if (!ms) return
    const caps = new Set(capabilities)
    const emit = (event: NativeRemoteEvent) => this.handler?.(event)
    const bindings: Record<string, [NativeCapability | NativeCapability[], MediaSessionActionHandler]> = {
      play: [['play', 'pause'], () => emit({ type: this.isPlaying() ? 'remote-pause' : 'remote-play' })],
      pause: [['play', 'pause'], () => emit({ type: this.isPlaying() ? 'remote-pause' : 'remote-play' })],
      stop: ['stop', () => emit({ type: 'remote-stop' })],
      nexttrack: ['skip-to-next', () => emit({ type: 'remote-next' })],
      previoustrack: ['skip-to-previous', () => emit({ type: 'remote-previous' })],
      seekto: [
        'seek-to',
        (d) => {
          if (d.seekTime !== undefined && d.seekTime !== null) {
            emit({ type: 'remote-seek', position: d.seekTime })
          }
        },
      ],
      seekforward: [
        'jump-forward',
        (d) => emit({ type: 'remote-jump-forward', interval: d.seekOffset ?? forwardInterval }),
      ],
      seekbackward: [
        'jump-backward',
        (d) => emit({ type: 'remote-jump-backward', interval: d.seekOffset ?? backwardInterval }),
      ],
    }
    for (const action of ACTIONS) {
      const binding = bindings[action]
      if (!binding) continue
      const [cap, handler] = binding
      const enabled = Array.isArray(cap) ? cap.some((c) => caps.has(c)) : caps.has(cap)
      try {
        ms.setActionHandler(action, enabled ? handler : null)
      } catch {}
    }
  }

  setTrack(track: NativeTrack | undefined): void {
    const ms = session()
    if (!ms) return
    if (!track) {
      ms.metadata = null
      ms.playbackState = 'none'
      return
    }
    try {
      ms.metadata = new MediaMetadata({
        title: track.title,
        artist: track.artist,
        album: track.album ?? '',
        artwork: track.artwork ? [{ src: track.artwork }] : [],
      })
    } catch {}
  }

  update(position: number, duration: number | undefined, rate: number, playing: boolean): void {
    const ms = session()
    if (!ms || !ms.metadata) return
    ms.playbackState = playing ? 'playing' : 'paused'
    if (duration === undefined || !(duration > 0)) return
    try {
      ms.setPositionState({
        duration,
        playbackRate: rate > 0 ? rate : 1,
        position: Math.min(Math.max(0, position), duration),
      })
    } catch {}
  }
}
