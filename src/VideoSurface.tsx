import React from 'react'
import { getHostComponent } from 'react-native-nitro-modules'
import VideoSurfaceConfig from '../nitrogen/generated/shared/json/VideoSurfaceConfig.json'
import type {
  VideoSurfaceMethods,
  VideoSurfaceProps as NativeVideoSurfaceProps,
} from './specs/VideoSurface.nitro'
import type { VideoSurfaceProps } from './types/VideoSurface'

export type { ResizeMode, VideoSurfaceProps } from './types/VideoSurface'

const NativeVideoSurface = getHostComponent<
  NativeVideoSurfaceProps,
  VideoSurfaceMethods
>('VideoSurface', () => VideoSurfaceConfig)

export function VideoSurface({
  style,
  resizeMode = 'contain',
}: VideoSurfaceProps) {
  return <NativeVideoSurface style={style} resizeMode={resizeMode} />
}
