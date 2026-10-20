# react-native-everything-player

A full-featured React Native media player built on [Nitro Modules](https://github.com/mrousavy/nitro). The public API mirrors `react-native-track-player` (RNTP) so migration is mostly an import change.

- **Audio-first**: audio-only by default; video can be enabled with a flag (see [Video](#video)).
- **Sources**: direct URLs, HLS, and YouTube SABR, auto-detected per track.
- **Native engines**: iOS (Swift, SABR via `swift-googlevideo`) and Android (Kotlin/ExoPlayer, SABR stubbed until `kotlin-googlevideo` is ready).
- **Electron**: the same TypeScript API backed by a renderer engine (MediaSource + Web Audio, SABR via vendored `googlevideo`, HLS via shaka-player). See [Electron](#electron).

---

# Interfaces

## StreamingInfo

How a track's media is located. A bare string is shorthand for a direct/HLS URL; the object form is used for SABR.

```ts
type StreamingInfo = string /* url */ | SabrStreamingInfo;

interface SabrStreamingInfo {
    videoId: string;
    serverAbrStreamingUrl: string;
    videoPlaybackUstreamerConfig: string;
    formats: SabrFormat[];            // all adaptive formats from the player response
    poToken: string;                  // cold-start placeholder; real token comes from onMintPoToken
    clientInfo: { clientName: number; clientVersion: string }; // clientName is the numeric client id
    cookie?: string;
    duration: number;                 // seconds
    callbacks: {
        /** Return fresh PoToken bytes. Called whenever the server rejects/expects a new token. */
        onMintPoToken: () => Promise<Uint8Array>;
        /** Called when the server requests a player reload (e.g. expired URL). */
        onReloadPlayerResponse: (playbackContext: ReloadPlaybackContext) => Promise<{
            videoPlaybackUstreamerConfig: string;
            serverAbrStreamingUrl: string;
        }>;
    };
}
```

### Source autodetection

The player picks an engine per track; callers never choose one explicitly.

| Condition | Engine |
| --- | --- |
| `streamingInfo` is an object with `serverAbrStreamingUrl` | SABR |
| String URL ending in `.m3u8`, or `contentType` is `application/vnd.apple.mpegurl` / `application/x-mpegURL` | HLS |
| Any other string URL | Raw (progressive) playback |

### SABR lifecycle

1. The app resolves a `SabrStreamingInfo` (player request, decipher URL, collect formats) and attaches it to the `Track`.
2. Native starts streaming with the **placeholder** `poToken` so playback begins without waiting on BotGuard.
3. `onMintPoToken` is called to obtain a real token; native swaps it in for subsequent requests.
4. If the server responds with a reload directive, native calls `onReloadPlayerResponse(playbackContext)` and continues with the returned `serverAbrStreamingUrl` and `videoPlaybackUstreamerConfig`.
5. If a callback rejects or times out, the track emits `PlaybackError` (code `sabr-callback-failed`) rather than retrying forever.

Callbacks are async JS functions invoked from native, possibly more than once and concurrently with playback. They must be idempotent.

### SABR sessions
The first response of every new SABR session carries a server backoff of about 4 s before any media is sent; requests later in the same session do not. To keep that cost to once per track:
- Seeks, including seeks after the track ended, reuse the live session (about 100–150 ms to audio).
- `sabrPoolAhead` upcoming SABR tracks get a session opened in advance: one handshake request, no media downloaded. Skipping to such a track adopts the session and starts in a few hundred ms. Pooled sessions are refreshed after 4 minutes.
- If a reused session fails before producing audio, playback retries once on a fresh session instead of erroring.
- Response bodies are parsed as they stream in, so audio starts before the full response has arrived.
- Changing the video quality still opens a new session for the new format; already-buffered audio keeps playing across it.

## Track

```ts
interface Track {
    id?: string;                       // generated if omitted
    title: string;
    artist: string;
    album?: string;
    artwork?: Artwork;
    duration?: number;                 // seconds
    startTime?: number;                // trim: begin playback here (seconds)
    endTime?: number;                  // trim: end playback here; crossfade respects this
    streamingInfo: StreamingInfo;
    userAgent?: string;
    contentType?: string;              // hint used by autodetection
    headers?: Record<string, string>;
    otherData?: Record<string, any>;   // opaque to the player, returned as-is
}
```

> Open question: the draft used snake_case (`streaming_info`, `user_agent`, ...). camelCase is used here to match RNTP; revert if you prefer the original.

## Enums

- `State`: `None | Ready | Playing | Paused | Stopped | Buffering | Loading | Error | Ended`
- `RepeatMode`: `Off | Track | Queue`
- `Capability`: `Play | Pause | Stop | SkipToNext | SkipToPrevious | SeekTo | JumpForward | JumpBackward | PlayFromSearch | ...`

---

# Functions

## Setup

| Function | Description |
| --- | --- |
| `isSetup() -> boolean` | Whether `setupPlayer` has completed. |
| `setupPlayer(options) -> Promise<void>` | Initialise the native engine. |
| `updateOptions(options) -> Promise<void>` | Update capabilities and behaviour at any time. |

`setupPlayer` options:
- `cacheConfig`: see [Caching](#caching-and-preloading)
- `enableVideo?: boolean` (default `false`): see [Video](#video)
- `videoQuality?: { minHeight?, maxHeight?, maxBitrate? }` (default `{ maxHeight: 720 }`): initial video quality range, see [Video quality](#video-quality)
- `sabrPoolAhead?: number` (default `1`): how many upcoming SABR tracks get a pre-opened session, see [SABR sessions](#sabr-sessions). `<= 0` keeps only the current track's session.

`updateOptions` options:
- `capabilities: Capability[]`, e.g. `Play, Pause, SkipToNext, SkipToPrevious, SeekTo, PlayFromSearch, ...`
- `progressUpdateEventInterval: number` (seconds; `0` disables)

## Playback options

| Function | Description |
| --- | --- |
| `setRepeatMode(mode: RepeatMode)` | `Off`, `Track`, or `Queue`. |
| `setEqualizer(bands: number[])` | Gain in dB per band; see [Equalizer](#equalizer). |
| `setCrossFade(seconds: number)` | `0` disables. See [Crossfade](#crossfade-and-trimming). |
| `getVideoQualities() -> { qualities, selected?, auto }` | Video qualities of the active track. |
| `setVideoQuality(id?: string)` | Pin a quality by `id`; `undefined` returns to automatic selection within the range. |
| `setVideoQualityRange(range)` / `getVideoQualityRange()` | Bounds used for automatic selection, new tracks and downloads. |

## Queue

| Function | Description |
| --- | --- |
| `addTrack(track)` / `addTracks(tracks)` | Append to the queue. |
| `removeTrack(index)` | Remove a track. |
| `getQueue() -> Track[]` | Current queue. |
| `getActiveTrackIndex() -> number \| undefined` | Index of the active track. |

## Transport

`play()`, `pause()`, `seekTo(seconds)`, `skipToNext()`, `skipToPrevious()`

## State

| Function | Description |
| --- | --- |
| `getProgress() -> { position, duration, buffered }` | All values in seconds. |
| `getPlaybackState() -> State` | Current state. |

## Events

`addEventListener(event, callback)` returns a subscription with `.remove()`.

Remote events: `RemoteDuck`, `RemotePrevious`, `RemoteNext`, `RemotePause`, `RemotePlay`, `RemoteSeek`.
Player events: `PlaybackState`, `PlaybackActiveTrackChanged`, `PlaybackProgressUpdated`, `PlaybackError`, `PlaybackQueueEnded`, `PlaybackVideoQualityChanged`.

---

# Features

## SABR playback
Uses [`swift-googlevideo`](#swift-googlevideo) on iOS. See [SABR lifecycle](#sabr-lifecycle) for the callback contract.

## Video
Audio only by default. Setting `enableVideo: true` in `setupPlayer` allows video formats to be selected and exposes a `VideoSurface` component to render them.

```tsx
<VideoSurface style={{ width: '100%', aspectRatio: 16 / 9 }} />
```

With `enableVideo: false` the player never selects or downloads video formats (SABR) and ignores video tracks (HLS).

### Shared buffer
When video is enabled, every `VideoSurface` that is created renders from a **shared buffer** of the active stream rather than opening its own connection or decoder:
- The player decodes the stream once; surfaces are consumers of that single buffer.
- Mounting more surfaces (e.g. mini-player plus full-screen player) costs no extra network or decode work, and all stay in sync with the audio clock.
- A surface mounted mid-track shows the current frame immediately, and unmounting one never interrupts playback or affects other surfaces.
- On track change the buffer is swapped; surfaces follow the active track automatically.

### Video quality
`setupPlayer({ videoQuality })` sets the initial range. Automatic selection picks the best quality inside it; `useVideoQualities()` / `getVideoQualities()` list what the active track offers and `setVideoQuality(id)` pins one.

| Source | Qualities | Switching |
| --- | --- | --- |
| SABR (iOS) | H.264 formats (`id` is the itag) | Restarts only the stream behind the playhead; already-buffered audio keeps playing, video resumes at the new format. |
| HLS (iOS) | H.264/AAC variants | Automatic mode adapts per segment to measured bandwidth inside the range; a pinned variant switches immediately without interrupting audio. |
| Raw / Android | ExoPlayer video tracks (Android); range caps only (iOS raw) | ExoPlayer track selection. |

Open questions: how the buffer is shared natively (iOS: a single `AVPlayerItemVideoOutput` / `CVPixelBuffer` feed fanned out to each surface's layer; Android: one ExoPlayer video output with surfaces attached/detached), and whether frames are dropped for hidden surfaces.

## Seeking
`seekTo(seconds)` clamps to `[0, duration]` and behaves per source type. Reference: `RNTPvE/SwiftAudioEx` `AVPlayerWrapper.seek(to:)` and `SabrOpusPlayer.seek(to:)`.

| Source | Behavior |
| --- | --- |
| Raw / HLS | Native seek with zero tolerance. A seek requested before the item exists is stored and applied once loading finishes. |
| SABR | Seek inside the live session: abort the in-flight request, drop buffered segments, and send the next request with `player_time_ms = target`. Adjusting the displayed clock alone is not enough, because the server keeps sending from where it left off. A new session is only opened when the current one has failed. |
| Cached file (SABR download) | Restart the decode pipeline at the target offset without re-fetching. |

Rules carried over from the reference implementation:
- **Freeze position at the target.** While a seek reloads (state `Loading`), `getProgress().position` reports the target, not `0`. Otherwise the scrubber snaps back, and a concurrent `seekBy` would compound off the wrong position.
- **Generation counter.** Each pipeline restart increments a generation id. Callbacks from a cancelled pipeline (end-of-stream, errors) check it and exit silently, so a stale pipeline can't trigger "finished" or "failed" for the new one.
- **Keep the audio engine running** across a seek and reuse it if the PCM format matches; only the decode pipeline restarts.
- **Clamp using the best known duration:** the `Track.duration` passed in, else the stream's duration, else the target itself.
- **`seekBy(offset)`** is `seekTo(position + offset)` for SABR, using the frozen position if a seek is in flight.
- `seekTo` emits `PlaybackProgressUpdated` with the target immediately, and `Buffering`/`Loading` is exposed until audio resumes.
- Seeking beyond `endTime` (see trimming) clamps to `endTime`.

### Never buffer whole streams
**Hard rule:** the player must never download or buffer an entire stream before (or as a precondition for) playback, as a way of avoiding seek handling. Playback starts as soon as the first playable data arrives, and every seek is handled by restarting the source at the target position (see the table above).
- Buffering is a small rolling window ahead of the playhead, bounded by time and bytes.
- A seek never waits on data that hasn't been requested: it re-requests from the target and drops the old window.
- Sources that can't serve random access (SABR) are not "made seekable" by accumulating everything in memory; they are restarted at `startTimeMs`.
- Full downloads only happen through the explicit `DownloadManager` path, never as a side effect of playing.
- Note: `lib-origin/tools/youtube_audio_stream.ts` keeps every chunk of a track in memory to serve Range requests. That is acceptable for a desktop tool but must not be copied for the Android SABR path.

## Caching and preloading
`cacheConfig` (proposed fields, to be finalised):
- `maxSizeMB: number`
- `maxAgeSeconds: number`
- `preloadNext: number`: how many upcoming tracks to preload
- `persistent: boolean`: disk cache (iOS `URLCache`, Android `SimpleCache`) vs. memory only

## Crossfade and trimming
- `startTime` / `endTime` on a `Track` trim playback.
- Crossfade begins at `endTime - crossFade` (or the track's end if no `endTime`).
- Crossfade is skipped for tracks shorter than twice the fade length, for `RepeatMode.Track`, and cancelled by a manual skip.

## Equalizer
`setEqualizer(bands)` takes 10 gains in dB (−12…+12) for 31, 62, 125, 250, 500, 1k, 2k, 4k, 8k, 16k Hz.
- iOS: SABR and HLS (including downloaded HLS) render through a shared `AVAudioEngine` graph with `AVAudioUnitEQ`; HLS is demuxed and decoded in-process (TS/fMP4, AAC/HE-AAC, AES-128) because AVPlayer cannot tap HLS audio. Raw URLs use an `MTAudioProcessingTap`. HLS streams the engine cannot decode (FairPlay/SAMPLE-AES, HEVC-only, AC-3) fall back to AVPlayer without EQ.
- Android: `android.media.audiofx.Equalizer` on each ExoPlayer audio session, with the 10 bands interpolated onto the device's bands.

## Downloads
`DownloadManager.download(track, { includeVideo?, videoQuality? })`. SABR downloads store audio and video as separate files (`audioPath`, `videoPath`); HLS downloads store the chosen rendition's segments with a local playlist (`localPath`), so offline playback uses the same engine (and EQ) as streaming.

## Background audio
iOS: `AVAudioSession` category `.playback`. Android: `MediaSessionService` as a foreground service.

---

# Platforms

## iOS
Swift engine based on the SwiftAudioEx fork used in RNTPvE (queue, crossfade, equalizer, now-playing, remote commands). SABR is provided by `swift-googlevideo`.

## Android
Write out the Android track player (ExoPlayer, `MediaSessionService`) completely, but **stub out a `kotlin-googlevideo`** module until it is ready:
- Define the same interface the iOS SABR layer exposes (start stream, selected formats, byte/segment output, callbacks).
- The stub rejects SABR tracks with `PlaybackError` (code `sabr-unsupported`); direct and HLS playback work normally.
- Open question: when implemented, expose SABR to ExoPlayer via a custom `DataSource` or a loopback HTTP server with Range support (as in `lib-origin/tools/youtube_audio_stream.ts`, but without its keep-everything-in-memory buffer; see [Never buffer whole streams](#never-buffer-whole-streams)).

---

## Electron
The package resolves to an Electron/DOM build under the `electron` and `browser` export conditions (Vite and webpack renderer builds pick it automatically), so the import and every type stay the same:

```ts
import TrackPlayer, { DownloadManager, VideoSurface } from 'react-native-everything-player'
// or explicitly: 'react-native-everything-player/electron'
```

Main process (call before `app` is ready so the file scheme is registered as privileged):

```ts
import { setupEverythingPlayer } from 'react-native-everything-player/electron/main'

setupEverythingPlayer({ downloadsDir?, session?, webRequest? })
```

Preload, only needed when `contextIsolation` is on (renderers with `nodeIntegration` reach the main process directly):

```ts
import { exposeEverythingPlayer } from 'react-native-everything-player/electron/preload'

exposeEverythingPlayer()
```

The main helper provides:
- File storage for downloads under `userData/EverythingPlayer/downloads`, sandboxed to that directory.
- The `everything-player-file://` scheme with Range support, so downloaded media plays with `webSecurity` on and still runs through the equalizer.
- Per-URL request headers (`headers`, `userAgent`, SABR `cookie`) and CORS response headers through `session.webRequest`. Renderer `fetch` cannot set `User-Agent`, `Cookie`, `Origin` or `Referer` itself. If the app already uses `onBeforeSendHeaders` / `onHeadersReceived` / `onBeforeRedirect`, pass `webRequest: false` and call the exported `applyRequestHeaders`, `applyResponseHeaders` and `applyRedirect` from your own listeners.

Without the main helper, playback still works for sources that need neither custom headers nor CORS. Downloads then use Node `fs` directly if `nodeIntegration` is on, and are unavailable otherwise.

| Source | Electron engine |
| --- | --- |
| SABR | Vendored [`googlevideo`](https://github.com/LuanRT/googlevideo) (`src/electron/vendor/googlevideo`, commit in `COMMIT`) streaming into MediaSource. Opus/WebM audio is preferred; video picks avc1, then vp9, then av1 per height, limited to what `MediaSource.isTypeSupported` accepts. Same session model as iOS: in-session seeks, the `sabrPoolAhead` warm pool, one retry on a fresh session, and quality switches that keep buffered audio. |
| HLS | shaka-player (AES-128, ABR inside the quality range, pinned variants, live). |
| Raw | The media element directly. |
| Downloads | Raw files resume with Range requests. HLS downloads are decrypted segments plus a local playlist, played offline through shaka. SABR downloads are separate audio and video files plus a segment index, so offline seeks read only the needed bytes. |

The patches on top of upstream `googlevideo` mirror the iOS port: `SabrStream.seek()` (in-session seek that swaps output streams and re-sends init segments), `warm()`/parking for the warm pool, parking at end of stream instead of closing the session, backoff measured from when the policy arrived, and a `segment` event used to build download indexes. Adapter-only modules (`SabrStreamingAdapter`, `SabrUmpProcessor`, cache and request managers) are removed.

Every source goes through one Web Audio graph: a per-track gain for volume and crossfade, then the 10-band peaking EQ. `VideoSurface` renders a `div`. The most recently mounted surface hosts the playing `<video>`; other surfaces mirror its frames onto a canvas, and unmounting a surface never interrupts playback. Remote commands and now-playing info use the Media Session API (media keys, macOS Now Playing, Windows SMTC, MPRIS), limited to the `capabilities` that map onto it (play/pause, stop, next/previous, seek, jump). `RemoteDuck`, like, dislike and bookmark are never emitted. `cacheConfig.preloadNext` prefetches upcoming raw tracks. The other `cacheConfig` fields are left to Chromium's HTTP cache.

---

# Migrating from RNTP
API names follow RNTP (`setupPlayer`, `updateOptions`, `addEventListener`). Differences: `streamingInfo` replaces `url` (a bare string still works), plus trimming, crossfade and SABR.
