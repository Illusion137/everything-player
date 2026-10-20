package com.margelo.nitro.everythingplayer

import androidx.annotation.Keep
import androidx.annotation.OptIn
import androidx.media3.common.util.UnstableApi
import com.facebook.proguard.annotations.DoNotStrip
import com.margelo.nitro.NitroModules
import com.margelo.nitro.core.Promise
import com.margelo.nitro.core.resolved
import com.margelo.nitro.everythingplayer.engine.EPAppKilledBehavior
import com.margelo.nitro.everythingplayer.engine.EPDownloads
import com.margelo.nitro.everythingplayer.engine.EPEqualizerSettings
import com.margelo.nitro.everythingplayer.engine.EPError
import com.margelo.nitro.everythingplayer.engine.EPErrorCode
import com.margelo.nitro.everythingplayer.engine.EPPlayerEngine
import com.margelo.nitro.everythingplayer.engine.EPRepeatMode
import com.margelo.nitro.everythingplayer.engine.EPSabrDownloads
import com.margelo.nitro.everythingplayer.engine.EPSetupOptions
import com.margelo.nitro.everythingplayer.engine.EPSourceType
import com.margelo.nitro.everythingplayer.engine.EPState
import com.margelo.nitro.everythingplayer.engine.EPUpdateOptions

@OptIn(UnstableApi::class)
@DoNotStrip
@Keep
class HybridEverythingPlayer : HybridEverythingPlayerSpec() {
  private val engine = EPPlayerEngine

  private val context
    get() = NitroModules.applicationContext
      ?: throw EPError(EPErrorCode.UNKNOWN, "React context is not available yet")

  override fun isSetup(): Boolean = engine.isSetup

  override fun setupPlayer(options: NativeSetupOptions): Promise<Unit> {
    val ctx = context
    engine.downloadedResolver = { track -> EPDownloads.isCompleted(ctx, track.id) }
    engine.localSabrResolver = { track -> EPSabrDownloads.localMedia(ctx, track) }
    engine.setup(
      ctx,
      EPSetupOptions(
        cacheMaxSizeMB = options.cacheConfig.maxSizeMB,
        cacheMaxAgeSeconds = options.cacheConfig.maxAgeSeconds,
        preloadNext = options.cacheConfig.preloadNext.toInt(),
        persistentCache = options.cacheConfig.persistent,
        forwardBufferSeconds = maxOf(1.0, options.bufferConfig.forwardBufferSeconds),
        maxBufferBytes = maxOf(256.0 * 1024, options.bufferConfig.maxBufferBytes).toInt(),
        enableVideo = options.enableVideo,
        autoHandleRemoteEvents = options.autoHandleRemoteEvents,
        autoHandleInterruptions = options.autoHandleInterruptions,
        sabrCallbackTimeoutMs = options.sabrCallbackTimeoutMs,
        sabrPoolAhead = options.sabrPoolAhead.toInt(),
        videoQualityRange = options.videoQuality.toEngine(),
      ),
    )
    return Promise.resolved()
  }

  override fun updateOptions(options: NativeUpdateOptions): Promise<Unit> {
    engine.update(
      EPUpdateOptions(
        capabilities = options.capabilities.map { it.key() }.toSet(),
        progressUpdateEventInterval = options.progressUpdateEventInterval,
        forwardJumpInterval = options.forwardJumpInterval,
        backwardJumpInterval = options.backwardJumpInterval,
        appKilledBehavior = when (options.appKilledPlaybackBehavior) {
          NativeAppKilledPlaybackBehavior.PAUSE_PLAYBACK -> EPAppKilledBehavior.PAUSE
          NativeAppKilledPlaybackBehavior.STOP_PLAYBACK_AND_REMOVE_NOTIFICATION -> EPAppKilledBehavior.STOP_AND_REMOVE
          else -> EPAppKilledBehavior.CONTINUE
        },
      ),
    )
    return Promise.resolved()
  }

  override fun setRepeatMode(mode: NativeRepeatMode) {
    engine.setRepeatMode(
      when (mode) {
        NativeRepeatMode.TRACK -> EPRepeatMode.TRACK
        NativeRepeatMode.QUEUE -> EPRepeatMode.QUEUE
        else -> EPRepeatMode.OFF
      },
    )
  }

  override fun getRepeatMode(): NativeRepeatMode = when (engine.getRepeatMode()) {
    EPRepeatMode.TRACK -> NativeRepeatMode.TRACK
    EPRepeatMode.QUEUE -> NativeRepeatMode.QUEUE
    EPRepeatMode.OFF -> NativeRepeatMode.OFF
  }

  override fun setEqualizer(bands: DoubleArray) = engine.setEqualizer(FloatArray(bands.size) { bands[it].toFloat() })
  override fun getEqualizer(): DoubleArray = EPEqualizerSettings.gains.map { it.toDouble() }.toDoubleArray()
  override fun setCrossFade(seconds: Double) = engine.setCrossFade(seconds)
  override fun setVolume(volume: Double) = engine.setVolume(volume.toFloat())
  override fun getVolume(): Double = engine.getVolume().toDouble()
  override fun setRate(rate: Double) = engine.setRate(rate.toFloat())
  override fun getRate(): Double = engine.getRate().toDouble()

  override fun getVideoQualities(): NativeVideoQualityState = engine.getVideoQuality().toNative(engine.activeTrackId)
  override fun setVideoQuality(id: String?) = engine.setVideoQuality(id)
  override fun setVideoQualityRange(range: NativeVideoQualityRange) = engine.setVideoQualityRange(range.toEngine())
  override fun getVideoQualityRange(): NativeVideoQualityRange = engine.getVideoQualityRange().toNative()

  override fun setOnVideoQualityChanged(callback: (state: NativeVideoQualityState) -> Unit) {
    engine.onVideoQualityChanged = { state, trackId -> callback(state.toNative(trackId)) }
  }

  override fun add(tracks: Array<NativeTrack>, insertBeforeIndex: Double?) =
    engine.add(tracks.map { it.toEngine() }, insertBeforeIndex?.toInt())

  override fun remove(indexes: DoubleArray) = engine.remove(indexes.map { it.toInt() })
  override fun move(fromIndex: Double, toIndex: Double) = engine.move(fromIndex.toInt(), toIndex.toInt())
  override fun setQueue(tracks: Array<NativeTrack>) = engine.setQueue(tracks.map { it.toEngine() })
  override fun updateMetadataForTrack(index: Double, track: NativeTrack) = engine.updateMetadata(index.toInt(), track.toEngine())
  override fun getQueue(): Array<NativeTrack> = engine.getQueue().map { it.toNative() }.toTypedArray()
  override fun getActiveTrackIndex(): Double? = engine.getActiveIndex()?.toDouble()

  override fun skip(index: Double, initialPosition: Double?): Promise<Unit> {
    engine.skip(index.toInt(), initialPosition)
    return Promise.resolved()
  }

  override fun skipToNext(initialPosition: Double?): Promise<Unit> {
    engine.skipToNext(initialPosition)
    return Promise.resolved()
  }

  override fun skipToPrevious(initialPosition: Double?): Promise<Unit> {
    engine.skipToPrevious(initialPosition)
    return Promise.resolved()
  }

  override fun removeUpcomingTracks() = engine.removeUpcoming()
  override fun play() = engine.play()
  override fun pause() = engine.pause()
  override fun stop() = engine.stop()
  override fun reset() = engine.reset()
  override fun seekTo(seconds: Double) = engine.seekTo(seconds)
  override fun seekBy(offset: Double) = engine.seekBy(offset)
  override fun retry() = engine.retry()

  override fun getProgress(): NativeProgress {
    val p = engine.getProgress()
    return NativeProgress(p.position, p.duration, p.buffered)
  }

  override fun getPlaybackState(): NativePlaybackStateEvent {
    val state = engine.getState()
    return NativePlaybackStateEvent(state.toNative(), if (state == EPState.ERROR) engine.getLastError()?.toNative() else null)
  }

  override fun getSourceType(index: Double): NativeSourceType? =
    engine.getQueue().getOrNull(index.toInt())?.sourceType?.let {
      when (it) {
        EPSourceType.RAW -> NativeSourceType.RAW
        EPSourceType.HLS -> NativeSourceType.HLS
        EPSourceType.SABR -> NativeSourceType.SABR
      }
    }

  override fun setOnPlaybackState(callback: (event: NativePlaybackStateEvent) -> Unit) {
    engine.onStateChange = { state, error -> callback(NativePlaybackStateEvent(state.toNative(), error?.toNative())) }
  }

  override fun setOnActiveTrackChanged(callback: (event: NativeActiveTrackChangedEvent) -> Unit) {
    engine.onActiveTrackChanged = { c ->
      callback(NativeActiveTrackChangedEvent(c.lastIndex?.toDouble(), c.lastTrackId, c.lastPosition, c.index?.toDouble(), c.trackId))
    }
  }

  override fun setOnProgress(callback: (event: NativeProgressEvent) -> Unit) {
    engine.onProgress = { p, index, id -> callback(NativeProgressEvent(p.position, p.duration, p.buffered, index?.toDouble(), id)) }
  }

  override fun setOnPlaybackError(callback: (error: NativePlaybackError) -> Unit) {
    engine.onError = { callback(it.toNative()) }
  }

  override fun setOnQueueEnded(callback: (event: NativeQueueEndedEvent) -> Unit) {
    engine.onQueueEnded = { index, id, position -> callback(NativeQueueEndedEvent(index?.toDouble(), id, position)) }
  }

  override fun setOnRemoteEvent(callback: (event: NativeRemoteEvent) -> Unit) {
    engine.onRemote = { callback(it.toNative()) }
  }

  override fun setSabrCallbacks(
    onMintPoToken: (trackId: String) -> Promise<Promise<String>>,
    onReloadPlayerResponse: (trackId: String, context: NativeReloadPlaybackContext) -> Promise<Promise<NativeReloadPlayerResponse>>,
  ) {
    engine.sabrCallbacks = JSSabrCallbacks(onMintPoToken, onReloadPlayerResponse)
  }

  private fun EPState.toNative(): NativeState = when (this) {
    EPState.NONE -> NativeState.NONE
    EPState.READY -> NativeState.READY
    EPState.PLAYING -> NativeState.PLAYING
    EPState.PAUSED -> NativeState.PAUSED
    EPState.STOPPED -> NativeState.STOPPED
    EPState.BUFFERING -> NativeState.BUFFERING
    EPState.LOADING -> NativeState.LOADING
    EPState.ERROR -> NativeState.ERROR
    EPState.ENDED -> NativeState.ENDED
  }
}
