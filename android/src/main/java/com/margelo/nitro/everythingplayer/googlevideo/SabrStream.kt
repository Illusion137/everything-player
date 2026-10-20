package com.margelo.nitro.everythingplayer.googlevideo

import kotlinx.coroutines.channels.ReceiveChannel

data class ClientInfo(val clientName: Int, val clientVersion: String)

data class SabrFormat(
  val itag: Int,
  val lastModified: String,
  val xtags: String? = null,
  val mimeType: String? = null,
  val bitrate: Int,
  val approxDurationMs: Long,
  val contentLength: Long? = null,
  val width: Int? = null,
  val height: Int? = null,
  val fps: Int? = null,
  val audioTrackId: String? = null,
  val isDrc: Boolean? = null,
  val isVb: Boolean? = null,
  val language: String? = null,
)

data class ReloadPlaybackContext(val token: String?)

data class ReloadResponse(val serverAbrStreamingUrl: String, val videoPlaybackUstreamerConfig: String)

class SabrStreamCallbacks(
  val onMintPoToken: (suspend () -> ByteArray)? = null,
  val onReloadPlayerResponse: (suspend (ReloadPlaybackContext?) -> ReloadResponse)? = null,
)

class SabrStreamConfig(
  val videoId: String,
  val serverAbrStreamingUrl: String,
  val videoPlaybackUstreamerConfig: String,
  val poToken: String?,
  val clientInfo: ClientInfo,
  val formats: List<SabrFormat>,
  val headers: Map<String, String> = emptyMap(),
  val callbacks: SabrStreamCallbacks? = null,
  val stripDuplicateInit: Boolean = true,
  val videoHighWaterMark: Int? = null,
  val audioHighWaterMark: Int? = null,
)

enum class EnabledTrackTypes { VIDEO_AND_AUDIO, AUDIO_ONLY, VIDEO_ONLY }

class SabrPlaybackOptions(
  val videoItag: Int? = null,
  val audioItag: Int,
  val enabledTrackTypes: EnabledTrackTypes = EnabledTrackTypes.AUDIO_ONLY,
  val startTimeMs: Long = 0,
)

class SelectedFormats(val videoFormat: SabrFormat?, val audioFormat: SabrFormat)

class StreamStartResult(
  val videoStream: ReceiveChannel<ByteArray>,
  val audioStream: ReceiveChannel<ByteArray>,
  val selectedFormats: SelectedFormats,
)

class SabrUnsupportedException : UnsupportedOperationException("kotlin-googlevideo is not implemented yet; SABR playback is unavailable on Android")

class SabrStream(val config: SabrStreamConfig) {
  val isAborted: Boolean get() = aborted
  val audioEndTimeMs: Long get() = 0
  val videoEndTimeMs: Long get() = 0

  private var aborted = false

  fun setStreamingURL(url: String) {}

  fun setUstreamerConfig(config: String) {}

  fun start(options: SabrPlaybackOptions): StreamStartResult {
    throw SabrUnsupportedException()
  }

  fun abort() {
    aborted = true
  }

  companion object {
    const val IS_IMPLEMENTED = false
  }
}
