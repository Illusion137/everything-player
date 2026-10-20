import type { HybridObject } from 'react-native-nitro-modules'
import type { EverythingPlayer } from '../specs/EverythingPlayer.nitro'
import type { DownloadManager } from '../specs/DownloadManager.nitro'
import type { Artwork } from '../types/Track'

type HybridKeys = keyof HybridObject<{ ios: 'swift'; android: 'kotlin' }>

export type PlayerBackend = Omit<EverythingPlayer, HybridKeys>
export type DownloadBackend = Omit<DownloadManager, HybridKeys>

export interface Platform {
  createPlayer(): PlayerBackend
  createDownloads(): DownloadBackend
  resolveArtwork(artwork: Exclude<Artwork, string>): string | undefined
}

let platform: Platform | undefined
let player: PlayerBackend | undefined
let downloads: DownloadBackend | undefined

export function installPlatform(next: Platform): void {
  platform = next
}

function current(): Platform {
  if (!platform) {
    throw new Error('[react-native-everything-player] no platform installed')
  }
  return platform
}

export function nativePlayer(): PlayerBackend {
  player ??= current().createPlayer()
  return player
}

export function nativeDownloads(): DownloadBackend {
  downloads ??= current().createDownloads()
  return downloads
}

export function resolveArtworkSource(
  artwork: Exclude<Artwork, string>
): string | undefined {
  return current().resolveArtwork(artwork)
}
