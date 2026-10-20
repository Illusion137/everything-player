package com.margelo.nitro.everythingplayer.googlevideo.types

import com.margelo.nitro.everythingplayer.googlevideo.core.CompositeBuffer
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.channels.ReceiveChannel
import kotlinx.coroutines.launch
import kotlinx.coroutines.suspendCancellableCoroutine
import java.io.InputStream
import java.net.HttpURLConnection
import java.net.URL
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException

class Part(
  var type: Int,
  var size: Int,
  var data: CompositeBuffer,
)

data class SabrFormat(
  var itag: Int,
  var lastModified: String,
  var xtags: String? = null,
  var contentLength: Long? = null,
  var mimeType: String? = null,
  var bitrate: Int,
  var height: Int? = null,
  var approxDurationMs: Long,
  var fps: Int? = null,
  var width: Int? = null,
  var audioTrackId: String? = null,
  var isDrc: Boolean? = null,
  var isVb: Boolean? = null,
  var isSr: Boolean? = null,
  var quality: String? = null,
  var qualityLabel: String? = null,
  var averageBitrate: Int? = null,
  var audioQuality: String? = null,
  var numChannels: Int? = null,
  var language: String? = null,
  var isHdr: Boolean = false,
  var isDubbed: Boolean? = null,
  var isAutoDubbed: Boolean? = null,
  var isDescriptive: Boolean? = null,
  var isSecondary: Boolean? = null,
  var isOriginal: Boolean? = null,
  var hasAudio: Boolean = false,
  var hasVideo: Boolean = false,
  var hasText: Boolean = false,
  var targetDurationSec: Double? = null,
  var codecCode: String? = null,
) : CreateFormatKeyInput {
  override val formatKeyCandidates: List<FormatKeyCandidate>
    get() = listOf(FormatKeyCandidate(itag, xtags))
}

data class FormatColorInfo(
  var transfer_characteristics: String? = null,
  var transferCharacteristics: String? = null,
)

data class FormatStream(
  var itag: Int,
  var bitrate: Int,
) {
  var last_modified_ms: String? = null
  var lastModified: String? = null
  var fps: Int? = null
  var xtags: String? = null
  var width: Int? = null
  var height: Int? = null
  var mime_type: String? = null
  var mimeType: String? = null
  var audio_quality: String? = null
  var audioQuality: String? = null
  var average_bitrate: Int? = null
  var averageBitrate: Int? = null
  var quality: String? = null
  var quality_label: String? = null
  var qualityLabel: String? = null
  var audio_track: AudioTrack? = null
  var audioTrackId: String? = null
  var audioChannels: Int? = null
  var audio_channels: Int? = null
  var caption_track: Map<String, String>? = null
  var captionTrack: Map<String, String>? = null
  var color_info: FormatColorInfo? = null
  var colorInfo: FormatColorInfo? = null
  var is_drc: Boolean? = null
  var isDrc: Boolean? = null
  var isVb: Boolean? = null
  var is_vb: Boolean? = null
  var is_sr: Boolean? = null
  var isSr: Boolean? = null
  var approx_duration_ms: Long? = null
  var approxDurationMs: String? = null
  var content_length: Long? = null
  var contentLength: String? = null
  var is_auto_dubbed: Boolean? = null
  var is_descriptive: Boolean? = null
  var is_dubbed: Boolean? = null
  var language: String? = null
  var is_original: Boolean? = null
  var is_secondary: Boolean? = null
  var targetDurationSec: Double? = null
  var target_duration_sec: Double? = null
  var target_duration_dec: Double? = null

  data class AudioTrack(var id: String)
}

data class FormatKeyCandidate(val itag: Int?, val xtags: String?)

interface CreateFormatKeyInput {
  val formatKeyCandidates: List<FormatKeyCandidate>
}

class FetchRequest(
  var url: String,
  var method: String = "GET",
  val headers: MutableMap<String, String> = LinkedHashMap(),
  var body: ByteArray? = null,
) {
  fun value(forHTTPHeaderField: String): String? =
    headers.entries.firstOrNull { it.key.equals(forHTTPHeaderField, ignoreCase = true) }?.value

  fun setValue(value: String, forHTTPHeaderField: String) {
    headers.keys.firstOrNull { it.equals(forHTTPHeaderField, ignoreCase = true) }?.let { headers.remove(it) }
    headers[forHTTPHeaderField] = value
  }
}

class HttpResponse(
  val url: String,
  val statusCode: Int,
  val headers: Map<String, String>,
) {
  fun value(forHTTPHeaderField: String): String? =
    headers.entries.firstOrNull { it.key.equals(forHTTPHeaderField, ignoreCase = true) }?.value
}

class FetchResponse(
  val response: HttpResponse,
  val body: ReceiveChannel<ByteArray>,
  val cancel: () -> Unit,
)

typealias FetchFunction = suspend (FetchRequest) -> FetchResponse

val defaultFetchFunction: FetchFunction = { request ->
  StreamingFetcher.shared.fetch(request)
}

class StreamingFetcher {
  private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

  suspend fun fetch(request: FetchRequest): FetchResponse {
    val connection = (URL(request.url).openConnection() as HttpURLConnection).apply {
      requestMethod = request.method
      instanceFollowRedirects = true
      connectTimeout = CONNECT_TIMEOUT_MS
      readTimeout = READ_TIMEOUT_MS
      for ((key, value) in request.headers) setRequestProperty(key, value)
    }

    val response = suspendCancellableCoroutine<HttpResponse> { continuation ->
      val job = scope.launch {
        try {
          request.body?.let { body ->
            connection.doOutput = true
            connection.setFixedLengthStreamingMode(body.size)
            connection.outputStream.use { it.write(body) }
          }
          val statusCode = connection.responseCode
          val headers = LinkedHashMap<String, String>()
          for ((key, values) in connection.headerFields) {
            if (key != null) headers[key.lowercase()] = values.joinToString(", ")
          }
          continuation.resume(HttpResponse(connection.url.toString(), statusCode, headers))
        } catch (e: Throwable) {
          connection.disconnect()
          if (continuation.isActive) continuation.resumeWithException(e)
        }
      }
      continuation.invokeOnCancellation {
        job.cancel()
        connection.disconnect()
      }
    }

    val body = Channel<ByteArray>(Channel.RENDEZVOUS)
    val reader = scope.launch {
      val input: InputStream? = try {
        if (response.statusCode >= 400) connection.errorStream else connection.inputStream
      } catch (e: Throwable) {
        null
      }
      try {
        if (input != null) {
          val buffer = ByteArray(CHUNK_SIZE)
          while (true) {
            val read = input.read(buffer)
            if (read < 0) break
            if (read > 0) body.send(buffer.copyOf(read))
          }
        }
        body.close()
      } catch (e: Throwable) {
        body.close(e)
      } finally {
        runCatching { input?.close() }
        connection.disconnect()
      }
    }

    val cancel = {
      reader.cancel()
      body.cancel()
      connection.disconnect()
    }

    return FetchResponse(response, body, cancel)
  }

  companion object {
    val shared = StreamingFetcher()

    private const val CHUNK_SIZE = 64 * 1024
    private const val CONNECT_TIMEOUT_MS = 30_000
    private const val READ_TIMEOUT_MS = 60_000
  }
}
