import React, { useLayoutEffect, useRef } from 'react'
import { videoHub, type SurfaceHandle } from './engine/VideoHub'
import type { VideoSurfaceProps } from '../types/VideoSurface'

export type { ResizeMode, VideoSurfaceProps } from '../types/VideoSurface'

function flatten(style: unknown): Record<string, unknown> {
  if (!style) return {}
  if (Array.isArray(style)) return Object.assign({}, ...style.map(flatten))
  return typeof style === 'object' ? (style as Record<string, unknown>) : {}
}

export function VideoSurface({ style, resizeMode = 'contain' }: VideoSurfaceProps) {
  const ref = useRef<HTMLDivElement>(null)
  const handle = useRef<SurfaceHandle | undefined>(undefined)

  useLayoutEffect(() => {
    const container = ref.current
    if (!container) return undefined
    const surface = videoHub.register(container, resizeMode)
    handle.current = surface
    return () => {
      handle.current = undefined
      surface.dispose()
    }
  }, [])

  useLayoutEffect(() => {
    handle.current?.setResizeMode(resizeMode)
  }, [resizeMode])

  return (
    <div
      ref={ref}
      style={{
        position: 'relative',
        overflow: 'hidden',
        display: 'flex',
        flexDirection: 'column',
        background: 'black',
        ...(flatten(style) as React.CSSProperties),
      }}
    />
  )
}
