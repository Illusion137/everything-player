package com.margelo.nitro.everythingplayer.engine

import android.content.Context
import androidx.annotation.OptIn
import androidx.media3.common.C
import androidx.media3.common.PlaybackException
import androidx.media3.common.util.UnstableApi
import androidx.media3.exoplayer.source.ClippingMediaSource
import androidx.media3.exoplayer.source.MediaSource
import androidx.media3.exoplayer.source.MergingMediaSource
import com.margelo.nitro.everythingplayer.googlevideo.types.StreamStartResult
import com.margelo.nitro.everythingplayer.googlevideo.utils.MediaType
import com.margelo.nitro.everythingplayer.googlevideo.utils.u8ToBase64

@OptIn(UnstableApi::class)
class EPSabrPipeline(
  context: Context,
  track: EPTrack,
  sabr: EPSabrInfo,
  options: EPSetupOptions,
  private val callbacks: EPSabrCallbackProvider?,
  private val local: EPLocalSabrMedia?,
  private val warmPool: EPSabrWarmPool?,
  initialRange: EPVideoQualityRange,
) : EPExoPipeline(context, track, options, false, initialRange), EPSabrSessionOwner {
  private val lock = Any()
  private var info = sabr
  private var poToken = sabr.poToken
  private var session: EPSabrSession? = null
  private var hub: EPSabrMediaHub? = null
  @Volatile private var generation = 0
  private var qualityRange = initialRange
  private var manualItag: Int? = null
  private var activeVideoItag: Int? = null
  private var reusedSession = false
  @Volatile private var callbackError: EPError? = null
  private val wantsVideo = options.enableVideo &&
    (if (local != null) local.videoFile != null else EPSabr.pickVideo(sabr.formats, initialRange) != null)

  private fun durationUs(): Long {
    val seconds = info.duration.takeIf { it > 0 } ?: track.duration
    if (seconds != null && seconds > 0) return (seconds * 1_000_000).toLong()
    val approx = EPSabr.pickAudio(info.formats)?.approxDurationMs ?: 0
    return if (approx > 0) approx * 1000 else C.TIME_UNSET
  }

  private fun clipped(source: MediaSource): MediaSource {
    val end = track.endTime ?: return source
    return ClippingMediaSource.Builder(source).setEndPositionUs((end * 1_000_000).toLong()).build()
  }

  override fun mediaSource(position: Double): MediaSource {
    val durationUs = durationUs()
    if (local != null) {
      val audio = EPSabrMedia.fileSource(local.audioFile, local.audioIsOpus, durationUs)
      val video = local.videoFile?.takeIf { wantsVideo }?.let { EPSabrMedia.fileSource(it, false, durationUs) }
      return clipped(if (video != null) MergingMediaSource(audio, video) else audio)
    }

    val audioFormat = EPSabr.pickAudio(info.formats)
      ?: throw EPError(EPErrorCode.SABR_STREAM_FAILED, "No playable audio format (opus/aac) in SABR formats")
    val videoFormat = if (wantsVideo) synchronized(lock) { selectedVideoFormatLocked() } else null

    tearDownSession()
    callbackError = null
    val gen = ++generation
    val (result, reused) = try {
      openSession(audioFormat.itag, videoFormat?.itag, position)
    } catch (e: Throwable) {
      throw EPError.from(e, EPErrorCode.SABR_STREAM_FAILED)
    }
    val active = session ?: throw EPError(EPErrorCode.SABR_STREAM_FAILED, "SABR session unavailable")
    synchronized(lock) {
      activeVideoItag = videoFormat?.itag
      reusedSession = reused
    }

    val mediaHub = EPSabrMediaHub({ active.stream.seek(toMs = it) }, result, (position * 1000).toLong(), gen)
    hub = mediaHub
    val audio = EPSabrMedia.streamSource(mediaHub, MediaType.AUDIO, EPSabr.isOpus(audioFormat), durationUs)
    val video = videoFormat?.let { EPSabrMedia.streamSource(mediaHub, MediaType.VIDEO, (it.mimeType ?: "").contains("webm"), durationUs) }
    return clipped(if (video != null) MergingMediaSource(audio, video) else audio)
  }

  private fun openSession(audioItag: Int, videoItag: Int?, position: Double): Pair<StreamStartResult, Boolean> {
    warmPool?.take(track.id, audioItag, videoItag)?.let { warm ->
      warm.owner = this
      session = warm
      warm.stream.seek(toMs = (position * 1000).toLong())?.let { return it to true }
      warm.owner = null
      warm.abort()
    }
    val (current, token) = synchronized(lock) { info to poToken }
    val fresh = EPSabrSession(track, current, token, options, callbacks, audioItag, videoItag)
    fresh.owner = this
    session = fresh
    return fresh.start(position) to false
  }

  private fun tearDownSession() {
    session?.owner = null
    session?.abort()
    session = null
    hub = null
  }

  private fun selectedVideoFormatLocked(): EPSabrFormat? {
    manualItag?.let { itag -> info.formats.firstOrNull { it.itag == itag }?.let { return it } }
    return EPSabr.pickVideo(info.formats, qualityRange)
  }

  override val videoQuality: EPVideoQualityState
    get() {
      if (!wantsVideo || local != null) return EPVideoQualityState()
      return synchronized(lock) {
        EPVideoQualityState(
          qualities = EPSabr.videoFormats(info.formats).map(EPSabr::quality),
          selectedId = activeVideoItag?.toString(),
          auto = manualItag == null,
        )
      }
    }

  override fun refreshQuality() {}

  override fun setVideoQuality(id: String?, range: EPVideoQualityRange) {
    if (!wantsVideo || local != null) {
      if (id != null) throw EPError(EPErrorCode.UNKNOWN, "Video quality cannot be changed for this track")
      return
    }
    val modeChanged = synchronized(lock) {
      val previousManual = manualItag
      qualityRange = range
      manualItag = if (id != null) {
        val itag = id.toIntOrNull()
        if (itag == null || EPSabr.videoFormats(info.formats).none { it.itag == itag }) {
          throw EPError(EPErrorCode.UNKNOWN, "Unknown video quality $id")
        }
        itag
      } else {
        null
      }
      previousManual != manualItag
    }
    handler.post {
      if (released) return@post
      val needsRestart = session != null && synchronized(lock) {
        activeVideoItag != null && selectedVideoFormatLocked()?.itag != activeVideoItag
      }
      if (needsRestart) load(currentTime)
      if (needsRestart || modeChanged) delegate?.onPipelineVideoQuality(this)
    }
  }

  override fun mapError(error: PlaybackException): EPError? {
    val feed = generateSequence<Throwable>(error) { it.cause }.filterIsInstance<EPSabrFeedException>().firstOrNull()
    if (feed != null && feed.generation != generation) return null
    callbackError?.let { return it }
    if (local != null) return super.mapError(error)
    val retry = synchronized(lock) { reusedSession } && hub?.producedAudio != true
    if (retry) {
      synchronized(lock) { reusedSession = false }
      handler.post { if (!released) load(currentTime) }
      return null
    }
    val cause = feed?.cause ?: error
    return EPError(EPErrorCode.SABR_STREAM_FAILED, cause.message ?: error.errorCodeName)
  }

  override fun teardown() {
    generation += 1
    tearDownSession()
    super.teardown()
  }

  override fun onSessionReload(session: EPSabrSession, serverAbrStreamingUrl: String, config: String) {
    synchronized(lock) {
      info = info.copy(serverAbrStreamingUrl = serverAbrStreamingUrl, videoPlaybackUstreamerConfig = config)
    }
  }

  override fun onSessionMint(session: EPSabrSession, token: ByteArray) {
    synchronized(lock) { poToken = u8ToBase64(token) }
  }

  override fun onSessionCallbackFailed(session: EPSabrSession, error: EPError) {
    val gen = generation
    handler.post {
      if (released || gen != generation || session !== this.session) return@post
      callbackError = error
      fail(error)
    }
  }

  override fun onSessionStreamFailed(session: EPSabrSession, error: Throwable) {}
}
