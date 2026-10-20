package com.margelo.nitro.everythingplayer

import com.margelo.nitro.core.Promise
import com.margelo.nitro.everythingplayer.engine.EPDownloadRecord
import com.margelo.nitro.everythingplayer.engine.EPError
import com.margelo.nitro.everythingplayer.engine.EPErrorCode
import com.margelo.nitro.everythingplayer.engine.EPRemoteEvent
import com.margelo.nitro.everythingplayer.engine.EPSabrCallbackProvider
import com.margelo.nitro.everythingplayer.engine.EPSabrFormat
import com.margelo.nitro.everythingplayer.engine.EPSabrInfo
import com.margelo.nitro.everythingplayer.engine.EPTrack
import com.margelo.nitro.everythingplayer.engine.EPVideoQualityRange
import com.margelo.nitro.everythingplayer.engine.EPVideoQualityState
import android.util.Base64

internal fun NativeTrack.toEngine(): EPTrack = EPTrack(
  id = id,
  title = title,
  artist = artist,
  album = album,
  artwork = artwork,
  duration = duration,
  startTime = startTime,
  endTime = endTime,
  url = url,
  sabr = sabr?.toEngine(),
  userAgent = userAgent,
  contentType = contentType,
  headers = headers ?: emptyMap(),
)

internal fun NativeSabrInfo.toEngine(): EPSabrInfo = EPSabrInfo(
  videoId = videoId,
  serverAbrStreamingUrl = serverAbrStreamingUrl,
  videoPlaybackUstreamerConfig = videoPlaybackUstreamerConfig,
  formats = formats.map { it.toEngine() },
  poToken = poToken,
  clientName = clientInfo.clientName.toInt(),
  clientVersion = clientInfo.clientVersion,
  cookie = cookie,
  duration = duration,
)

internal fun NativeSabrFormat.toEngine(): EPSabrFormat = EPSabrFormat(
  itag = itag.toInt(),
  lastModified = lastModified,
  xtags = xtags,
  mimeType = mimeType,
  bitrate = bitrate.toInt(),
  averageBitrate = averageBitrate?.toInt(),
  approxDurationMs = approxDurationMs.toLong(),
  contentLength = contentLength?.toLong(),
  width = width?.toInt(),
  height = height?.toInt(),
  fps = fps?.toInt(),
  quality = quality,
  qualityLabel = qualityLabel,
  audioQuality = audioQuality,
  audioSampleRate = audioSampleRate?.toInt(),
  audioChannels = audioChannels?.toInt(),
  audioTrackId = audioTrackId,
  language = language,
  isDrc = isDrc,
  isVb = isVb,
  isSr = isSr,
  isHdr = isHdr,
  isDubbed = isDubbed,
  isAutoDubbed = isAutoDubbed,
  isDescriptive = isDescriptive,
  isSecondary = isSecondary,
  isOriginal = isOriginal,
)

internal fun EPTrack.toNative(): NativeTrack = NativeTrack(
  id, title, artist, album, artwork, duration, startTime, endTime, url, sabr?.toNative(), userAgent, contentType,
  headers.ifEmpty { null },
)

internal fun EPSabrInfo.toNative(): NativeSabrInfo = NativeSabrInfo(
  videoId, serverAbrStreamingUrl, videoPlaybackUstreamerConfig, formats.map { it.toNative() }.toTypedArray(),
  poToken, NativeSabrClientInfo(clientName.toDouble(), clientVersion), cookie, duration,
)

internal fun EPSabrFormat.toNative(): NativeSabrFormat = NativeSabrFormat(
  itag.toDouble(), lastModified, xtags, mimeType, bitrate.toDouble(), averageBitrate?.toDouble(),
  approxDurationMs.toDouble(), contentLength?.toDouble(), width?.toDouble(), height?.toDouble(), fps?.toDouble(),
  quality, qualityLabel, audioQuality, audioSampleRate?.toDouble(), audioChannels?.toDouble(), audioTrackId, language,
  isDrc, isVb, isSr, isHdr, isDubbed, isAutoDubbed, isDescriptive, isSecondary, isOriginal,
)

internal fun EPError.toNative(): NativePlaybackError = NativePlaybackError(errorCode.code, message, trackId)

internal fun NativeCapability.key(): String = name.lowercase().replace('_', '-')

internal fun EPRemoteEvent.toNative(): NativeRemoteEvent {
  fun make(
    type: NativeRemoteEventType,
    position: Double? = null,
    interval: Double? = null,
    paused: Boolean? = null,
    permanent: Boolean? = null,
    id: String? = null,
    index: Double? = null,
    query: String? = null,
  ) = NativeRemoteEvent(type, position, interval, paused, permanent, id, index, query)
  return when (this) {
    EPRemoteEvent.Play -> make(NativeRemoteEventType.REMOTE_PLAY)
    EPRemoteEvent.Pause -> make(NativeRemoteEventType.REMOTE_PAUSE)
    EPRemoteEvent.Stop -> make(NativeRemoteEventType.REMOTE_STOP)
    EPRemoteEvent.Next -> make(NativeRemoteEventType.REMOTE_NEXT)
    EPRemoteEvent.Previous -> make(NativeRemoteEventType.REMOTE_PREVIOUS)
    is EPRemoteEvent.Seek -> make(NativeRemoteEventType.REMOTE_SEEK, position = position)
    is EPRemoteEvent.JumpForward -> make(NativeRemoteEventType.REMOTE_JUMP_FORWARD, interval = interval)
    is EPRemoteEvent.JumpBackward -> make(NativeRemoteEventType.REMOTE_JUMP_BACKWARD, interval = interval)
    is EPRemoteEvent.Duck -> make(NativeRemoteEventType.REMOTE_DUCK, paused = paused, permanent = permanent)
    is EPRemoteEvent.PlayId -> make(NativeRemoteEventType.REMOTE_PLAY_ID, id = id, index = index?.toDouble())
    is EPRemoteEvent.PlaySearch -> make(NativeRemoteEventType.REMOTE_PLAY_SEARCH, query = query)
    is EPRemoteEvent.Skip -> make(NativeRemoteEventType.REMOTE_SKIP, index = index.toDouble())
    EPRemoteEvent.Like -> make(NativeRemoteEventType.REMOTE_LIKE)
    EPRemoteEvent.Dislike -> make(NativeRemoteEventType.REMOTE_DISLIKE)
    EPRemoteEvent.Bookmark -> make(NativeRemoteEventType.REMOTE_BOOKMARK)
  }
}

internal fun EPDownloadRecord.toNative(): NativeDownload = NativeDownload(
  trackId = trackId,
  state = when (state) {
    "queued" -> NativeDownloadState.QUEUED
    "downloading" -> NativeDownloadState.DOWNLOADING
    "paused" -> NativeDownloadState.PAUSED
    "completed" -> NativeDownloadState.COMPLETED
    "cancelled" -> NativeDownloadState.CANCELLED
    else -> NativeDownloadState.FAILED
  },
  progress = progress,
  bytesDownloaded = bytesDownloaded.toDouble(),
  totalBytes = totalBytes?.toDouble(),
  localPath = audioPath,
  audioPath = audioPath,
  videoPath = videoPath,
  errorCode = errorCode,
  errorMessage = errorMessage,
  track = track.toNative(),
)

internal fun NativeVideoQualityRange.toEngine(): EPVideoQualityRange =
  EPVideoQualityRange(minHeight?.toInt(), maxHeight?.toInt(), maxBitrate?.toInt())

internal fun EPVideoQualityRange.toNative(): NativeVideoQualityRange =
  NativeVideoQualityRange(minHeight?.toDouble(), maxHeight?.toDouble(), maxBitrate?.toDouble())

internal fun EPVideoQualityState.toNative(trackId: String?): NativeVideoQualityState = NativeVideoQualityState(
  qualities.map {
    NativeVideoQuality(it.id, it.width?.toDouble(), it.height?.toDouble(), it.fps, it.bitrate.toDouble(), it.label, it.codec)
  }.toTypedArray(),
  selectedId,
  auto,
  trackId,
)

internal class JSSabrCallbacks(
  private val mint: (String) -> Promise<Promise<String>>,
  private val reload: (String, NativeReloadPlaybackContext) -> Promise<Promise<NativeReloadPlayerResponse>>,
) : EPSabrCallbackProvider {
  override suspend fun mintPoToken(trackId: String): ByteArray {
    val encoded = mint(trackId).await().await()
    return runCatching { Base64.decode(encoded, Base64.DEFAULT) }.getOrElse {
      throw EPError(EPErrorCode.SABR_CALLBACK_FAILED, "onMintPoToken returned invalid bytes")
    }
  }

  override suspend fun reloadPlayerResponse(trackId: String, token: String?): Pair<String, String> {
    val response = reload(trackId, NativeReloadPlaybackContext(NativeReloadPlaybackParams(token))).await().await()
    return response.serverAbrStreamingUrl to response.videoPlaybackUstreamerConfig
  }
}
