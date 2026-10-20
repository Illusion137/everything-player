import type {
  HybridView,
  HybridViewMethods,
  HybridViewProps,
} from 'react-native-nitro-modules'

export type NativeResizeMode = 'contain' | 'cover' | 'stretch'

export interface VideoSurfaceProps extends HybridViewProps {
  resizeMode?: NativeResizeMode
}

export interface VideoSurfaceMethods extends HybridViewMethods {}

export type VideoSurface = HybridView<VideoSurfaceProps, VideoSurfaceMethods>
