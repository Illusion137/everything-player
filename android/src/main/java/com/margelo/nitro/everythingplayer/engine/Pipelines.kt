package com.margelo.nitro.everythingplayer.engine

import android.content.Context
import android.net.Uri
import android.os.Handler
import android.os.Looper
import androidx.media3.common.AudioAttributes
import androidx.media3.common.C
import androidx.media3.common.MediaItem
import androidx.media3.common.MediaMetadata
import androidx.media3.common.PlaybackException
import androidx.media3.common.PlaybackParameters
import androidx.media3.common.Player
import androidx.media3.common.TrackSelectionOverride
import androidx.media3.common.TrackSelectionParameters
import androidx.media3.common.Tracks
import androidx.media3.common.VideoSize
import androidx.annotation.OptIn
import androidx.media3.common.util.UnstableApi
import androidx.media3.exoplayer.DefaultLoadControl
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.hls.HlsMediaSource
import androidx.media3.exoplayer.source.MediaSource
import androidx.media3.exoplayer.source.ProgressiveMediaSource

sealed class EPPipelineStatus {
  object Idle : EPPipelineStatus()
  object Loading : EPPipelineStatus()
  object Buffering : EPPipelineStatus()
  object Ready : EPPipelineStatus()
  object Playing : EPPipelineStatus()
  object Ended : EPPipelineStatus()
  data class Failed(val message: String) : EPPipelineStatus()
}

interface EPPipelineDelegate {
  fun onPipelineStatus(pipeline: EPPipeline, status: EPPipelineStatus)
  fun onPipelineError(pipeline: EPPipeline, error: EPError)
  fun onPipelineDuration(pipeline: EPPipeline)
  fun onPipelineVideoQuality(pipeline: EPPipeline)
}

internal fun TrackSelectionParameters.Builder.applyVideoRange(range: EPVideoQualityRange): TrackSelectionParameters.Builder =
  setMaxVideoSize(Int.MAX_VALUE, range.maxHeight ?: Int.MAX_VALUE)
    .setMinVideoSize(0, range.minHeight ?: 0)
    .setMaxVideoBitrate(range.maxBitrate ?: Int.MAX_VALUE)

interface EPPipeline {
  val track: EPTrack
  var delegate: EPPipelineDelegate?
  val status: EPPipelineStatus
  val currentTime: Double
  val mediaDuration: Double?
  val bufferedTime: Double
  var volume: Float
  var rate: Float
  val exoPlayer: ExoPlayer?
  val videoQuality: EPVideoQualityState

  fun setVideoQuality(id: String?, range: EPVideoQualityRange)
  fun load(position: Double)
  fun play()
  fun pause()
  fun seek(seconds: Double)
  fun attachVideo()
  fun detachVideo()
  fun teardown()
}

@OptIn(UnstableApi::class)
open class EPExoPipeline(
  private val context: Context,
  override val track: EPTrack,
  protected val options: EPSetupOptions,
  private val downloaded: Boolean,
  initialRange: EPVideoQualityRange,
) : EPPipeline, Player.Listener {
  override var delegate: EPPipelineDelegate? = null
  final override var status: EPPipelineStatus = EPPipelineStatus.Idle
    private set

  protected val player: ExoPlayer
  private var equalizer: EPEqualizerController? = null
  private var frozenPosition: Double? = null
  private var seeking = false
  protected var playWhenReady = false
    private set
  protected var released = false
    private set
  private var videoAttached = false
  private var manualQualityId: String? = null
  protected val handler: Handler

  @Volatile
  private var qualityState = EPVideoQualityState()

  init {
    val forwardMs = maxOf(2_000, (options.forwardBufferSeconds * 1000).toInt())
    val loadControl = DefaultLoadControl.Builder()
      .setBufferDurationsMs(minOf(15_000, forwardMs), forwardMs, 1_000, 2_000)
      .setTargetBufferBytes(options.maxBufferBytes)
      .setPrioritizeTimeOverSizeThresholds(false)
      .build()
    player = ExoPlayer.Builder(context)
      .setLoadControl(loadControl)
      .setAudioAttributes(
        AudioAttributes.Builder().setUsage(C.USAGE_MEDIA).setContentType(C.AUDIO_CONTENT_TYPE_MUSIC).build(),
        false,
      )
      .setWakeMode(C.WAKE_MODE_NETWORK)
      .build()
    player.trackSelectionParameters = player.trackSelectionParameters.buildUpon().apply {
      if (options.enableVideo) applyVideoRange(initialRange) else setTrackTypeDisabled(C.TRACK_TYPE_VIDEO, true)
    }.build()
    handler = Handler(player.applicationLooper)
    player.addListener(this)
    player.addAnalyticsListener(androidx.media3.exoplayer.util.EventLogger("EPDBG-${track.id}"))
  }

  override val videoQuality: EPVideoQualityState get() = qualityState

  override fun setVideoQuality(id: String?, range: EPVideoQualityRange) {
    if (id != null && qualityState.qualities.none { it.id == id }) {
      throw EPError(EPErrorCode.UNKNOWN, "Unknown video quality $id")
    }
    handler.post {
      if (released || !options.enableVideo) return@post
      manualQualityId = id
      val builder = player.trackSelectionParameters.buildUpon()
        .clearOverridesOfType(C.TRACK_TYPE_VIDEO)
        .applyVideoRange(range)
      if (id != null) {
        val (gi, ti) = id.split(":").map { it.toInt() }
        player.currentTracks.groups.getOrNull(gi)?.let { builder.setOverrideForType(TrackSelectionOverride(it.mediaTrackGroup, ti)) }
      }
      player.trackSelectionParameters = builder.build()
      refreshQuality()
    }
  }

  protected open fun refreshQuality() {
    if (!options.enableVideo) return
    val playing = player.videoFormat
    val list = mutableListOf<EPVideoQuality>()
    var selected: String? = null
    player.currentTracks.groups.forEachIndexed { gi, group ->
      if (group.type != C.TRACK_TYPE_VIDEO) return@forEachIndexed
      for (i in 0 until group.length) {
        if (!group.isTrackSupported(i)) continue
        val f = group.getTrackFormat(i)
        val id = "$gi:$i"
        val height = f.height.takeIf { it > 0 }
        val bitrate = listOf(f.averageBitrate, f.bitrate, f.peakBitrate).firstOrNull { it > 0 } ?: 0
        list.add(EPVideoQuality(
          id, f.width.takeIf { it > 0 }, height, f.frameRate.takeIf { it > 0 }?.toDouble(), bitrate,
          height?.let { "${it}p" } ?: "${bitrate / 1000} kbps", f.codecs,
        ))
        if (playing != null && f.id == playing.id && f.height == playing.height) selected = id
      }
    }
    list.sortWith(compareByDescending<EPVideoQuality> { it.height ?: 0 }.thenByDescending { it.bitrate })
    val next = EPVideoQualityState(list, selected ?: manualQualityId, manualQualityId == null)
    if (next != qualityState) {
      qualityState = next
      delegate?.onPipelineVideoQuality(this)
    }
  }

  override fun onTracksChanged(tracks: Tracks) {
    refreshQuality()
  }

  override val exoPlayer: ExoPlayer get() = player

  override val currentTime: Double
    get() = frozenPosition ?: (player.currentPosition / 1000.0)

  @Volatile
  private var knownDuration: Double? = null

  override val mediaDuration: Double?
    get() {
      if (Looper.myLooper() != player.applicationLooper) return knownDuration
      return player.duration.takeIf { it != C.TIME_UNSET && it > 0 }?.let { it / 1000.0 }.also { knownDuration = it }
    }

  override val bufferedTime: Double get() = player.bufferedPosition / 1000.0

  override var volume: Float
    get() = player.volume
    set(value) { player.volume = value }

  override var rate: Float
    get() = player.playbackParameters.speed
    set(value) { player.playbackParameters = PlaybackParameters(value) }

  protected open fun mediaSource(position: Double): MediaSource {
    val uri = Uri.parse(track.url ?: throw EPError(EPErrorCode.SOURCE_ERROR, "Track ${track.id} has no URL"))
    val metadata = MediaMetadata.Builder()
      .setTitle(track.title)
      .setArtist(track.artist)
      .setAlbumTitle(track.album)
      .setArtworkUri(track.artwork?.let { Uri.parse(it) })
      .build()
    val item = MediaItem.Builder()
      .setUri(uri)
      .setMediaId(track.id)
      .setMediaMetadata(metadata)
      .apply {
        track.endTime?.let {
          setClippingConfiguration(MediaItem.ClippingConfiguration.Builder().setEndPositionMs((it * 1000).toLong()).build())
        }
      }
      .build()
    val factory = EPMediaCache.playbackFactory(context, track.requestHeaders, downloaded)
    return if (track.sourceType == EPSourceType.HLS) {
      HlsMediaSource.Factory(factory).createMediaSource(item)
    } else {
      ProgressiveMediaSource.Factory(factory).createMediaSource(item)
    }
  }

  override fun load(position: Double) {
    val start = maxOf(position, track.trimStart)
    val source = try {
      mediaSource(start)
    } catch (e: EPError) {
      fail(e)
      return
    }
    frozenPosition = if (start > 0) start else null
    seeking = start > 0
    setStatus(EPPipelineStatus.Loading)
    player.setMediaSource(source, (start * 1000).toLong())
    player.playWhenReady = playWhenReady
    player.prepare()
  }

  override fun play() {
    playWhenReady = true
    if (status == EPPipelineStatus.Ended) return
    player.playWhenReady = true
  }

  override fun pause() {
    playWhenReady = false
    player.playWhenReady = false
    if (status == EPPipelineStatus.Playing || status == EPPipelineStatus.Buffering) setStatus(EPPipelineStatus.Ready)
  }

  override fun seek(seconds: Double) {
    val target = maxOf(track.trimStart, seconds)
    frozenPosition = target
    seeking = true
    if (status == EPPipelineStatus.Ended) status = EPPipelineStatus.Ready
    setStatus(EPPipelineStatus.Loading)
    player.seekTo((target * 1000).toLong())
    player.playWhenReady = playWhenReady
  }

  override fun attachVideo() {
    if (!options.enableVideo || videoAttached) return
    videoAttached = true
    player.setVideoSurface(EPVideoHub.inputSurface)
    val size = player.videoSize
    if (size.width > 0) EPVideoHub.setVideoSize(size.width, size.height)
  }

  override fun detachVideo() {
    if (!videoAttached) return
    videoAttached = false
    player.clearVideoSurface()
  }

  override fun teardown() {
    released = true
    detachVideo()
    player.removeListener(this)
    equalizer?.release()
    equalizer = null
    player.release()
  }

  override fun onPlaybackStateChanged(playbackState: Int) {
    when (playbackState) {
      Player.STATE_BUFFERING -> setStatus(if (seeking || status == EPPipelineStatus.Loading) EPPipelineStatus.Loading else EPPipelineStatus.Buffering)
      Player.STATE_READY -> {
        if (equalizer == null && player.audioSessionId != C.AUDIO_SESSION_ID_UNSET) {
          equalizer = EPEqualizerController(player.audioSessionId)
        }
        if (seeking) {
          seeking = false
          frozenPosition = null
        }
        setStatus(if (player.isPlaying) EPPipelineStatus.Playing else if (playWhenReady) EPPipelineStatus.Buffering else EPPipelineStatus.Ready)
      }
      Player.STATE_ENDED -> setStatus(EPPipelineStatus.Ended)
      else -> Unit
    }
  }

  override fun onIsPlayingChanged(isPlaying: Boolean) {
    if (isPlaying) {
      setStatus(EPPipelineStatus.Playing)
    } else if (player.playbackState == Player.STATE_READY) {
      setStatus(if (playWhenReady) EPPipelineStatus.Buffering else EPPipelineStatus.Ready)
    }
  }

  override fun onTimelineChanged(timeline: androidx.media3.common.Timeline, reason: Int) {
    if (mediaDuration != null) delegate?.onPipelineDuration(this)
  }

  override fun onAudioSessionIdChanged(audioSessionId: Int) {
    equalizer?.release()
    equalizer = if (audioSessionId != C.AUDIO_SESSION_ID_UNSET) EPEqualizerController(audioSessionId) else null
  }

  override fun onVideoSizeChanged(videoSize: VideoSize) {
    if (videoAttached && videoSize.width > 0) EPVideoHub.setVideoSize(videoSize.width, videoSize.height)
    refreshQuality()
  }

  override fun onPlayerError(error: PlaybackException) {
    mapError(error)?.let { fail(it) }
  }

  protected open fun mapError(error: PlaybackException): EPError? {
    val code = when (error.errorCode) {
      in PlaybackException.ERROR_CODE_IO_UNSPECIFIED..PlaybackException.ERROR_CODE_IO_CLEARTEXT_NOT_PERMITTED -> EPErrorCode.NETWORK_ERROR
      in PlaybackException.ERROR_CODE_DECODER_INIT_FAILED..PlaybackException.ERROR_CODE_DECODING_RESOURCES_RECLAIMED -> EPErrorCode.DECODE_ERROR
      else -> EPErrorCode.SOURCE_ERROR
    }
    return EPError(code, error.message ?: error.errorCodeName)
  }

  protected fun setStatus(new: EPPipelineStatus) {
    if (released || status == new || status is EPPipelineStatus.Failed) return
    status = new
    delegate?.onPipelineStatus(this, new)
  }

  protected fun fail(error: EPError) {
    if (released || status is EPPipelineStatus.Failed) return
    error.trackId = track.id
    player.playWhenReady = false
    status = EPPipelineStatus.Failed(error.message)
    delegate?.onPipelineError(this, error)
  }
}
