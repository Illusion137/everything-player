package com.margelo.nitro.everythingplayer.googlevideo.types

import com.margelo.nitro.everythingplayer.googlevideo.protos.video_streaming.FormatInitializationMetadata
import com.margelo.nitro.everythingplayer.googlevideo.protos.video_streaming.MediaHeader
import com.margelo.nitro.everythingplayer.googlevideo.protos.video_streaming.NextRequestPolicy
import com.margelo.nitro.everythingplayer.googlevideo.protos.video_streaming.PlaybackCookie
import com.margelo.nitro.everythingplayer.googlevideo.protos.video_streaming.ReloadPlaybackContext
import com.margelo.nitro.everythingplayer.googlevideo.protos.video_streaming.SabrContextSendingPolicy
import com.margelo.nitro.everythingplayer.googlevideo.protos.video_streaming.SabrContextUpdate
import com.margelo.nitro.everythingplayer.googlevideo.protos.video_streaming.SabrError
import com.margelo.nitro.everythingplayer.googlevideo.protos.video_streaming.SabrRedirect
import com.margelo.nitro.everythingplayer.googlevideo.protos.video_streaming.SnackbarMessage
import com.margelo.nitro.everythingplayer.googlevideo.protos.video_streaming.StreamProtectionStatus
import com.margelo.nitro.everythingplayer.googlevideo.utils.ByteRange
import com.margelo.nitro.everythingplayer.googlevideo.utils.CacheManager
import com.margelo.nitro.everythingplayer.googlevideo.utils.ClientInfo
import com.margelo.nitro.everythingplayer.googlevideo.utils.RequestMetadataManager

data class SabrRequestStreamInfo(
  var playbackCookie: PlaybackCookie? = null,
  var nextRequestPolicy: NextRequestPolicy? = null,
  var formatInitMetadata: List<FormatInitializationMetadata>? = null,
  var streamProtectionStatus: StreamProtectionStatus? = null,
  var reloadPlaybackContext: ReloadPlaybackContext? = null,
  var sabrContextSendingPolicy: SabrContextSendingPolicy? = null,
  var sabrContextUpdate: SabrContextUpdate? = null,
  var snackbarMessage: SnackbarMessage? = null,
  var mediaHeader: MediaHeader? = null,
  var redirect: SabrRedirect? = null,
)

data class SabrRequestError(
  var sabrError: SabrError? = null,
)

class SabrRequestMetadata(
  var byteRange: ByteRange? = null,
  var format: SabrFormat? = null,
  var isInit: Boolean? = null,
  var isUMP: Boolean? = null,
  var isSABR: Boolean? = null,
  var streamInfo: SabrRequestStreamInfo? = null,
  var error: SabrRequestError? = null,
  var timestamp: Double,
)

typealias OnSnackbarMessageCb = (SnackbarMessage) -> Unit
typealias OnReloadPlayerResponseCb = suspend (ReloadPlaybackContext) -> Unit
typealias OnMintPoTokenCallback = suspend () -> String

data class SabrOptions(
  var enableCaching: Boolean? = null,
  var enableVerboseRequestLogging: Boolean? = null,
  var maxCacheSizeMB: Int? = null,
  var maxCacheAgeSeconds: Int? = null,
  var playerAdapter: SabrPlayerAdapter? = null,
  var clientInfo: ClientInfo? = null,
)

class PlayerHttpResponse(
  var url: String,
  var method: String,
  var headers: Map<String, String>,
  var data: ByteArray? = null,
  var makeRequest: suspend (String, Map<String, String>) -> PlayerHttpResponse,
)

class PlayerHttpRequest(
  var url: String,
  var method: String,
  var headers: MutableMap<String, String>,
  var segment: RequestSegment,
  var body: ByteArray? = null,
)

class RequestSegment(
  var getStartTime: () -> Double?,
  var isInit: () -> Boolean,
)

typealias RequestFilter = suspend (PlayerHttpRequest) -> PlayerHttpRequest?
typealias ResponseFilter = suspend (PlayerHttpResponse) -> PlayerHttpResponse?

data class ActiveTrackFormats(
  var audioFormat: SabrFormat? = null,
  var videoFormat: SabrFormat? = null,
)

interface SabrPlayerAdapter {
  fun initialize(
    player: Any,
    requestMetadataManager: RequestMetadataManager,
    cache: CacheManager?,
  )
  fun getPlayerTime(): Double
  fun getPlaybackRate(): Double
  fun getBandwidthEstimate(): Double
  fun getActiveTrackFormats(activeFormat: SabrFormat, sabrFormats: List<SabrFormat>): ActiveTrackFormats
  fun registerRequestInterceptor(interceptor: RequestFilter)
  fun registerResponseInterceptor(interceptor: ResponseFilter)
  fun dispose()
}
