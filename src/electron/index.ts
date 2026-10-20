import { installPlatform } from '../internal/native'
import TrackPlayer from '../TrackPlayer'
import { electronPlatform } from './platform'

installPlatform(electronPlatform)

export default TrackPlayer
export * from '../TrackPlayer'
export { default as DownloadManager } from '../DownloadManager'
export { VideoSurface } from './VideoSurface'
export type { VideoSurfaceProps, ResizeMode } from './VideoSurface'
export * from '../hooks'
export * from '../types/enums'
export * from '../types/Event'
export * from '../types/Options'
export * from '../types/Track'
