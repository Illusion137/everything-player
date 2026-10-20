import type { Platform } from '../internal/native'
import { downloadsEngine } from './engine/ElectronDownloads'
import { ElectronPlayer, setLocalMediaResolver } from './engine/ElectronPlayer'

function artworkUri(artwork: unknown): string | undefined {
  if (typeof artwork === 'string') return artwork
  if (artwork && typeof artwork === 'object') {
    const { uri, default: def } = artwork as { uri?: unknown; default?: unknown }
    if (typeof uri === 'string') return uri
    if (typeof def === 'string') return def
  }
  return undefined
}

export const electronPlatform: Platform = {
  createPlayer: () => {
    const downloads = downloadsEngine()
    setLocalMediaResolver((track) => downloads.localMedia(track))
    return new ElectronPlayer(downloads.ready)
  },
  createDownloads: () => downloadsEngine(),
  resolveArtwork: artworkUri,
}
