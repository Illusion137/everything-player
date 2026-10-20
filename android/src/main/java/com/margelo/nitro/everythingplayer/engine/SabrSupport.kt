package com.margelo.nitro.everythingplayer.engine

import com.margelo.nitro.everythingplayer.googlevideo.types.FetchFunction
import com.margelo.nitro.everythingplayer.googlevideo.types.SabrFormat
import com.margelo.nitro.everythingplayer.googlevideo.types.StreamingFetcher
import com.margelo.nitro.everythingplayer.googlevideo.utils.ClientInfo
import kotlinx.coroutines.TimeoutCancellationException
import kotlinx.coroutines.withTimeout
import java.io.File

data class EPLocalSabrMedia(
  val audioFile: File,
  val audioIsOpus: Boolean,
  val videoFile: File?,
)

object EPSabr {
  fun googleFormat(f: EPSabrFormat): SabrFormat {
    val mime = f.mimeType ?: ""
    return SabrFormat(
      itag = f.itag, lastModified = f.lastModified, xtags = f.xtags, contentLength = f.contentLength,
      mimeType = f.mimeType, bitrate = f.bitrate, height = f.height, approxDurationMs = f.approxDurationMs,
      fps = f.fps, width = f.width, audioTrackId = f.audioTrackId, isDrc = f.isDrc, isVb = f.isVb, isSr = f.isSr,
      quality = f.quality, qualityLabel = f.qualityLabel, averageBitrate = f.averageBitrate,
      audioQuality = f.audioQuality, numChannels = f.audioChannels, language = f.language,
      isHdr = f.isHdr ?: false, isDubbed = f.isDubbed, isAutoDubbed = f.isAutoDubbed,
      isDescriptive = f.isDescriptive, isSecondary = f.isSecondary, isOriginal = f.isOriginal,
      hasAudio = mime.startsWith("audio"), hasVideo = mime.startsWith("video"),
    )
  }

  fun pickAudio(formats: List<EPSabrFormat>): EPSabrFormat? {
    val audio = formats.filter { (it.mimeType ?: "").startsWith("audio") }
    val preferred = audio.filter(::isMainAudio)
    val pool = preferred.ifEmpty { audio }
    val original = pool.filter { it.isOriginal != false }
    val candidates = original.ifEmpty { pool }
    val opus = candidates.filter { (it.mimeType ?: "").contains("opus") }
    val aac = candidates.filter { (it.mimeType ?: "").contains("mp4a") }
    return opus.ifEmpty { aac }.maxByOrNull { it.bitrate }
  }

  private fun isMainAudio(f: EPSabrFormat): Boolean {
    if (f.isDrc == true || f.isDescriptive == true) return false
    if (f.isAutoDubbed == true || f.isSecondary == true) return false
    return true
  }

  fun videoFormats(formats: List<EPSabrFormat>): List<EPSabrFormat> {
    val seen = HashSet<Int>()
    return formats.filter {
      val m = it.mimeType ?: ""
      m.startsWith("video") && (m.contains("avc1") || m.contains("avc3")) && it.isHdr != true && seen.add(it.itag)
    }.sortedWith(compareByDescending<EPSabrFormat> { it.height ?: 0 }.thenByDescending { it.bitrate })
  }

  fun pickVideo(formats: List<EPSabrFormat>, range: EPVideoQualityRange): EPSabrFormat? =
    range.pick(videoFormats(formats), height = { it.height }, bitrate = { it.averageBitrate ?: it.bitrate })

  fun quality(f: EPSabrFormat): EPVideoQuality {
    val mime = f.mimeType ?: ""
    val codec = mime.indexOf("codecs=\"").takeIf { it >= 0 }?.let { start -> mime.substring(start + 8).takeWhile { it != '"' } }
    return EPVideoQuality(
      id = f.itag.toString(), width = f.width, height = f.height, fps = f.fps?.toDouble(),
      bitrate = f.averageBitrate ?: f.bitrate, label = f.qualityLabel ?: f.height?.let { "${it}p" } ?: "itag ${f.itag}",
      codec = codec,
    )
  }

  fun isOpus(format: EPSabrFormat): Boolean =
    (format.mimeType ?: "").contains("opus") || (format.mimeType ?: "").contains("webm")

  fun clientInfo(info: EPSabrInfo): ClientInfo = ClientInfo.newBuilder()
    .setClientName(info.clientName)
    .setClientVersion(info.clientVersion)
    .build()

  fun fetchFunction(headers: Map<String, String>): FetchFunction = { request ->
    for ((k, v) in headers) {
      if (request.value(forHTTPHeaderField = k) == null) request.setValue(v, forHTTPHeaderField = k)
    }
    StreamingFetcher.shared.fetch(request)
  }
}

suspend fun <T> epWithTimeout(ms: Double, what: String, operation: suspend () -> T): T = try {
  withTimeout(maxOf(1L, ms.toLong())) { operation() }
} catch (e: TimeoutCancellationException) {
  throw EPError(EPErrorCode.SABR_CALLBACK_FAILED, "$what timed out after ${ms.toInt()}ms")
}
