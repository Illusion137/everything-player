import { YouTubeDL } from '@origin/youtube/youtube_dl'
import type { SabrFormat, Track } from 'react-native-everything-player'

export interface TrackStub {
  videoId: string
  title: string
  artist: string
}

export const QUEUE: TrackStub[] = [
  { videoId: 'xg07s07I6P8', title: 'Track One', artist: 'SABR Example' },
  { videoId: 'sRrE6b4ZJns', title: 'Track Two', artist: 'SABR Example' },
]

function withoutNulls<T extends object>(value: T): T {
  return Object.fromEntries(
    Object.entries(value).filter(([, v]) => v !== null)
  ) as T
}

export async function resolveSabrTrack(stub: TrackStub): Promise<Track> {
  const info = await YouTubeDL.resolve_sabr_info(stub.videoId)
  if ('error' in info) throw info.error

  const reload = info.callbacks?.onReloadPlayerResponse
  if (!reload) throw new Error(`No reload callback for ${stub.videoId}`)

  return {
    id: stub.videoId,
    title: stub.title,
    artist: stub.artist,
    artwork: `https://i.ytimg.com/vi/${stub.videoId}/hqdefault.jpg`,
    duration: info.duration,
    streamingInfo: {
      videoId: info.videoId,
      serverAbrStreamingUrl: info.serverAbrStreamingUrl,
      videoPlaybackUstreamerConfig: info.videoPlaybackUstreamerConfig,
      formats: info.formats.map((f) => withoutNulls(f as SabrFormat)),
      poToken: info.poToken ?? '',
      clientInfo: {
        clientName: info.clientInfo.clientName ?? 1,
        clientVersion: info.clientInfo.clientVersion ?? '',
      },
      cookie: info.cookie,
      duration: info.duration,
      callbacks: {
        onMintPoToken: async () => {
          const bytes = await YouTubeDL.fetch_potoken_bytes(stub.videoId)
          if (bytes.length === 0) throw new Error(`PoToken mint failed for ${stub.videoId}`)
          return bytes
        },
        onReloadPlayerResponse: async (context) => {
          const next = await reload(context as Parameters<typeof reload>[0])
          return {
            serverAbrStreamingUrl: next.serverAbrStreamingUrl,
            videoPlaybackUstreamerConfig: next.videoPlaybackUstreamerConfig,
          }
        },
      },
    },
  }
}
