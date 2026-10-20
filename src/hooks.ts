import { useEffect, useRef, useState } from 'react'
import * as TrackPlayer from './TrackPlayer'
import * as DownloadManager from './DownloadManager'
import { State } from './types/enums'
import {
  DownloadEvent,
  Event,
  type Download,
  type EventPayloadByEvent,
} from './types/Event'
import type {
  PlaybackState,
  Progress,
  VideoQualities,
} from './types/Options'
import type { QueuedTrack } from './types/Track'

type AnyEventHandler = <E extends Event>(
  payload: EventPayloadByEvent[E] & { type: E }
) => void

export function useTrackPlayerEvents<E extends Event>(
  events: E[],
  handler: (payload: EventPayloadByEvent[E] & { type: E }) => void
): void {
  const handlerRef = useRef(handler)
  handlerRef.current = handler
  const key = events.join('|')
  useEffect(() => {
    const subs = events.map((type) =>
      TrackPlayer.addEventListener(type, (payload) =>
        (handlerRef.current as AnyEventHandler)({
          ...(payload as object),
          type,
        } as never)
      )
    )
    return () => subs.forEach((s) => s.remove())
  }, [key])
}

function safe<T>(fn: () => T, fallback: T): T {
  try {
    return TrackPlayer.isSetup() ? fn() : fallback
  } catch {
    return fallback
  }
}

export function usePlaybackState(): PlaybackState | { state: undefined } {
  const [state, setState] = useState<PlaybackState | { state: undefined }>(() =>
    safe<PlaybackState | { state: undefined }>(TrackPlayer.getPlaybackState, {
      state: undefined,
    })
  )
  useEffect(() => {
    const sub = TrackPlayer.addEventListener(Event.PlaybackState, setState)
    setState(
      safe<PlaybackState | { state: undefined }>(TrackPlayer.getPlaybackState, {
        state: undefined,
      })
    )
    return () => sub.remove()
  }, [])
  return state
}

export function useIsPlaying(): boolean | undefined {
  const { state } = usePlaybackState()
  if (state === undefined) return undefined
  return state === State.Playing
}

export function useProgress(updateInterval = 1000): Progress {
  const [progress, setProgress] = useState<Progress>({
    position: 0,
    duration: 0,
    buffered: 0,
  })
  useEffect(() => {
    let mounted = true
    const update = () => {
      const p = safe(TrackPlayer.getProgress, undefined)
      if (!mounted || !p) return
      setProgress((prev) =>
        prev.position === p.position &&
        prev.duration === p.duration &&
        prev.buffered === p.buffered
          ? prev
          : p
      )
    }
    update()
    const timer = setInterval(update, updateInterval)
    const sub = TrackPlayer.addEventListener(
      Event.PlaybackActiveTrackChanged,
      update
    )
    return () => {
      mounted = false
      clearInterval(timer)
      sub.remove()
    }
  }, [updateInterval])
  return progress
}

export function useActiveTrack(): QueuedTrack | undefined {
  const [track, setTrack] = useState<QueuedTrack | undefined>(() =>
    safe(TrackPlayer.getActiveTrack, undefined)
  )
  useEffect(() => {
    const sub = TrackPlayer.addEventListener(
      Event.PlaybackActiveTrackChanged,
      (e) => setTrack(e.track)
    )
    setTrack(safe(TrackPlayer.getActiveTrack, undefined))
    return () => sub.remove()
  }, [])
  return track
}

const NO_QUALITIES: VideoQualities = { qualities: [], auto: true }

export function useVideoQualities(): VideoQualities {
  const [qualities, setQualities] = useState<VideoQualities>(() =>
    safe(TrackPlayer.getVideoQualities, NO_QUALITIES)
  )
  useEffect(() => {
    const refresh = () =>
      setQualities(safe(TrackPlayer.getVideoQualities, NO_QUALITIES))
    const subs = [
      TrackPlayer.addEventListener(Event.PlaybackVideoQualityChanged, (e) =>
        setQualities({
          qualities: e.qualities,
          selected: e.selected,
          auto: e.auto,
        })
      ),
      TrackPlayer.addEventListener(Event.PlaybackActiveTrackChanged, refresh),
    ]
    refresh()
    return () => subs.forEach((s) => s.remove())
  }, [])
  return qualities
}

export function useDownload(trackId: string): Download | undefined {
  const [download, setDownload] = useState<Download | undefined>(() =>
    DownloadManager.getDownload(trackId)
  )
  useEffect(() => {
    setDownload(DownloadManager.getDownload(trackId))
    const sub = DownloadManager.addEventListener(
      DownloadEvent.DownloadChanged,
      (d) => {
        if (d.trackId === trackId) setDownload(d)
      }
    )
    return () => sub.remove()
  }, [trackId])
  return download
}
