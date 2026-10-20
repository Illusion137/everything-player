package com.margelo.nitro.everythingplayer.googlevideo.core

import com.google.protobuf.ByteString
import com.margelo.nitro.everythingplayer.googlevideo.protos.misc.SeekSource
import com.margelo.nitro.everythingplayer.googlevideo.protos.video_streaming.ClientAbrState
import com.margelo.nitro.everythingplayer.googlevideo.protos.video_streaming.CuepointList
import com.margelo.nitro.everythingplayer.googlevideo.protos.video_streaming.FormatInitializationMetadata
import com.margelo.nitro.everythingplayer.googlevideo.protos.video_streaming.MediaHeader
import com.margelo.nitro.everythingplayer.googlevideo.protos.video_streaming.NextRequestPolicy
import com.margelo.nitro.everythingplayer.googlevideo.protos.video_streaming.ReloadPlaybackContext
import com.margelo.nitro.everythingplayer.googlevideo.protos.video_streaming.SabrContextSendingPolicy
import com.margelo.nitro.everythingplayer.googlevideo.protos.video_streaming.SabrContextUpdate
import com.margelo.nitro.everythingplayer.googlevideo.protos.video_streaming.SabrError
import com.margelo.nitro.everythingplayer.googlevideo.protos.video_streaming.SabrLiveMetadata
import com.margelo.nitro.everythingplayer.googlevideo.protos.video_streaming.SabrRedirect
import com.margelo.nitro.everythingplayer.googlevideo.protos.video_streaming.SabrSeek
import com.margelo.nitro.everythingplayer.googlevideo.protos.video_streaming.SsapPlaybackInfo
import com.margelo.nitro.everythingplayer.googlevideo.protos.video_streaming.StreamProtectionStatus
import com.margelo.nitro.everythingplayer.googlevideo.protos.video_streaming.StreamerContext
import com.margelo.nitro.everythingplayer.googlevideo.protos.video_streaming.UMPPartId
import com.margelo.nitro.everythingplayer.googlevideo.protos.video_streaming.VideoPlaybackAbrRequest
import com.margelo.nitro.everythingplayer.googlevideo.types.AbortOptions
import com.margelo.nitro.everythingplayer.googlevideo.types.FetchFunction
import com.margelo.nitro.everythingplayer.googlevideo.types.FetchRequest
import com.margelo.nitro.everythingplayer.googlevideo.types.FetchResponse
import com.margelo.nitro.everythingplayer.googlevideo.types.HeartbeatCheckType
import com.margelo.nitro.everythingplayer.googlevideo.types.HeartbeatParams
import com.margelo.nitro.everythingplayer.googlevideo.types.HeartbeatRequest
import com.margelo.nitro.everythingplayer.googlevideo.types.HeartbeatRequestParams
import com.margelo.nitro.everythingplayer.googlevideo.types.PlayabilityStatus
import com.margelo.nitro.everythingplayer.googlevideo.types.SabrFormat
import com.margelo.nitro.everythingplayer.googlevideo.types.SabrPlaybackOptions
import com.margelo.nitro.everythingplayer.googlevideo.types.SabrSnapshot
import com.margelo.nitro.everythingplayer.googlevideo.types.SabrStreamCallbacks
import com.margelo.nitro.everythingplayer.googlevideo.types.SabrStreamConfig
import com.margelo.nitro.everythingplayer.googlevideo.types.SabrStreamEvent
import com.margelo.nitro.everythingplayer.googlevideo.types.SelectedFormats
import com.margelo.nitro.everythingplayer.googlevideo.types.StreamStartResult
import com.margelo.nitro.everythingplayer.googlevideo.types.TrackOutput
import com.margelo.nitro.everythingplayer.googlevideo.types.TrackState
import com.margelo.nitro.everythingplayer.googlevideo.types.defaultFetchFunction
import com.margelo.nitro.everythingplayer.googlevideo.utils.AbortController
import com.margelo.nitro.everythingplayer.googlevideo.utils.ClientInfo
import com.margelo.nitro.everythingplayer.googlevideo.utils.CuepointEvent
import com.margelo.nitro.everythingplayer.googlevideo.utils.EnabledTrackTypes
import com.margelo.nitro.everythingplayer.googlevideo.utils.EventEmitterLike
import com.margelo.nitro.everythingplayer.googlevideo.utils.FormatId
import com.margelo.nitro.everythingplayer.googlevideo.utils.FormatPreferences
import com.margelo.nitro.everythingplayer.googlevideo.utils.Logger
import com.margelo.nitro.everythingplayer.googlevideo.utils.MediaType
import com.margelo.nitro.everythingplayer.googlevideo.utils.OrderedMap
import com.margelo.nitro.everythingplayer.googlevideo.utils.ReadableStream
import com.margelo.nitro.everythingplayer.googlevideo.utils.SabrContext
import com.margelo.nitro.everythingplayer.googlevideo.utils.SabrContextWritePolicy
import com.margelo.nitro.everythingplayer.googlevideo.utils.AdState
import com.margelo.nitro.everythingplayer.googlevideo.utils.SabrSegmentBuffer
import com.margelo.nitro.everythingplayer.googlevideo.utils.TrackCollection
import com.margelo.nitro.everythingplayer.googlevideo.utils.assert
import com.margelo.nitro.everythingplayer.googlevideo.utils.assertIsDefined
import com.margelo.nitro.everythingplayer.googlevideo.utils.base64ToU8
import com.margelo.nitro.everythingplayer.googlevideo.utils.buildMediaCapabilities
import com.margelo.nitro.everythingplayer.googlevideo.utils.chooseFormat
import com.margelo.nitro.everythingplayer.googlevideo.utils.createFormatKey
import com.margelo.nitro.everythingplayer.googlevideo.utils.decodePart
import com.margelo.nitro.everythingplayer.googlevideo.utils.describeMissingFormat
import com.margelo.nitro.everythingplayer.googlevideo.utils.errorMessage
import com.margelo.nitro.everythingplayer.googlevideo.utils.getBroadcastId
import com.margelo.nitro.everythingplayer.googlevideo.utils.getMediaType
import com.margelo.nitro.everythingplayer.googlevideo.utils.getNextFallbackUrl
import com.margelo.nitro.everythingplayer.googlevideo.utils.has
import com.margelo.nitro.everythingplayer.googlevideo.utils.nowMs
import com.margelo.nitro.everythingplayer.googlevideo.utils.searchParam
import com.margelo.nitro.everythingplayer.googlevideo.utils.settingSearchParam
import com.margelo.nitro.everythingplayer.googlevideo.utils.ticksToMs
import com.margelo.nitro.everythingplayer.googlevideo.utils.urlHost
import com.margelo.nitro.everythingplayer.googlevideo.utils.wait
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.async
import kotlinx.coroutines.launch
import kotlin.coroutines.cancellation.CancellationException
import kotlin.coroutines.resume
import kotlin.coroutines.suspendCoroutine
import kotlin.math.floor
import kotlin.math.min
import kotlin.math.pow

private const val TAG = "SabrStream"

private const val MAX_STALLS = 3
private const val DEFAULT_MAX_RETRIES = 10
private const val DEFAULT_STALL_DETECTION_MS = 30_000L
private const val REQUEST_TIMEOUT_MS = 30_000L
private const val INITIAL_RETRY_BACKOFF_MS = 500L
private const val MAX_RETRY_BACKOFF_MS = 5_000L
private const val OFFLINE_GRACE_PERIOD_MS: Double = 15_000.0
private const val DEFAULT_HEARTBEAT_INTERVAL_MS = 10_000L
private const val LIVE_EDGE_SENTINEL_MS = 9_007_199_254_740_991L

private const val DEFAULT_VIDEO_HWM = 1024 * 1024 * 16
private const val DEFAULT_AUDIO_HWM = 1024 * 1024 * 3

private const val BANDWIDTH_EMA_PREVIOUS_WEIGHT = 0.8
private const val BANDWIDTH_EMA_CURRENT_WEIGHT = 0.2
private const val MIN_FETCH_DURATION_FOR_BW_ESTIMATE_MS = 50.0

private enum class SeekOrigin(val rawValue: String) {
  SERVER("server"),
  CLIENT("client"),
}

private class Runtime {
  @Volatile var playerTimeMs = 0L
  @Volatile var requestNumber = 0
  @Volatile var bandwidthEstimateBps = 0.0
  @Volatile var lastHeartbeatTimeMs = 0.0
  @Volatile var playbackSessionStartMs: Double? = null
  @Volatile var poTokenGenerationId = 0
  @Volatile var spsRejectCount = 0
}

private class Lifecycle {
  @Volatile var aborted = false
  @Volatile var errored = false
  @Volatile var busy = false
}

private class ProgressTracker(
  var lastProgressTime: Double = nowMs(),
  var lastBufferedTimeMs: Double = 0.0,
  var stallCount: Int = 0,
)

class SabrStream(config: SabrStreamConfig) : EventEmitterLike() {
  private val logger = Logger.getInstance()
  private val formats: List<SabrFormat> = config.formats
  private val segmentBuffer: SabrSegmentBuffer
  private val stateLock = Any()
  private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)

  private val fetchFunction: FetchFunction = config.fetchFunction ?: defaultFetchFunction
  @Volatile private var abortController: AbortController? = null
  private var requestTimeoutTask: Job? = null

  @Volatile private var serverAbrStreamingUrl: String?
  @Volatile private var videoPlaybackUstreamerConfig: String = config.videoPlaybackUstreamerConfig
  private val clientInfo: ClientInfo = config.clientInfo
  @Volatile private var proofOfOriginToken: ByteArray? = config.poToken?.let { if (it.isEmpty()) null else base64ToU8(it) }
  private var heartbeatParams: HeartbeatParams = config.heartbeatParams ?: HeartbeatParams()

  @Volatile private var nextRequestPolicy: NextRequestPolicy? = null
  private val ssapPlaybackInfos = OrderedMap<String, SsapPlaybackInfo>()
  private val sabrContextUpdates = OrderedMap<Int, SabrContextUpdate>()
  private val activeSabrContextTypes = LinkedHashSet<Int>()
  private val trackCollection: TrackCollection

  private val videoId: String? = config.videoId
  private var broadcastId: String?

  private val idleResolvers = mutableListOf<() -> Unit>()
  private var drainResolver: (() -> Unit)? = null

  @Volatile private var shouldStop = false
  private var seekEpoch = 0
  @Volatile private var lastSeekWallMs: Double? = null
  private var resumeResolver: (() -> Unit)? = null
  private var warming = false
  @Volatile private var nextRequestPolicyReceivedMs = 0.0
  private var selectedFormats: SelectedFormats? = null
  private val videoHighWaterMark: Int = config.videoHighWaterMark ?: DEFAULT_VIDEO_HWM
  private val audioHighWaterMark: Int = config.audioHighWaterMark ?: DEFAULT_AUDIO_HWM
  @Volatile private var isMintingPoToken = false
  private var isBroadcast = false

  private val runtime = Runtime()
  private val lifecycle = Lifecycle()
  @Volatile private var progressTracker = ProgressTracker()

  private val callbacks: SabrStreamCallbacks = config.callbacks ?: SabrStreamCallbacks()

  init {
    val streamingUrl = config.serverAbrStreamingUrl.settingSearchParam("alr", "no")
    serverAbrStreamingUrl = streamingUrl

    val isBroadcast = listOf("yt_premiere_broadcast", "yt_live_broadcast").contains(streamingUrl.searchParam("source") ?: "")
    this.isBroadcast = isBroadcast

    broadcastId = if (isBroadcast) getBroadcastId(streamingUrl) else null

    val trackCollection = TrackCollection()
    this.trackCollection = trackCollection

    segmentBuffer = SabrSegmentBuffer(trackCollection, isBroadcast, config.stripDuplicateInit ?: true)

    trackCollection.video.output = createTrackStream(videoHighWaterMark)
    trackCollection.audio.output = createTrackStream(audioHighWaterMark)
  }

  val isLive: Boolean
    get() = isBroadcast

  val isBusy: Boolean
    get() = lifecycle.busy

  val isAborted: Boolean
    get() = lifecycle.aborted

  val isErrored: Boolean
    get() = lifecycle.errored

  val videoEndTimeMs: Long
    get() = trackCollection.video.endTimeMs

  val audioEndTimeMs: Long
    get() = trackCollection.audio.endTimeMs

  val livePlaybackLatencyMs: Double?
    get() {
      if (!isBroadcast) return null
      return trackCollection.livePlaybackLatencyMs
    }

  val streamingURL: String
    get() = assertIsDefined(serverAbrStreamingUrl, "Streaming URL is not set")

  fun setStreamingURL(url: String) {
    val streamingUrl = url.settingSearchParam("alr", "no")
    serverAbrStreamingUrl = streamingUrl
    validateStreamingUrl(streamingUrl)
  }

  fun setUstreamerConfig(config: String) {
    videoPlaybackUstreamerConfig = config
  }

  suspend fun waitForIdle() {
    if (lifecycle.busy) {
      suspendCoroutine<Unit> { continuation ->
        val resumeNow = synchronized(stateLock) {
          if (!lifecycle.busy) {
            true
          } else {
            idleResolvers.add { continuation.resume(Unit) }
            false
          }
        }
        if (resumeNow) continuation.resume(Unit)
      }
    }
  }

  suspend fun snapshot(): SabrSnapshot {
    waitForIdle()
    return SabrSnapshot(
      playerTimeMs = runtime.playerTimeMs,
      tracks = trackCollection.snapshot(),
    )
  }

  suspend fun abort(options: AbortOptions = AbortOptions()): SabrSnapshot? {
    var snapshotData: SabrSnapshot? = null
    if (options.snapshot == true) snapshotData = snapshot()

    emit(SabrStreamEvent.abort)

    lifecycle.aborted = true

    abortController?.abort()
    trackCollection.error("Stream aborted")

    takeDrainResolver()?.invoke()
    takeResumeResolver()?.invoke()

    return snapshotData
  }

  fun seek(toMs: Long): StreamStartResult? {
    val previous: List<TrackOutput>
    val inFlight: AbortController?
    val drain: (() -> Unit)?
    val resume: (() -> Unit)?
    val selectedFormats: SelectedFormats
    synchronized(stateLock) {
      val selected = this.selectedFormats
      if (lifecycle.aborted || lifecycle.errored || shouldStop || isBroadcast || selected == null) {
        return null
      }
      selectedFormats = selected
      seekEpoch += 1
      previous = listOf(trackCollection.video.output, trackCollection.audio.output)
      trackCollection.video.output = createTrackStream(videoHighWaterMark)
      trackCollection.audio.output = createTrackStream(audioHighWaterMark)
      for (track in listOf(trackCollection.video, trackCollection.audio)) {
        track.discardMediaSegments()
        track.initSegment?.let { track.streamController.enqueue(it) }
      }
      segmentBuffer.discardPending()
      runtime.playerTimeMs = toMs
      lastSeekWallMs = nowMs()
      resetProgressTracker(toMs.toDouble())
      inFlight = abortController
      drain = drainResolver
      drainResolver = null
      resume = resumeResolver
      resumeResolver = null
      warming = false
    }

    previous.forEach { it.controller.close() }
    inFlight?.abort()
    drain?.invoke()
    resume?.invoke()

    return StreamStartResult(
      videoStream = trackCollection.video.output.stream,
      audioStream = trackCollection.audio.output.stream,
      selectedFormats = selectedFormats,
    )
  }

  private val currentSeekEpoch: Int
    get() = synchronized(stateLock) { seekEpoch }

  private fun takeResumeResolver(): (() -> Unit)? = synchronized(stateLock) {
    val resolver = resumeResolver
    resumeResolver = null
    resolver
  }

  private suspend fun waitForSeek(after: Int) {
    suspendCoroutine<Unit> { continuation ->
      val resumeNow = synchronized(stateLock) {
        if (seekEpoch != after || lifecycle.aborted) {
          true
        } else {
          resumeResolver = { continuation.resume(Unit) }
          false
        }
      }
      if (resumeNow) continuation.resume(Unit)
    }
  }

  fun warm(options: SabrPlaybackOptions) {
    synchronized(stateLock) { warming = true }
    start(options)
  }

  fun start(options: SabrPlaybackOptions): StreamStartResult {
    assert(runtime.playbackSessionStartMs == null, "This stream instance has already been started and cannot be reused")
    val (videoFormat, audioFormat) = selectFormats(options)
    val selected = SelectedFormats(videoFormat = videoFormat, audioFormat = audioFormat)
    synchronized(stateLock) { selectedFormats = selected }

    scope.launch { setupStreaming(options, audioFormat, videoFormat) }

    return StreamStartResult(
      videoStream = trackCollection.video.output.stream,
      audioStream = trackCollection.audio.output.stream,
      selectedFormats = selected,
    )
  }

  private fun createTrackStream(highWaterMark: Int): TrackOutput {
    var controller: ReadableStream.Controller<ByteArray>? = null
    val stream = ReadableStream<ByteArray>(
      highWaterMark = highWaterMark,
      sizeOf = { it.size },
      start = { controller = it },
      pull = { notifyDrain() },
      onCancel = { reason ->
        logger.debug(TAG, "Stream cancelled by consumer. Reason: ${reason ?: "N/A"}")
        scope.launch { abort() }
      },
    )
    return TrackOutput(stream = stream, controller = controller!!)
  }

  private fun takeDrainResolver(onlyIfDrained: Boolean = false): (() -> Unit)? {
    synchronized(stateLock) {
      if (onlyIfDrained && trackCollection.needsDrain) return null
      val resolver = drainResolver
      drainResolver = null
      return resolver
    }
  }

  private fun notifyDrain() {
    takeDrainResolver(onlyIfDrained = true)?.invoke()
  }

  private suspend fun waitForDrain() {
    if (!trackCollection.needsDrain) return
    logger.debug(TAG, "Waiting for drain")
    suspendCoroutine<Unit> { continuation ->
      val resumeNow = synchronized(stateLock) {
        if (!trackCollection.needsDrain || lifecycle.aborted) {
          true
        } else {
          drainResolver = { continuation.resume(Unit) }
          false
        }
      }
      if (resumeNow) continuation.resume(Unit)
    }
  }

  private fun validateStreamingUrl(url: String) {
    getBroadcastId(url)?.let { validateBroadcastId(it) }
  }

  private fun validateBroadcastId(bid: String) {
    if (isBroadcast && (broadcastId != null && broadcastId != bid)) {
      logger.warn(TAG, "Broadcast ID changed from $broadcastId to $bid. Stopping.")
      shouldStop = true
    }
  }

  private fun selectFormats(options: SabrPlaybackOptions): Pair<SabrFormat?, SabrFormat> {
    val audioOnly = options.enabledTrackTypes == EnabledTrackTypes.AUDIO_ONLY
    val needsVideo = !audioOnly

    val hasAudioSpecs = options.audioFormat != null || options.audioPreferences != null
    val hasVideoSpecs = options.videoFormat != null || options.videoPreferences != null

    if (audioOnly) {
      assert(hasAudioSpecs, "Expected audio format or preferences to be provided")
    } else {
      assert(hasAudioSpecs && hasVideoSpecs, "Expected both video and audio format or preferences to be provided")
    }

    val audioFormat = chooseFormat(formats, options.audioFormat, FormatPreferences(options.audioPreferences))

    val videoFormat = if (needsVideo) {
      chooseFormat(formats, options.videoFormat, FormatPreferences(options.videoPreferences))
    } else {
      null
    }

    val missing = mutableListOf<String>()
    if (needsVideo && videoFormat == null) missing.add(describeMissingFormat(MediaType.VIDEO, options.videoFormat, formats))
    if (audioFormat == null) missing.add(describeMissingFormat(MediaType.AUDIO, options.audioFormat, formats))
    if (missing.isNotEmpty()) throw GoogleVideoError("Could not select formats: ${missing.joinToString("; ")}")

    val selectedAudioFormat = assertIsDefined(audioFormat, "Expected selected audio format")

    return videoFormat to selectedAudioFormat
  }

  private suspend fun setupStreaming(
    options: SabrPlaybackOptions,
    audioFormat: SabrFormat,
    videoFormat: SabrFormat?,
  ) {
    try {
      logger.debug(TAG, "Starting SABR stream: videoFormat=${videoFormat?.itag?.toString() ?: "n/a"}, audioFormat=${audioFormat.itag}, isBroadcast=$isBroadcast, isPostLiveDvr=${options.isPostLiveDvr}")

      tryMintPoToken()

      val maxRetries = options.maxRetries ?: DEFAULT_MAX_RETRIES
      val enabledTrackTypesBitfield = options.enabledTrackTypes ?: EnabledTrackTypes.VIDEO_AND_AUDIO

      val snapshot = options.snapshot
      if (snapshot != null && snapshot.tracks.isNotEmpty()) {
        if (videoFormat != null) {
          assert(
            snapshot.tracks.any { createFormatKey(it) == createFormatKey(videoFormat) },
            "The selected video format does not match any format in the provided snapshot",
          )
        }

        assert(
          snapshot.tracks.any { createFormatKey(it) == createFormatKey(audioFormat) },
          "The selected audio format does not match any format in the provided snapshot",
        )

        for (state in snapshot.tracks) {
          trackCollection.initialize(getMediaType(state.mimeType), state)
        }

        seekTo(snapshot.playerTimeMs, SeekOrigin.CLIENT)
      } else {
        seekTo(options.startTimeMs ?: (if (isBroadcast && !options.isPostLiveDvr) LIVE_EDGE_SENTINEL_MS else 0), SeekOrigin.CLIENT)
      }

      val abrState = ClientAbrState.newBuilder()
      abrState.setPlayerTimeMs(runtime.playerTimeMs)
      audioFormat.audioTrackId?.let { abrState.setAudioTrackId(it) }
      abrState.setClientViewportIsFlexible(false)
      abrState.setDrcEnabled(if (audioFormat.isVb == true) false else audioFormat.isDrc ?: false)
      buildMediaCapabilities(videoFormat, audioFormat)?.let { abrState.setMediaCapabilities(it) }
      audioFormat.isVb?.let { abrState.setEnableVoiceBoost(it) }
      videoFormat?.height?.let { abrState.setStickyResolution(it) }
      abrState.setElapsedWallTimeMs(0)
      abrState.setTimeSinceLastActionMs(0)
      abrState.setTimeSinceLastSeek(0)
      abrState.setPlaybackRate(1f)
      abrState.setVisibility(1)
      abrState.setEnabledTrackTypesBitfield(enabledTrackTypesBitfield.rawValue)

      runtime.playbackSessionStartMs = nowMs()

      while (!shouldStop) {
        if (lifecycle.aborted) {
          logger.debug(TAG, "Stream aborted")
          break
        }

        val elapsedTimeMs = getElapsedWallTimeMs().toLong()

        abrState.setTimeSinceLastSeek(lastSeekWallMs?.let { (nowMs() - it).toLong() } ?: elapsedTimeMs)
        abrState.setTimeSinceLastActionMs(elapsedTimeMs)
        abrState.setElapsedWallTimeMs(elapsedTimeMs)

        if (runtime.bandwidthEstimateBps > 0) {
          abrState.setBandwidthEstimate(Math.round(runtime.bandwidthEstimateBps))
        }

        logger.debug(TAG, "Starting new segment fetch, playerTimeMs=${abrState.playerTimeMs}, bandwidthEstimate=${if (abrState.hasBandwidthEstimate()) abrState.bandwidthEstimate.toString() else "n/a"}, elapsedWallTimeMs=${abrState.elapsedWallTimeMs}")

        checkForStall(options.stallDetectionMs)

        val currentAbrState = abrState.build()

        val success = executeWithRetry({
          fetchAndProcess(
            currentAbrState,
            audioFormat,
            videoFormat,
          )
        }, maxRetries)

        abrState.setPlayerTimeMs(runtime.playerTimeMs)

        val parkEpoch: Int? = synchronized(stateLock) { if (warming) seekEpoch else null }
        if (success && parkEpoch != null) {
          waitForSeek(after = parkEpoch)
          abrState.setPlayerTimeMs(runtime.playerTimeMs)
          continue
        }

        if (trackCollection.endOfStreamReached(enabledTrackTypesBitfield)) {
          if (isBroadcast) {
            shouldStop = true
          } else {
            val epoch = currentSeekEpoch
            trackCollection.close()
            emit(SabrStreamEvent.finish)
            waitForSeek(after = epoch)
            abrState.setPlayerTimeMs(runtime.playerTimeMs)
            continue
          }
        }

        if (isBroadcast) {
          scope.launch { heartbeat() }
        }

        if (!success) break
      }
    } catch (error: Throwable) {
      if (!lifecycle.aborted) {
        errorHandler(error)
      }
    }

    if (!lifecycle.aborted && !lifecycle.errored) {
      trackCollection.close()
      emit(SabrStreamEvent.finish)
    }

    dispose()
  }

  private suspend fun heartbeat() {
    val heartbeatParams = this.heartbeatParams
    val heartbeatCallback = callbacks.onCheckHeartbeat
    val videoId = videoId

    if (heartbeatCallback == null || videoId == null) {
      return
    }

    val intervalMs = heartbeatParams.intervalMilliseconds?.let { it.toLongOrNull() ?: 0 } ?: DEFAULT_HEARTBEAT_INTERVAL_MS
    val timeSinceLastHeartbeat = nowMs() - runtime.lastHeartbeatTimeMs

    if (timeSinceLastHeartbeat < intervalMs.toDouble()) {
      return
    }

    try {
      runtime.lastHeartbeatTimeMs = nowMs()

      val heartbeatBody = HeartbeatRequest(
        heartbeatRequestParams = HeartbeatRequestParams(heartbeatChecks = listOf(HeartbeatCheckType.LIVE_STREAM_STATUS)),
        videoId = videoId,
      )

      if (heartbeatParams.heartbeatToken != null) {
        heartbeatBody.heartbeatToken = heartbeatParams.heartbeatToken
      }

      if (heartbeatParams.heartbeatServerData != null) {
        heartbeatBody.heartbeatServerData = heartbeatParams.heartbeatServerData
      }

      val response = heartbeatCallback(heartbeatBody)
      if (shouldStop) return

      if (response.heartbeatServerData != null) {
        this.heartbeatParams.heartbeatServerData = response.heartbeatServerData
      }

      response.broadcastId?.let { validateBroadcastId(it) }

      if (response.status == PlayabilityStatus.OK) {
        logger.debug(TAG, "Live stream is online")
        return
      }

      if (response.status == PlayabilityStatus.LIVE_STREAM_OFFLINE) {
        if (response.offlineSlatePresent == true && response.displayEndscreen != true) {
          logger.debug(TAG, "Live stream is offline but not displaying end screen. Continuing.")
          return
        }

        if (!(response.displayEndscreen == true || response.offlineSlateButtonsPresent == true)) {
          return
        }

        val elapsedTimeSinceLastProgress = nowMs() - progressTracker.lastProgressTime

        if (elapsedTimeSinceLastProgress > OFFLINE_GRACE_PERIOD_MS) {
          logger.debug(TAG, "Heartbeat check indicates live stream is offline and no activity for ${elapsedTimeSinceLastProgress}ms. Stopping stream.")
          shouldStop = true
          return
        }

        logger.debug(TAG, "Heartbeat check indicates live stream is offline, but progress was made ${elapsedTimeSinceLastProgress}ms ago. Continuing.")
      }
    } catch (error: Throwable) {
      logger.warn(TAG, "Heartbeat check failed:", errorMessage(error))
    }
  }

  private fun dispose() {
    sabrContextUpdates.clear()
    ssapPlaybackInfos.clear()
    activeSabrContextTypes.clear()
    segmentBuffer.reset()

    abortController = null
    nextRequestPolicy = null

    runtime.spsRejectCount = 0
    runtime.playerTimeMs = 0
    runtime.requestNumber = 0
    runtime.bandwidthEstimateBps = 0.0
    isMintingPoToken = false

    resetProgressTracker(0.0)
    clearRequestTimeout()
    setBusyState(false)
  }

  private fun getElapsedWallTimeMs(): Double {
    val playbackSessionStartMs = runtime.playbackSessionStartMs ?: return 0.0
    return nowMs() - playbackSessionStartMs
  }

  private fun checkForStall(stallDetectionMs: Long?) {
    if (isBroadcast && runtime.playerTimeMs == LIVE_EDGE_SENTINEL_MS) {
      return
    }

    val currentTime = nowMs()
    val stallThreshold = stallDetectionMs ?: DEFAULT_STALL_DETECTION_MS

    if (currentTime - progressTracker.lastProgressTime > stallThreshold.toDouble()) {
      progressTracker.stallCount += 1

      logger.warn(TAG, "Stream stalled for ${stallThreshold}ms (stall #${progressTracker.stallCount})")

      if (progressTracker.stallCount >= MAX_STALLS) {
        if (isBroadcast) {
          logger.warn(TAG, "Live stream stalled. Assuming end of stream and stopping download")
          shouldStop = true
        } else {
          throw GoogleVideoError("Stream stalled $MAX_STALLS times. Aborting")
        }
      }

      progressTracker.lastProgressTime = currentTime
    }
  }

  private suspend fun executeWithRetry(
    fetchFn: suspend () -> Unit,
    maxRetries: Int,
  ): Boolean {
    val backoffTimeMs = ((nextRequestPolicy?.backoffTimeMs ?: 0).toDouble() - (nowMs() - nextRequestPolicyReceivedMs)).toLong()

    if (backoffTimeMs > 0) {
      logger.debug(TAG, "Backing off for ${backoffTimeMs}ms before next request")
      wait(backoffTimeMs)
    }

    val epoch = currentSeekEpoch

    for (attempt in 1..(maxRetries + 1)) {
      if (lifecycle.aborted) {
        logger.debug(TAG, "Abort requested, preventing new requests")
        return false
      }

      if (currentSeekEpoch != epoch) {
        return true
      }

      try {
        setBusyState(true)
        fetchFn()
        setBusyState(false)
        return true
      } catch (error: Throwable) {
        setBusyState(false)

        if (lifecycle.aborted) {
          logger.debug(TAG, "Abort requested, not retrying fetch")
          return false
        }

        if (currentSeekEpoch != epoch) {
          return true
        }

        if (attempt > maxRetries) {
          logger.warn(TAG, "Retries exhausted while fetching segment: ${errorMessage(error)}")
          errorHandler(error)
          break
        }

        val retryBackoffMs = min(INITIAL_RETRY_BACKOFF_MS * 2.0.pow(attempt - 1).toLong(), MAX_RETRY_BACKOFF_MS)
        logger.warn(TAG, "Segment fetch attempt $attempt/$maxRetries failed - retrying in ${retryBackoffMs}ms", error)
        wait(retryBackoffMs)
      }
    }

    return false
  }

  private fun setBusyState(newState: Boolean) {
    val resolvers = synchronized(stateLock) {
      lifecycle.busy = newState
      if (!newState) {
        val resolvers = idleResolvers.toList()
        idleResolvers.clear()
        resolvers
      } else {
        emptyList()
      }
    }
    resolvers.forEach { it() }
  }

  private fun errorHandler(err: Throwable) {
    lifecycle.errored = true
    trackCollection.error(err)
    emit(SabrStreamEvent.error, err)
  }

  private suspend fun fetchAndProcess(
    abrState: ClientAbrState,
    selectedAudioFormat: SabrFormat?,
    selectedVideoFormat: SabrFormat?,
  ) {
    val requestPoTokenGeneration = runtime.poTokenGenerationId
    val epoch = currentSeekEpoch

    val requestBody = buildRequestBody(abrState, selectedAudioFormat, selectedVideoFormat)
    val startTime = nowMs()
    val fetched = makeStreamingRequest(requestBody)
    val response = fetched.response
    val contentType = response.value(forHTTPHeaderField = "content-type")

    val expired = if (response.statusCode == 403) hasExpired() else false
    if (expired) {
      fetched.cancel()
      tryReloadStreamingData()
    }

    if (response.statusCode !in 200 until 300 || contentType != "application/vnd.yt-ump") {
      fetched.cancel()
      assert(response.statusCode in 200 until 300, "Server returned ${response.statusCode}")
      throw GoogleVideoError("Unexpected content type from server: ${contentType ?: "null"}")
    }

    var serverSeek = false
    var bytesDownloaded = 0L

    val umpReader = UmpReader(
      UmpReaderCallbacks(onPart = onPart@{ type, data ->
        if (currentSeekEpoch != epoch) throw CancellationException()
        when (UMPPartId.forNumber(type)) {
          UMPPartId.SABR_ERROR -> {
            val sabrError = decodePart(data.chunks, SabrError.parser()) ?: return@onPart
            throw GoogleVideoError("SABR Error: ${sabrError.type} - ${sabrError.code}")
          }

          UMPPartId.FORMAT_INITIALIZATION_METADATA -> {
            val formatInitializationMetadata = decodePart(data.chunks, FormatInitializationMetadata.parser()) ?: return@onPart

            if (videoId != formatInitializationMetadata.videoId) {
              logger.warn(TAG, "Video ID mismatch: expected ${videoId ?: "nil"}, got ${formatInitializationMetadata.videoId}. Ignoring format initialization metadata.")
              return@onPart
            }

            if (!trackCollection.initializedTracksMap.has(createFormatKey(formatInitializationMetadata))) {
              val formatType = getMediaType(formatInitializationMetadata.mimeType)
              val selectedFormat = if (formatType == MediaType.VIDEO) selectedVideoFormat else selectedAudioFormat

              trackCollection.initialize(
                formatType,
                TrackState(
                  formatId = formatInitializationMetadata.formatId,
                  mimeType = formatInitializationMetadata.mimeType,
                  endSegmentNum = formatInitializationMetadata.endSegmentNum.toInt(),
                  endTimeTicks = formatInitializationMetadata.endTimeTicks,
                  endTimescale = if (formatInitializationMetadata.endTimeTimescale != 0L) formatInitializationMetadata.endTimeTimescale else 1000,
                  targetDurationSec = selectedFormat?.targetDurationSec,
                ),
              )

              logger.debug(TAG, "Initialized format: itag=${formatInitializationMetadata.formatId.itag}, mimeType=${formatInitializationMetadata.mimeType}")

              emit(SabrStreamEvent.formatInitialization, trackCollection.track(formatType))
            }
          }

          UMPPartId.MEDIA_HEADER -> {
            val mediaHeader = decodePart(data.chunks, MediaHeader.parser()) ?: return@onPart

            if (videoId != mediaHeader.videoId) {
              logger.warn(TAG, "Video ID mismatch: expected ${videoId ?: "nil"}, got ${mediaHeader.videoId}. Ignoring media header.")
              return@onPart
            }

            logger.debug(TAG, "Received media header: headerId=${mediaHeader.headerId}, itag=${mediaHeader.itag}, segmentNum=${mediaHeader.segmentNum}, startMs=${mediaHeader.startMs}, durationMs=${mediaHeader.durationMs}, segmentLengthBytes=${mediaHeader.segmentLengthBytes}")
            segmentBuffer.queueMediaHeader(mediaHeader)
          }

          UMPPartId.MEDIA -> {
            val headerId = data.getUint8(0)
            val dataBuffer = data.split(1).remainingBuffer
            segmentBuffer.appendMediaData(headerId, dataBuffer)
          }

          UMPPartId.MEDIA_END -> {
            val headerId = data.getUint8(0)
            if (segmentBuffer.finalizeSegment(headerId)) {
              recordProgress(trackCollection.buffered)
              logger.debug(TAG, "Finalized segment: headerId=$headerId")
              emit(SabrStreamEvent.trackStateUpdate, trackCollection)
            }
          }

          UMPPartId.LIVE_METADATA -> {
            val sabrLiveMetadata = decodePart(data.chunks, SabrLiveMetadata.parser()) ?: return@onPart

            if (sabrLiveMetadata.hasBroadcastId() && sabrLiveMetadata.broadcastId.isNotEmpty()) {
              validateBroadcastId(sabrLiveMetadata.broadcastId)
            }

            emit(SabrStreamEvent.liveMetadataUpdate, sabrLiveMetadata)
          }

          UMPPartId.SABR_SEEK -> {
            val sabrSeek = decodePart(data.chunks, SabrSeek.parser()) ?: return@onPart

            if (sabrSeek.seekSource == SeekSource.SEEK_SOURCE_SABR_SEEK_TO_HEAD) {
              val seekTimeMs = ticksToMs(sabrSeek.seekMediaTime, if (sabrSeek.seekMediaTimescale != 0) sabrSeek.seekMediaTimescale.toLong() else 1000, ::floor)
              seekTo(seekTimeMs, SeekOrigin.SERVER)
              resetProgressTracker(seekTimeMs.toDouble())
              ssapPlaybackInfos.clear()
              serverSeek = true
            }
          }

          UMPPartId.CUEPOINT_LIST -> {
            val cuepointList = decodePart(data.chunks, CuepointList.parser()) ?: return@onPart

            for (info in cuepointList.ssapInfosList) {
              val cuepointId = info.cuepoint.identifier

              if (!info.hasCuepoint() || !info.hasTimeRange()) {
                continue
              }

              val cuepoint = info.cuepoint
              val timeRange = info.timeRange

              if (cuepoint.event == CuepointEvent.STOP) {
                ssapPlaybackInfos.remove(cuepointId)
                logger.debug(TAG, "Removed cuepoint: identifier=$cuepointId")
              } else {
                if (ssapPlaybackInfos.has(cuepointId)) {
                  continue
                }

                val timescale = if (timeRange.timescale != 0) timeRange.timescale.toLong() else 1000
                val startTicks = timeRange.startTicks
                val startTimeMs = floor(ticksToMs(startTicks, timescale, ::floor).toDouble() - (cuepoint.playheadTimeSec * 1000)).toLong()
                val durationMs = (cuepoint.totalDurationSec * 1000).toLong()

                val playbackInfo = SsapPlaybackInfo.newBuilder()
                  .setCuepointId(cuepointId)
                  .setStartTimeMs(startTimeMs)
                  .setDurationMs(durationMs)
                  .setState(AdState.RATECONTROL_CLIENT)
                  .build()
                ssapPlaybackInfos[cuepointId] = playbackInfo

                logger.debug(TAG, "Added new cuepoint: cuepointId=$cuepointId, startTimeMs=$startTimeMs, durationMs=$durationMs")
              }
            }
          }

          UMPPartId.SABR_CONTEXT_UPDATE -> {
            val contextUpdate = decodePart(data.chunks, SabrContextUpdate.parser()) ?: return@onPart
            if (!contextUpdate.hasType() || !contextUpdate.hasValue() || contextUpdate.value.isEmpty) return@onPart

            val contextType = contextUpdate.type

            if (contextUpdate.writePolicy == SabrContextWritePolicy.KEEP_EXISTING && sabrContextUpdates.has(contextType)) {
              return@onPart
            }

            sabrContextUpdates[contextType] = contextUpdate

            if (contextUpdate.sendByDefault) {
              activeSabrContextTypes.add(contextType)
            }
          }

          UMPPartId.SABR_CONTEXT_SENDING_POLICY -> {
            val contextSendingPolicy = decodePart(data.chunks, SabrContextSendingPolicy.parser()) ?: return@onPart

            for (startPolicy in contextSendingPolicy.startPolicyList) {
              if (!activeSabrContextTypes.contains(startPolicy)) {
                activeSabrContextTypes.add(startPolicy)
                logger.debug(TAG, "Activated SABR context: type=$startPolicy")
              }
            }

            for (stopPolicy in contextSendingPolicy.stopPolicyList) {
              if (activeSabrContextTypes.contains(stopPolicy)) {
                activeSabrContextTypes.remove(stopPolicy)
                logger.debug(TAG, "Deactivated SABR context: type=$stopPolicy")
              }
            }

            for (discardPolicy in contextSendingPolicy.discardPolicyList) {
              if (sabrContextUpdates.has(discardPolicy)) {
                sabrContextUpdates.remove(discardPolicy)
                logger.debug(TAG, "Discarded SABR context: type=$discardPolicy")
              }
            }
          }

          UMPPartId.NEXT_REQUEST_POLICY -> {
            nextRequestPolicy = decodePart(data.chunks, NextRequestPolicy.parser())
            nextRequestPolicyReceivedMs = nowMs()
          }

          UMPPartId.STREAM_PROTECTION_STATUS -> {
            val streamProtectionStatus = decodePart(data.chunks, StreamProtectionStatus.parser()) ?: return@onPart
            if (streamProtectionStatus.status == 0) return@onPart

            emit(SabrStreamEvent.streamProtectionStatusUpdate, streamProtectionStatus)

            if (requestPoTokenGeneration != runtime.poTokenGenerationId) {
              return@onPart
            }

            val isRejected = streamProtectionStatus.status == 3
            val isPending = streamProtectionStatus.status == 2
            val maxRetries = if (streamProtectionStatus.maxRetries != 0) streamProtectionStatus.maxRetries else 5
            val spsRejectCount = runtime.spsRejectCount

            assert(spsRejectCount < maxRetries, "Stream protection attestation rejected after $spsRejectCount attempts")

            if ((isRejected || isPending) && !isMintingPoToken) {
              logger.warn(
                TAG,
                if (isRejected) {
                  "Stream protection attestation rejected: attempt $spsRejectCount of $maxRetries"
                } else {
                  "Stream protection attestation pending"
                },
              )

              if (isRejected) {
                runtime.spsRejectCount += 1
              }

              tryMintPoToken()
            }
          }

          UMPPartId.SABR_REDIRECT -> {
            val sabrRedirect = decodePart(data.chunks, SabrRedirect.parser()) ?: return@onPart
            if (sabrRedirect.url.isEmpty()) return@onPart
            setStreamingURL(sabrRedirect.url)
            logger.debug(TAG, "Received SABR redirect: newUrl=${sabrRedirect.url}")
          }

          UMPPartId.RELOAD_PLAYER_RESPONSE -> {
            val reloadPlaybackContext = decodePart(data.chunks, ReloadPlaybackContext.parser()) ?: return@onPart
            logger.debug(TAG, "Reload requested: reloadPlaybackParams=${reloadPlaybackContext.reloadPlaybackParams}")
            tryReloadStreamingData(reloadPlaybackContext)
          }

          else -> Unit
        }
      }),
    )

    val abortController = this.abortController

    abortController?.onAbort(fetched.cancel)

    try {
      for (value in fetched.body) {
        waitForDrain()

        if (abortController?.aborted == true && !lifecycle.aborted) {
          throw GoogleVideoError("Request timed out")
        }

        if (lifecycle.aborted) {
          break
        }

        if (value.isNotEmpty()) {
          bytesDownloaded += value.size
          resetRequestTimeout()
          umpReader.feed(value)
        }
      }
    } catch (error: Throwable) {
      fetched.cancel()
      clearRequestTimeout()
      umpReader.dispose()
      if (abortController?.aborted == true && !lifecycle.aborted && currentSeekEpoch == epoch) {
        throw GoogleVideoError("Request timed out")
      }
      throw error
    }

    fetched.cancel()
    clearRequestTimeout()
    umpReader.dispose()

    val fetchDurationMs = nowMs() - startTime

    if (fetchDurationMs > MIN_FETCH_DURATION_FOR_BW_ESTIMATE_MS && bytesDownloaded > 0) {
      val currentBps = (bytesDownloaded * 8).toDouble() / (fetchDurationMs / 1000)
      val bandwidthEstimateBps = runtime.bandwidthEstimateBps
      runtime.bandwidthEstimateBps = if (bandwidthEstimateBps == 0.0) {
        currentBps
      } else {
        BANDWIDTH_EMA_PREVIOUS_WEIGHT * bandwidthEstimateBps + BANDWIDTH_EMA_CURRENT_WEIGHT * currentBps
      }
    }

    if (!serverSeek && currentSeekEpoch == epoch) {
      val buffered = trackCollection.buffered
      if (buffered != Double.POSITIVE_INFINITY) {
        seekTo(Math.round(buffered), SeekOrigin.CLIENT)
      }
    }
  }

  private fun tryMintPoToken() {
    val onMintPoToken = callbacks.onMintPoToken ?: return

    isMintingPoToken = true

    scope.launch {
      try {
        proofOfOriginToken = onMintPoToken()
        runtime.poTokenGenerationId += 1
      } catch (error: Throwable) {
        logger.warn(TAG, "An error occurred while minting proof of origin token: ${errorMessage(error)}")
      }
      isMintingPoToken = false
    }
  }

  private fun buildRequestBody(
    abrState: ClientAbrState,
    selectedAudioFormat: SabrFormat?,
    selectedVideoFormat: SabrFormat?,
  ): ByteArray {
    val ssapPlaybackInfos = ssapPlaybackInfos.values.toList()
    val videoPlaybackUstreamerConfig = base64ToU8(videoPlaybackUstreamerConfig)
    val bufferedRanges = trackCollection.bufferedRanges
    val nextRequestPolicy = nextRequestPolicy
    val playbackCookie = if (nextRequestPolicy?.hasPlaybackCookie() == true) nextRequestPolicy.playbackCookie.toByteString() else null
    val poToken = proofOfOriginToken

    val initializationFormatIds = if (!isBroadcast) trackCollection.initializationFormatIds else emptyList()
    val selectedAudioFormatIds = selectedAudioFormat?.let { listOf(FormatId(it)) } ?: emptyList()
    val selectedVideoFormatIds = selectedVideoFormat?.let { listOf(FormatId(it)) } ?: emptyList()

    val (sabrContexts, unsentSabrContexts) = prepareSabrContexts()

    val streamerContext = StreamerContext.newBuilder()
    streamerContext.setClientInfo(clientInfo)
    playbackCookie?.let { streamerContext.setPlaybackCookie(it) }
    streamerContext.addAllUnsentSabrContexts(unsentSabrContexts)
    streamerContext.addAllSabrContexts(sabrContexts)
    poToken?.let { streamerContext.setPoToken(ByteString.copyFrom(it)) }

    val request = VideoPlaybackAbrRequest.newBuilder()
    request.setClientAbrState(abrState)
    request.addAllBufferedRanges(bufferedRanges)
    request.addAllSsapPlaybackInfos(ssapPlaybackInfos)
    request.addAllInitializationFormatIds(initializationFormatIds)
    request.addAllSelectedAudioFormatIds(selectedAudioFormatIds)
    request.addAllSelectedVideoFormatIds(selectedVideoFormatIds)
    request.setVideoPlaybackUstreamerConfig(ByteString.copyFrom(videoPlaybackUstreamerConfig))
    request.setStreamerContext(streamerContext)

    return request.build().toByteArray()
  }

  private fun prepareSabrContexts(): Pair<List<SabrContext>, List<Int>> {
    val sabrContexts = mutableListOf<SabrContext>()
    val unsentSabrContexts = mutableListOf<Int>()

    for ((type, ctxUpdate) in sabrContextUpdates.entries) {
      if (activeSabrContextTypes.contains(type)) {
        sabrContexts.add(
          SabrContext.newBuilder()
            .setType(ctxUpdate.type)
            .setValue(ctxUpdate.value)
            .build(),
        )
      } else {
        unsentSabrContexts.add(type)
      }
    }

    return sabrContexts to unsentSabrContexts
  }

  private suspend fun makeStreamingRequest(body: ByteArray): FetchResponse {
    serverAbrStreamingUrl = streamingURL.settingSearchParam("rn", runtime.requestNumber.toString())
    val epoch = currentSeekEpoch
    val abortController = AbortController()
    this.abortController = abortController
    resetRequestTimeout()

    try {
      val request = FetchRequest(streamingURL, method = "POST", body = body)
      request.setValue("application/x-protobuf", forHTTPHeaderField = "content-type")
      request.setValue("identity", forHTTPHeaderField = "accept-encoding")
      request.setValue("application/vnd.yt-ump", forHTTPHeaderField = "accept")

      val fetchFunction = fetchFunction
      val task = scope.async { fetchFunction(request) }
      abortController.onAbort { task.cancel() }

      return task.await()
    } catch (error: Throwable) {
      clearRequestTimeout()

      if (lifecycle.aborted || currentSeekEpoch != epoch) throw error

      getNextFallbackUrl(streamingURL)?.let { nextFallbackUrl ->
        logger.warn(TAG, "Switching to fallback URL: ${nextFallbackUrl.urlHost ?: ""}")
        setStreamingURL(nextFallbackUrl)
      }

      throw error
    } finally {
      runtime.requestNumber += 1
    }
  }

  private fun hasExpired(): Boolean {
    val expireRawValue = streamingURL.searchParam("expire")
    if (expireRawValue.isNullOrEmpty()) return false

    val expireTimestampMs = (expireRawValue.toLongOrNull() ?: 0).toDouble() * 1000
    val msRemaining = expireTimestampMs - nowMs()

    return msRemaining <= 0
  }

  private suspend fun tryReloadStreamingData(reloadPlaybackContext: ReloadPlaybackContext? = null) {
    val onReloadPlayerResponseCb = callbacks.onReloadPlayerResponse
    if (onReloadPlayerResponseCb != null) {
      try {
        val response = onReloadPlayerResponseCb(reloadPlaybackContext)
        setStreamingURL(response.serverAbrStreamingUrl)
        setUstreamerConfig(response.videoPlaybackUstreamerConfig)

        sabrContextUpdates.clear()
        activeSabrContextTypes.clear()
        ssapPlaybackInfos.clear()
      } catch (error: Throwable) {
        throw GoogleVideoError("An error occurred while reloading streaming data: ${errorMessage(error)}")
      }
    } else {
      throw GoogleVideoError("Streaming data reload requested but no handler was found")
    }
  }

  private fun resetRequestTimeout() {
    clearRequestTimeout()
    val abortController = this.abortController
    requestTimeoutTask = scope.launch {
      wait(REQUEST_TIMEOUT_MS)
      abortController?.abort()
    }
  }

  private fun clearRequestTimeout() {
    requestTimeoutTask?.cancel()
    requestTimeoutTask = null
  }

  private fun recordProgress(progressMs: Double) {
    if (!progressMs.isFinite() || progressMs <= progressTracker.lastBufferedTimeMs) {
      return
    }

    progressTracker.lastProgressTime = nowMs()
    progressTracker.lastBufferedTimeMs = progressMs
    progressTracker.stallCount = 0
  }

  private fun seekTo(timeMs: Long, source: SeekOrigin) {
    logger.debug(TAG, "Seeking: timeMs=$timeMs, source=${source.rawValue}")
    runtime.playerTimeMs = timeMs
  }

  private fun resetProgressTracker(progressMs: Double) {
    progressTracker = ProgressTracker(
      lastProgressTime = nowMs(),
      lastBufferedTimeMs = progressMs,
      stallCount = 0,
    )
  }
}
