package com.margelo.nitro.everythingplayer.googlevideo.core

import com.google.protobuf.ByteString
import com.margelo.nitro.everythingplayer.googlevideo.protos.misc.FormatId
import com.margelo.nitro.everythingplayer.googlevideo.protos.video_streaming.BufferedRange
import com.margelo.nitro.everythingplayer.googlevideo.protos.video_streaming.ClientAbrState
import com.margelo.nitro.everythingplayer.googlevideo.protos.video_streaming.PlaybackCookie
import com.margelo.nitro.everythingplayer.googlevideo.protos.video_streaming.SabrContextUpdate
import com.margelo.nitro.everythingplayer.googlevideo.protos.video_streaming.StreamerContext
import com.margelo.nitro.everythingplayer.googlevideo.protos.video_streaming.TimeRange
import com.margelo.nitro.everythingplayer.googlevideo.protos.video_streaming.VideoPlaybackAbrRequest
import com.margelo.nitro.everythingplayer.googlevideo.types.ActiveTrackFormats
import com.margelo.nitro.everythingplayer.googlevideo.types.OnMintPoTokenCallback
import com.margelo.nitro.everythingplayer.googlevideo.types.OnReloadPlayerResponseCb
import com.margelo.nitro.everythingplayer.googlevideo.types.OnSnackbarMessageCb
import com.margelo.nitro.everythingplayer.googlevideo.types.PlayerHttpRequest
import com.margelo.nitro.everythingplayer.googlevideo.types.PlayerHttpResponse
import com.margelo.nitro.everythingplayer.googlevideo.types.SabrFormat
import com.margelo.nitro.everythingplayer.googlevideo.types.SabrOptions
import com.margelo.nitro.everythingplayer.googlevideo.types.SabrPlayerAdapter
import com.margelo.nitro.everythingplayer.googlevideo.types.SabrRequestMetadata
import com.margelo.nitro.everythingplayer.googlevideo.utils.ByteRange
import com.margelo.nitro.everythingplayer.googlevideo.utils.CacheManager
import com.margelo.nitro.everythingplayer.googlevideo.utils.EnabledTrackTypes
import com.margelo.nitro.everythingplayer.googlevideo.utils.Logger
import com.margelo.nitro.everythingplayer.googlevideo.utils.MAX_INT32_VALUE
import com.margelo.nitro.everythingplayer.googlevideo.utils.OrderedMap
import com.margelo.nitro.everythingplayer.googlevideo.utils.RequestMetadataManager
import com.margelo.nitro.everythingplayer.googlevideo.utils.SabrContext
import com.margelo.nitro.everythingplayer.googlevideo.utils.SabrContextWritePolicy
import com.margelo.nitro.everythingplayer.googlevideo.utils.base64ToU8
import com.margelo.nitro.everythingplayer.googlevideo.utils.createFormatKey
import com.margelo.nitro.everythingplayer.googlevideo.utils.has
import com.margelo.nitro.everythingplayer.googlevideo.utils.nowMs
import com.margelo.nitro.everythingplayer.googlevideo.utils.parseRangeHeader
import com.margelo.nitro.everythingplayer.googlevideo.utils.searchParam
import com.margelo.nitro.everythingplayer.googlevideo.utils.settingSearchParam
import com.margelo.nitro.everythingplayer.googlevideo.utils.wait
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import com.margelo.nitro.everythingplayer.googlevideo.utils.FormatId as formatIdOf

class SabrAdapterError(message: String, val code: String? = null) : GoogleVideoError("[SabrStreamingAdapter] $message")

private data class LastSegmentMetadata(
  var formatId: FormatId,
  var startSequenceNumber: Int,
  var endSequenceNumber: Int,
  var startTimeMs: Long,
  var durationMs: Long,
  var timescale: Int,
)

private data class InitializedFormat(
  var lastSegmentMetadata: LastSegmentMetadata? = null,
)

private const val TAG = "SabrStreamingAdapter"

object SABR_CONSTANTS {
  const val PROTOCOL = "sabr:"
  const val KEY_PARAM = "key"
  const val DEFAULT_ENABLE_CACHING = true
  const val DEFAULT_ENABLE_VERBOSE_REQUEST_LOGGING = false
  const val DEFAULT_MAX_CACHE_SIZE_MB = 3
  const val DEFAULT_MAX_CACHE_AGE_SECONDS = 300
}

private val BASIC_UMP_REQUEST_BODY = byteArrayOf(120, 0)

class SabrStreamingAdapter(options: SabrOptions) {
  private val playerAdapter: SabrPlayerAdapter
  private val requestMetadataManager: RequestMetadataManager
  private val initializedFormats = HashMap<String, InitializedFormat>()
  private val logger = Logger.getInstance()
  private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)

  private var options: SabrOptions?
  private var ustreamerConfig: String? = null
  private var serverAbrStreamingUrl: String? = null

  private var sabrFormats: List<SabrFormat> = emptyList()
  private val sabrContexts = OrderedMap<Int, SabrContextUpdate>()
  private val activeSabrContextTypes = LinkedHashSet<Int>()
  private var lastPlaybackCookie: PlaybackCookie? = null
  private var lastPlayerTimeSecs = 0.0
  private var cacheManager: CacheManager? = null
  private var requestNumber = 0

  @Volatile private var activeDelayPromise: Job? = null
  private var onReloadPlayerResponseCallback: OnReloadPlayerResponseCb? = null
  private var onSnackbarMessageCallback: OnSnackbarMessageCb? = null
  private var onMintPoTokenCallback: OnMintPoTokenCallback? = null

  var isDisposed = false

  fun onSnackbarMessage(cb: OnSnackbarMessageCb) {
    onSnackbarMessageCallback = cb
  }

  fun onReloadPlayerResponse(cb: OnReloadPlayerResponseCb) {
    onReloadPlayerResponseCallback = cb
  }

  fun onMintPoToken(cb: OnMintPoTokenCallback) {
    onMintPoTokenCallback = cb
  }

  init {
    val merged = options.copy(
      enableCaching = options.enableCaching ?: SABR_CONSTANTS.DEFAULT_ENABLE_CACHING,
      enableVerboseRequestLogging = options.enableVerboseRequestLogging ?: SABR_CONSTANTS.DEFAULT_ENABLE_VERBOSE_REQUEST_LOGGING,
      maxCacheSizeMB = options.maxCacheSizeMB ?: SABR_CONSTANTS.DEFAULT_MAX_CACHE_SIZE_MB,
      maxCacheAgeSeconds = options.maxCacheAgeSeconds ?: SABR_CONSTANTS.DEFAULT_MAX_CACHE_AGE_SECONDS,
    )
    this.options = merged

    playerAdapter = options.playerAdapter ?: throw SabrAdapterError("A player adapter is required.")

    if (merged.enableCaching == true) {
      cacheManager = CacheManager(
        merged.maxCacheSizeMB!!,
        merged.maxCacheAgeSeconds!!,
      )
    }

    requestMetadataManager = RequestMetadataManager()
  }

  fun attach(player: Any) {
    checkDisposed()
    playerAdapter.initialize(player, requestMetadataManager, cacheManager)
    setupInterceptors()
  }

  fun setStreamingURL(url: String? = null) {
    checkDisposed()
    serverAbrStreamingUrl = url
  }

  fun setUstreamerConfig(ustreamerConfig: String? = null) {
    checkDisposed()
    this.ustreamerConfig = ustreamerConfig
  }

  fun setServerAbrFormats(sabrFormats: List<SabrFormat>) {
    checkDisposed()
    this.sabrFormats = sabrFormats
  }

  fun getCacheManager(): CacheManager? = cacheManager

  private fun setupInterceptors() {
    playerAdapter.registerRequestInterceptor { request ->
      handleRequest(request)
    }
    playerAdapter.registerResponseInterceptor { response ->
      handleResponse(response)
    }
  }

  private suspend fun handleRequest(originalRequest: PlayerHttpRequest): PlayerHttpRequest {
    val request = originalRequest
    val originalUri = request.url
    val scheme = originalUri.substringBefore(':', "")

    if ("$scheme:" == SABR_CONSTANTS.PROTOCOL) {
      activeDelayPromise?.join()

      val serverAbrStreamingUrl = serverAbrStreamingUrl
      if (serverAbrStreamingUrl.isNullOrEmpty()) {
        throw SabrAdapterError("Server ABR URL not set.")
      }

      if (sabrFormats.isEmpty()) {
        throw SabrAdapterError("No SABR formats available.")
      }

      val requestNumber = this.requestNumber.toString()
      this.requestNumber += 1

      request.url = serverAbrStreamingUrl.settingSearchParam("rn", requestNumber)

      val keyParam = originalUri.searchParam(SABR_CONSTANTS.KEY_PARAM) ?: ""
      val currentFormat = sabrFormats.firstOrNull { createFormatKey(it) == keyParam }
        ?: throw SabrAdapterError("Could not determine current format from URL: ${request.url}")

      if (playerAdapter.getPlayerTime() < lastPlayerTimeSecs) {
        initializedFormats.clear()
      }

      val activeFormats = playerAdapter.getActiveTrackFormats(currentFormat, sabrFormats)
      val videoPlaybackAbrRequest = createVideoPlaybackAbrRequest(request, currentFormat, activeFormats)

      val height = currentFormat.height
      if (height != null && height != 0) {
        videoPlaybackAbrRequest.setClientAbrState(
          videoPlaybackAbrRequest.clientAbrState.toBuilder()
            .setStickyResolution(height)
            .setLastManualSelectedResolution(height),
        )
      }

      val formatToDiscard = addBufferingInfoToAbrRequest(videoPlaybackAbrRequest, currentFormat, activeFormats)

      if (formatToDiscard != null) {
        videoPlaybackAbrRequest.addInitializationFormatIds(formatIdOf(formatToDiscard))
      }

      if (!request.segment.isInit()) {
        videoPlaybackAbrRequest.addInitializationFormatIds(formatIdOf(currentFormat))
      }

      if (options?.enableVerboseRequestLogging == true) {
        logger.debug(TAG, "Created VideoPlaybackAbrRequest ($requestNumber):", videoPlaybackAbrRequest.build())
      }

      request.body = videoPlaybackAbrRequest.build().toByteArray()

      requestMetadataManager.metadataMap[requestNumber] = SabrRequestMetadata(
        byteRange = parseRangeHeader(request.headers["Range"]),
        format = currentFormat,
        isInit = request.segment.isInit(),
        isUMP = true,
        isSABR = true,
        timestamp = nowMs(),
      )
    } else {
      val webPoToken = onMintPoTokenCallback?.invoke()
      val rangeValue = request.headers["Range"]?.split("=")?.drop(1)?.firstOrNull()

      val head = originalUri.substringBefore('?').substringBefore('#')
      val path = head.substringAfter("://", head).let { rest -> rest.indexOf('/').let { if (it >= 0) rest.substring(it) else "" } }

      var url = if (path.contains("videoplayback/expire") || path.contains("source/yt_live_broadcast")) {
        var newPath = path
        newPath += "/ump/1"
        newPath += "/srfvp/1"
        newPath += "/alr/yes"
        if (!webPoToken.isNullOrEmpty()) {
          newPath += "/pot/$webPoToken"
        }
        if (rangeValue != null) {
          newPath += "/range/$rangeValue"
        }
        head.removeSuffix(path) + newPath + originalUri.substring(head.length)
      } else {
        var url = originalUri
        url = url.settingSearchParam("ump", "1")
        url = url.settingSearchParam("srfvp", "1")
        url = url.settingSearchParam("alr", "yes")
        if (!webPoToken.isNullOrEmpty()) {
          url = url.settingSearchParam("pot", webPoToken)
        }
        if (rangeValue != null) {
          url = url.settingSearchParam("range", rangeValue)
        }
        url
      }

      val requestNumber = this.requestNumber.toString()
      this.requestNumber += 1
      url = url.settingSearchParam("rn", requestNumber)
      request.url = url
      request.body = BASIC_UMP_REQUEST_BODY

      requestMetadataManager.metadataMap[requestNumber] = SabrRequestMetadata(
        isUMP = true,
        isSABR = false,
        timestamp = nowMs(),
      )
    }

    request.method = "POST"

    request.headers.remove("Range")

    return request
  }

  private suspend fun createVideoPlaybackAbrRequest(
    request: PlayerHttpRequest,
    currentFormat: SabrFormat,
    activeFormats: ActiveTrackFormats,
  ): VideoPlaybackAbrRequest.Builder {
    val ustreamerConfig = ustreamerConfig
    if (ustreamerConfig.isNullOrEmpty()) {
      throw SabrAdapterError("Ustreamer config not set")
    }

    val streamerContext = StreamerContext.newBuilder()
    onMintPoTokenCallback?.let { streamerContext.setPoToken(ByteString.copyFrom(base64ToU8(it()))) }
    lastPlaybackCookie?.let { streamerContext.setPlaybackCookie(it.toByteString()) }
    options?.clientInfo?.let { streamerContext.setClientInfo(it) }

    for (ctxUpdate in sabrContexts.values) {
      if (activeSabrContextTypes.contains(ctxUpdate.type)) {
        streamerContext.addSabrContexts(
          SabrContext.newBuilder()
            .setType(ctxUpdate.type)
            .setValue(ctxUpdate.value),
        )
      } else {
        streamerContext.addUnsentSabrContexts(ctxUpdate.type)
      }
    }

    lastPlayerTimeSecs = playerAdapter.getPlayerTime()

    val clientAbrState = ClientAbrState.newBuilder()
    clientAbrState.setPlaybackRate(playerAdapter.getPlaybackRate().toFloat())
    clientAbrState.setPlayerTimeMs(Math.round((request.segment.getStartTime() ?: lastPlayerTimeSecs) * 1000))
    clientAbrState.setClientViewportIsFlexible(false)
    clientAbrState.setBandwidthEstimate(Math.round(playerAdapter.getBandwidthEstimate()))
    clientAbrState.setDrcEnabled(currentFormat.isDrc ?: false)
    clientAbrState.setEnabledTrackTypesBitfield(if ((currentFormat.width ?: 0) != 0) EnabledTrackTypes.VIDEO_ONLY.rawValue else EnabledTrackTypes.AUDIO_ONLY.rawValue)
    currentFormat.audioTrackId?.let { clientAbrState.setAudioTrackId(it) }

    val videoPlaybackAbrRequest = VideoPlaybackAbrRequest.newBuilder()
    videoPlaybackAbrRequest.setClientAbrState(clientAbrState)
    videoPlaybackAbrRequest.addSelectedAudioFormatIds(activeFormats.audioFormat?.let { formatIdOf(it) } ?: FormatId.getDefaultInstance())
    videoPlaybackAbrRequest.addSelectedVideoFormatIds(activeFormats.videoFormat?.let { formatIdOf(it) } ?: FormatId.getDefaultInstance())
    videoPlaybackAbrRequest.setVideoPlaybackUstreamerConfig(ByteString.copyFrom(base64ToU8(ustreamerConfig)))
    videoPlaybackAbrRequest.setStreamerContext(streamerContext)

    return videoPlaybackAbrRequest
  }

  private fun addBufferingInfoToAbrRequest(
    videoPlaybackAbrRequest: VideoPlaybackAbrRequest.Builder,
    currentFormat: SabrFormat,
    activeFormats: ActiveTrackFormats,
  ): SabrFormat? {
    var formatToDiscard: SabrFormat? = null

    val currentFormatKey = createFormatKey(currentFormat)

    for (activeFormat in listOf(activeFormats.audioFormat, activeFormats.videoFormat)) {
      if (activeFormat == null) continue

      val activeFormatKey = createFormatKey(activeFormat)
      val shouldDiscard = currentFormatKey != activeFormatKey
      val initializedFormat = initializedFormats[activeFormatKey]

      val bufferedRange = if (shouldDiscard) {
        createFullBufferRange(activeFormat)
      } else {
        createPartialBufferRange(initializedFormat)
      }

      if (bufferedRange != null) {
        videoPlaybackAbrRequest.addBufferedRanges(bufferedRange)

        if (shouldDiscard) {
          formatToDiscard = activeFormat
        }
      }
    }

    return formatToDiscard
  }

  private fun createFullBufferRange(format: SabrFormat): BufferedRange =
    BufferedRange.newBuilder()
      .setFormatId(formatIdOf(format))
      .setDurationMs(MAX_INT32_VALUE.toLong())
      .setStartTimeMs(0)
      .setStartSegmentIndex(MAX_INT32_VALUE.toInt())
      .setEndSegmentIndex(MAX_INT32_VALUE.toInt())
      .setTimeRange(
        TimeRange.newBuilder()
          .setDurationTicks(MAX_INT32_VALUE.toLong())
          .setStartTicks(0)
          .setTimescale(1000),
      )
      .build()

  private fun createPartialBufferRange(initializedFormat: InitializedFormat?): BufferedRange? {
    val metadata = initializedFormat?.lastSegmentMetadata ?: return null

    return BufferedRange.newBuilder()
      .setFormatId(metadata.formatId)
      .setStartSegmentIndex(metadata.startSequenceNumber)
      .setDurationMs(metadata.durationMs)
      .setStartTimeMs(0)
      .setEndSegmentIndex(metadata.endSequenceNumber)
      .setTimeRange(
        TimeRange.newBuilder()
          .setTimescale(metadata.timescale)
          .setStartTicks(0)
          .setDurationTicks(metadata.durationMs),
      )
      .build()
  }

  private suspend fun handleResponse(response: PlayerHttpResponse): PlayerHttpResponse? {
    val requestMetadata = requestMetadataManager.getRequestMetadata(response.url, true) ?: return response

    val streamInfo = requestMetadata.streamInfo ?: return response
    val format = requestMetadata.format
    val byteRange = requestMetadata.byteRange
    val isSABR = requestMetadata.isSABR

    val retry: suspend () -> PlayerHttpResponse = {
      val formatType = if ((format?.width ?: 0) != 0) "video" else "audio"
      val formatKey = createFormatKey(format!!)
      val url = "${SABR_CONSTANTS.PROTOCOL}//$formatType?${SABR_CONSTANTS.KEY_PARAM}=$formatKey"
      makeFollowupRequest(response, url, isSABR, byteRange)
    }

    streamInfo.snackbarMessage?.let { snackbarMessage ->
      logger.debug(TAG, "Received snackbar message:", snackbarMessage)
      onSnackbarMessageCallback?.invoke(snackbarMessage)
    }

    val redirect = streamInfo.redirect
    if (redirect != null && redirect.url.isNotEmpty()) {
      var redirectUrl = redirect.url

      logger.info(TAG, "Redirecting to $redirectUrl")

      if (isSABR == true) {
        serverAbrStreamingUrl = redirect.url
        val formatType = if ((format?.width ?: 0) != 0) "video" else "audio"
        val formatKey = createFormatKey(format!!)
        redirectUrl = "${SABR_CONSTANTS.PROTOCOL}//$formatType?${SABR_CONSTANTS.KEY_PARAM}=$formatKey"
      }

      if ((response.data?.size ?: 0) == 0) {
        return makeFollowupRequest(response, redirectUrl, isSABR, byteRange)
      }
    }

    val nextRequestPolicy = streamInfo.nextRequestPolicy
    if (nextRequestPolicy != null) {
      lastPlaybackCookie = nextRequestPolicy.playbackCookie
      val delayMs = nextRequestPolicy.backoffTimeMs.toLong()

      if (delayMs > 0 && activeDelayPromise == null) {
        logger.info(TAG, "Delaying next requests by ${delayMs.toDouble() / 1000} seconds.")
        activeDelayPromise = scope.launch {
          wait(delayMs)
          logger.info(TAG, "Delay completed, resuming requests.")
          activeDelayPromise = null
        }
      }
    }

    val sabrContextSendingPolicy = streamInfo.sabrContextSendingPolicy
    if (sabrContextSendingPolicy != null) {
      for (startPolicy in sabrContextSendingPolicy.startPolicyList) {
        if (!activeSabrContextTypes.contains(startPolicy)) {
          activeSabrContextTypes.add(startPolicy)
          logger.debug(TAG, "Activated SABR context for type $startPolicy")
        }
      }

      for (stopPolicy in sabrContextSendingPolicy.stopPolicyList) {
        if (activeSabrContextTypes.contains(stopPolicy)) {
          activeSabrContextTypes.remove(stopPolicy)
          logger.debug(TAG, "Deactivated SABR context for type $stopPolicy")
        }
      }

      for (discardPolicy in sabrContextSendingPolicy.discardPolicyList) {
        if (sabrContexts.has(discardPolicy)) {
          sabrContexts.remove(discardPolicy)
          logger.debug(TAG, "Discarded SABR context for type $discardPolicy")
        }
      }
    }

    val sabrContextUpdate = streamInfo.sabrContextUpdate
    if (sabrContextUpdate != null && sabrContextUpdate.hasType() && sabrContextUpdate.hasValue() && !sabrContextUpdate.value.isEmpty) {
      val contextType = sabrContextUpdate.type

      if (!sabrContexts.has(contextType) || sabrContextUpdate.writePolicy == SabrContextWritePolicy.OVERWRITE) {
        logger.debug(TAG, "Received SABR context update (type: ${sabrContextUpdate.type}, writePolicy: ${sabrContextUpdate.writePolicy} sendByDefault: ${sabrContextUpdate.sendByDefault})")
        sabrContexts[contextType] = sabrContextUpdate
      }

      if (sabrContextUpdate.sendByDefault) {
        activeSabrContextTypes.add(contextType)
      }

      if ((response.data?.size ?: 0) == 0) {
        return retry()
      }
    }

    val reloadPlaybackContext = streamInfo.reloadPlaybackContext
    val onReloadPlayerResponseCallback = onReloadPlayerResponseCallback
    if (reloadPlaybackContext != null && onReloadPlayerResponseCallback != null) {
      logger.info(TAG, "Server requested player reload with new parameters:", reloadPlaybackContext)
      onReloadPlayerResponseCallback(reloadPlaybackContext)
      return retry()
    }

    val mediaHeader = streamInfo.mediaHeader
    if (mediaHeader != null) {
      val formatKey = createFormatKey(mediaHeader)

      if (mediaHeader.isInitializationSegment) {
        return null
      }

      val initializedFormat = initializedFormats[formatKey] ?: InitializedFormat()

      val segmentNum = mediaHeader.segmentNum

      initializedFormat.lastSegmentMetadata = LastSegmentMetadata(
        formatId = mediaHeader.formatId,
        startSequenceNumber = if (segmentNum != 0) segmentNum else 1,
        endSequenceNumber = if (segmentNum != 0) segmentNum else 1,
        startTimeMs = mediaHeader.startMs,
        durationMs = mediaHeader.durationMs,
        timescale = if (mediaHeader.timeRange.timescale != 0) mediaHeader.timeRange.timescale else 1000,
      )

      initializedFormats[formatKey] = initializedFormat
    }

    return response
  }

  private suspend fun makeFollowupRequest(
    originalResponse: PlayerHttpResponse,
    url: String,
    isSABR: Boolean? = null,
    byteRange: ByteRange? = null,
  ): PlayerHttpResponse {
    activeDelayPromise?.join()

    val headers = LinkedHashMap<String, String>()

    if (isSABR == true && byteRange != null) {
      headers["Range"] = "bytes=${byteRange.start}-${byteRange.end}"
    }

    val response = originalResponse
    val redirectResponse = originalResponse.makeRequest(url, headers)
    response.url = redirectResponse.url
    response.method = redirectResponse.method
    response.headers = redirectResponse.headers
    response.data = redirectResponse.data

    return response
  }

  private fun checkDisposed() {
    if (isDisposed) {
      throw SabrAdapterError("Adapter has been disposed.")
    }
  }

  fun dispose() {
    if (isDisposed) return

    cacheManager?.dispose()
    cacheManager = null

    initializedFormats.clear()
    requestMetadataManager.metadataMap.clear()
    sabrContexts.clear()
    activeSabrContextTypes.clear()

    lastPlaybackCookie = null
    lastPlayerTimeSecs = 0.0
    sabrFormats = emptyList()
    serverAbrStreamingUrl = null
    ustreamerConfig = null
    activeDelayPromise = null
    playerAdapter.dispose()
    requestNumber = 0

    onReloadPlayerResponseCallback = null
    onSnackbarMessageCallback = null
    onMintPoTokenCallback = null

    options = null
    isDisposed = true

    logger.debug(TAG, "Disposed")
  }
}
