package com.margelo.nitro.everythingplayer.engine

import android.net.Uri

enum class EPSourceType { RAW, HLS, SABR }

enum class EPState { NONE, READY, PLAYING, PAUSED, STOPPED, BUFFERING, LOADING, ERROR, ENDED }

enum class EPRepeatMode { OFF, TRACK, QUEUE }

enum class EPErrorCode(val code: String) {
  SABR_CALLBACK_FAILED("sabr-callback-failed"),
  SABR_UNSUPPORTED("sabr-unsupported"),
  SABR_STREAM_FAILED("sabr-stream-failed"),
  SOURCE_ERROR("source-error"),
  NETWORK_ERROR("network-error"),
  DECODE_ERROR("decode-error"),
  UNKNOWN("unknown"),
}

class EPError(val errorCode: EPErrorCode, override val message: String, var trackId: String? = null) : Exception(message)

data class EPSabrFormat(
  val itag: Int,
  val lastModified: String,
  val xtags: String? = null,
  val mimeType: String? = null,
  val bitrate: Int,
  val averageBitrate: Int? = null,
  val approxDurationMs: Long,
  val contentLength: Long? = null,
  val width: Int? = null,
  val height: Int? = null,
  val fps: Int? = null,
  val quality: String? = null,
  val qualityLabel: String? = null,
  val audioQuality: String? = null,
  val audioSampleRate: Int? = null,
  val audioChannels: Int? = null,
  val audioTrackId: String? = null,
  val language: String? = null,
  val isDrc: Boolean? = null,
  val isVb: Boolean? = null,
  val isSr: Boolean? = null,
  val isHdr: Boolean? = null,
  val isDubbed: Boolean? = null,
  val isAutoDubbed: Boolean? = null,
  val isDescriptive: Boolean? = null,
  val isSecondary: Boolean? = null,
  val isOriginal: Boolean? = null,
)

data class EPSabrInfo(
  val videoId: String,
  val serverAbrStreamingUrl: String,
  val videoPlaybackUstreamerConfig: String,
  val formats: List<EPSabrFormat>,
  val poToken: String,
  val clientName: Int,
  val clientVersion: String,
  val cookie: String?,
  val duration: Double,
)

data class EPTrack(
  val id: String,
  var title: String,
  var artist: String,
  var album: String? = null,
  var artwork: String? = null,
  var duration: Double? = null,
  val startTime: Double? = null,
  val endTime: Double? = null,
  val url: String? = null,
  val sabr: EPSabrInfo? = null,
  val userAgent: String? = null,
  val contentType: String? = null,
  val headers: Map<String, String> = emptyMap(),
) {
  val sourceType: EPSourceType
    get() {
      if (sabr != null) return EPSourceType.SABR
      val ct = contentType?.lowercase()
      if (ct == "application/vnd.apple.mpegurl" || ct == "application/x-mpegurl") return EPSourceType.HLS
      val path = url?.let { runCatching { Uri.parse(it).path }.getOrNull() }?.lowercase()
      if (path != null && path.endsWith(".m3u8")) return EPSourceType.HLS
      return EPSourceType.RAW
    }

  val requestHeaders: Map<String, String>
    get() {
      val h = headers.toMutableMap()
      if (userAgent != null && !h.containsKey("User-Agent")) h["User-Agent"] = userAgent
      sabr?.cookie?.let { if (!h.containsKey("Cookie")) h["Cookie"] = it }
      return h
    }

  val trimStart: Double get() = maxOf(0.0, startTime ?: 0.0)

  fun trimEnd(mediaDuration: Double?): Double? {
    val known = duration ?: mediaDuration
    return when {
      endTime != null && known != null -> minOf(endTime, known)
      endTime != null -> endTime
      else -> known
    }
  }
}

data class EPVideoQualityRange(
  val minHeight: Int? = null,
  val maxHeight: Int? = 720,
  val maxBitrate: Int? = null,
)

data class EPVideoQuality(
  val id: String,
  val width: Int?,
  val height: Int?,
  val fps: Double?,
  val bitrate: Int,
  val label: String,
  val codec: String?,
)

data class EPVideoQualityState(
  val qualities: List<EPVideoQuality> = emptyList(),
  val selectedId: String? = null,
  val auto: Boolean = true,
)

data class EPSetupOptions(
  val cacheMaxSizeMB: Double = 256.0,
  val cacheMaxAgeSeconds: Double = 7.0 * 24 * 3600,
  val preloadNext: Int = 1,
  val persistentCache: Boolean = true,
  val forwardBufferSeconds: Double = 30.0,
  val maxBufferBytes: Int = 16 * 1024 * 1024,
  val enableVideo: Boolean = false,
  val autoHandleRemoteEvents: Boolean = true,
  val autoHandleInterruptions: Boolean = true,
  val sabrCallbackTimeoutMs: Double = 21000.0,
  val sabrPoolAhead: Int = 1,
  val videoQualityRange: EPVideoQualityRange = EPVideoQualityRange(),
)

enum class EPAppKilledBehavior { CONTINUE, PAUSE, STOP_AND_REMOVE }

data class EPUpdateOptions(
  val capabilities: Set<String> = emptySet(),
  val progressUpdateEventInterval: Double = 0.0,
  val forwardJumpInterval: Double = 15.0,
  val backwardJumpInterval: Double = 15.0,
  val appKilledBehavior: EPAppKilledBehavior = EPAppKilledBehavior.CONTINUE,
)

data class EPProgress(val position: Double, val duration: Double, val buffered: Double)

data class EPActiveTrackChange(
  val lastIndex: Int?,
  val lastTrackId: String?,
  val lastPosition: Double,
  val index: Int?,
  val trackId: String?,
)

sealed class EPRemoteEvent {
  object Play : EPRemoteEvent()
  object Pause : EPRemoteEvent()
  object Stop : EPRemoteEvent()
  object Next : EPRemoteEvent()
  object Previous : EPRemoteEvent()
  data class Seek(val position: Double) : EPRemoteEvent()
  data class JumpForward(val interval: Double) : EPRemoteEvent()
  data class JumpBackward(val interval: Double) : EPRemoteEvent()
  data class Duck(val paused: Boolean, val permanent: Boolean) : EPRemoteEvent()
  data class PlayId(val id: String, val index: Int?) : EPRemoteEvent()
  data class PlaySearch(val query: String) : EPRemoteEvent()
  data class Skip(val index: Int) : EPRemoteEvent()
  object Like : EPRemoteEvent()
  object Dislike : EPRemoteEvent()
  object Bookmark : EPRemoteEvent()
}

object EPEqualizerBands {
  val frequencies = floatArrayOf(31f, 62f, 125f, 250f, 500f, 1000f, 2000f, 4000f, 8000f, 16000f)
  const val MIN_GAIN = -12f
  const val MAX_GAIN = 12f
}

interface EPSabrCallbackProvider {
  suspend fun mintPoToken(trackId: String): ByteArray
  suspend fun reloadPlayerResponse(trackId: String, token: String?): Pair<String, String>
}
