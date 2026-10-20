import { Image } from 'react-native'
import { NitroModules } from 'react-native-nitro-modules'
import type { EverythingPlayer } from '../specs/EverythingPlayer.nitro'
import type { DownloadManager } from '../specs/DownloadManager.nitro'
import type { Platform } from './native'

export const nitroPlatform: Platform = {
  createPlayer: () =>
    NitroModules.createHybridObject<EverythingPlayer>('EverythingPlayer'),
  createDownloads: () =>
    NitroModules.createHybridObject<DownloadManager>('DownloadManager'),
  resolveArtwork: (artwork) => Image.resolveAssetSource(artwork)?.uri,
}
