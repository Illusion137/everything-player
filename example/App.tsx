import { useState } from 'react'
import {
  ActivityIndicator,
  Image,
  Pressable,
  SafeAreaView,
  StyleSheet,
  Switch,
  Text,
  View,
} from 'react-native'
import Slider from '@react-native-community/slider'
import { StatusBar } from 'expo-status-bar'
import TrackPlayer, {
  Capability,
  Event,
  State,
  VideoSurface,
  useActiveTrack,
  usePlaybackState,
  useProgress,
  useTrackPlayerEvents,
} from 'react-native-everything-player'
import { QUEUE, resolveSabrTrack } from './src/sabr'

type Phase = 'idle' | 'starting' | 'ready'

function formatTime(seconds: number) {
  const s = Math.max(0, Math.floor(seconds))
  return `${Math.floor(s / 60)}:${String(s % 60).padStart(2, '0')}`
}

export default function App() {
  const [phase, setPhase] = useState<Phase>('idle')
  const [enableVideo, setEnableVideo] = useState(false)
  const [status, setStatus] = useState('')
  const [error, setError] = useState<string>()
  const [scrubbing, setScrubbing] = useState<number>()

  const playback = usePlaybackState()
  const progress = useProgress(250)
  const track = useActiveTrack()

  useTrackPlayerEvents([Event.PlaybackError], (e) => {
    setError(`${e.code}: ${e.message}`)
  })

  const start = async () => {
    setPhase('starting')
    setError(undefined)
    try {
      setStatus('Setting up player…')
      await TrackPlayer.setupPlayer({ enableVideo, sabrPoolAhead: 0})
      await TrackPlayer.updateOptions({
        capabilities: [
          Capability.Play,
          Capability.Pause,
          Capability.SkipToNext,
          Capability.SkipToPrevious,
          Capability.SeekTo,
        ],
        progressUpdateEventInterval: 1,
      })
      setStatus('Resolving SABR streams…')
      const tracks = await Promise.all(QUEUE.map(resolveSabrTrack))
      TrackPlayer.setQueue(tracks)
      TrackPlayer.play()
      setPhase('ready')
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e))
      setPhase('idle')
    } finally {
      setStatus('')
    }
  }

  const ready = phase === 'ready'
  const isPlaying = playback.state === State.Playing
  const isBusy =
    playback.state === State.Loading || playback.state === State.Buffering
  const duration = progress.duration || track?.duration || 0
  const position = scrubbing ?? progress.position

  return (
    <SafeAreaView style={styles.root}>
      <StatusBar style="light" />
      <View style={styles.container}>
        <Text style={styles.heading}>Everything Player · SABR</Text>

        <Pressable
          style={[styles.startButton, phase !== 'idle' && styles.disabled]}
          disabled={phase !== 'idle'}
          onPress={start}
        >
          {phase === 'starting' ? (
            <ActivityIndicator color="#0b0b0f" />
          ) : (
            <Text style={styles.startText}>
              {ready ? 'Running' : 'Start'}
            </Text>
          )}
        </Pressable>

        <View style={styles.row}>
          <Text style={styles.label}>Video</Text>
          <Switch
            value={enableVideo}
            onValueChange={setEnableVideo}
            disabled={phase !== 'idle'}
          />
        </View>
        {phase !== 'idle' && (
          <Text style={styles.hint}>
            Video mode is fixed once the player is set up.
          </Text>
        )}

        {!!status && <Text style={styles.status}>{status}</Text>}
        {!!error && <Text style={styles.error}>{error}</Text>}

        {ready && (
          <View style={styles.player}>
            {enableVideo ? (
              <VideoSurface style={styles.media} />
            ) : (
              typeof track?.artwork === 'string' && (
                <Image source={{ uri: track.artwork }} style={styles.media} />
              )
            )}

            <Text style={styles.title}>{track?.title ?? '—'}</Text>
            <Text style={styles.artist}>
              {track?.artist ?? ''} · {track?.id ?? ''}
            </Text>

            <Slider
              style={styles.slider}
              minimumValue={0}
              maximumValue={Math.max(duration, 1)}
              value={position}
              minimumTrackTintColor="#f5f5f7"
              maximumTrackTintColor="#3a3a44"
              thumbTintColor="#f5f5f7"
              onSlidingStart={setScrubbing}
              onValueChange={(v) => scrubbing !== undefined && setScrubbing(v)}
              onSlidingComplete={(v) => {
                TrackPlayer.seekTo(v)
                setScrubbing(undefined)
              }}
            />
            <View style={styles.times}>
              <Text style={styles.time}>{formatTime(position)}</Text>
              <Text style={styles.time}>
                {isBusy ? playback.state : formatTime(duration)}
              </Text>
            </View>

            <View style={styles.transport}>
              <Pressable
                style={styles.transportButton}
                onPress={() => TrackPlayer.skipToPrevious()}
              >
                <Text style={styles.transportText}>Prev</Text>
              </Pressable>
              <Pressable
                style={[styles.transportButton, styles.playButton]}
                onPress={() =>
                  isPlaying ? TrackPlayer.pause() : TrackPlayer.play()
                }
              >
                <Text style={[styles.transportText, styles.playText]}>
                  {isPlaying ? 'Pause' : 'Play'}
                </Text>
              </Pressable>
              <Pressable
                style={styles.transportButton}
                onPress={() => TrackPlayer.skipToNext()}
              >
                <Text style={styles.transportText}>Next</Text>
              </Pressable>
            </View>
          </View>
        )}
      </View>
    </SafeAreaView>
  )
}

const styles = StyleSheet.create({
  root: { flex: 1, backgroundColor: '#0b0b0f' },
  container: { flex: 1, padding: 20, gap: 12 },
  heading: { color: '#f5f5f7', fontSize: 22, fontWeight: '700' },
  startButton: {
    backgroundColor: '#f5f5f7',
    borderRadius: 12,
    height: 52,
    alignItems: 'center',
    justifyContent: 'center',
  },
  startText: { color: '#0b0b0f', fontSize: 17, fontWeight: '700' },
  disabled: { opacity: 0.5 },
  row: {
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'space-between',
    paddingVertical: 4,
  },
  label: { color: '#f5f5f7', fontSize: 16 },
  hint: { color: '#8a8a96', fontSize: 12 },
  status: { color: '#8a8a96' },
  error: { color: '#ff6b6b' },
  player: { marginTop: 8, gap: 8 },
  media: {
    width: '100%',
    aspectRatio: 16 / 9,
    borderRadius: 12,
    backgroundColor: '#000',
  },
  title: { color: '#f5f5f7', fontSize: 18, fontWeight: '600', marginTop: 8 },
  artist: { color: '#8a8a96' },
  slider: { width: '100%', height: 40 },
  times: { flexDirection: 'row', justifyContent: 'space-between' },
  time: { color: '#8a8a96', fontVariant: ['tabular-nums'] },
  transport: {
    flexDirection: 'row',
    justifyContent: 'center',
    alignItems: 'center',
    gap: 16,
    marginTop: 8,
  },
  transportButton: {
    borderWidth: 1,
    borderColor: '#3a3a44',
    borderRadius: 999,
    paddingHorizontal: 20,
    paddingVertical: 12,
  },
  transportText: { color: '#f5f5f7', fontSize: 16, fontWeight: '600' },
  playButton: { backgroundColor: '#f5f5f7', borderColor: '#f5f5f7' },
  playText: { color: '#0b0b0f' },
})
