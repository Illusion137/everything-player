package com.margelo.nitro.everythingplayer.googlevideo.utils

import com.margelo.nitro.everythingplayer.googlevideo.core.GoogleVideoError
import com.margelo.nitro.everythingplayer.googlevideo.protos.misc.FormatId
import com.margelo.nitro.everythingplayer.googlevideo.protos.video_streaming.FormatInitializationMetadata
import com.margelo.nitro.everythingplayer.googlevideo.protos.video_streaming.MediaHeader
import com.margelo.nitro.everythingplayer.googlevideo.types.AudioFormatPreferences
import com.margelo.nitro.everythingplayer.googlevideo.types.CreateFormatKeyInput
import com.margelo.nitro.everythingplayer.googlevideo.types.FormatKeyCandidate
import com.margelo.nitro.everythingplayer.googlevideo.types.FormatSelector
import com.margelo.nitro.everythingplayer.googlevideo.types.FormatStream
import com.margelo.nitro.everythingplayer.googlevideo.types.MediaContainer
import com.margelo.nitro.everythingplayer.googlevideo.types.PreferredAudioCodec
import com.margelo.nitro.everythingplayer.googlevideo.types.PreferredVideoCodec
import com.margelo.nitro.everythingplayer.googlevideo.types.SabrFormat
import com.margelo.nitro.everythingplayer.googlevideo.types.SabrRequestMetadata
import com.margelo.nitro.everythingplayer.googlevideo.types.VideoFormatPreferences

const val MAX_INT32_VALUE = "2147483647"

enum class EnabledTrackTypes(val rawValue: Int) {
  VIDEO_AND_AUDIO(0),
  AUDIO_ONLY(1),
  VIDEO_ONLY(2),
}

class FormatPreferences(
  var quality: String? = null,
  var language: String? = null,
  var container: MediaContainer? = null,
  var preferredVideoCodec: PreferredVideoCodec? = null,
  var preferredAudioCodec: PreferredAudioCodec? = null,
  var voiceBoost: Boolean? = null,
  var dynamicRangeCompression: Boolean? = null,
  var superResolution: Boolean? = null,
  var hdr: Boolean? = null,
  var isAudio: Boolean,
) {
  constructor(preferences: AudioFormatPreferences?) : this(
    quality = preferences?.quality?.rawValue,
    language = preferences?.language,
    container = preferences?.container,
    preferredAudioCodec = preferences?.preferredAudioCodec,
    voiceBoost = preferences?.voiceBoost,
    dynamicRangeCompression = preferences?.dynamicRangeCompression,
    isAudio = true,
  )

  constructor(preferences: VideoFormatPreferences?) : this(
    quality = preferences?.quality,
    container = preferences?.container,
    preferredVideoCodec = preferences?.preferredVideoCodec,
    superResolution = preferences?.superResolution,
    hdr = preferences?.hdr,
    isAudio = false,
  )
}

fun describeMissingFormat(
  type: MediaType,
  formatOption: FormatSelector?,
  formats: List<SabrFormat>,
): String {
  val availableFormats = filterFormatsByType(formats, type == MediaType.AUDIO).joinToString(", ") {
    "${it.itag}[qualityLabel=${it.qualityLabel ?: it.audioQuality ?: ""}, mimeType=${it.mimeType ?: ""}, isVb=${it.isVb ?: false}, isDrc=${it.isDrc ?: false}]"
  }
  val available = availableFormats.ifEmpty { "none" }

  if (formatOption is FormatSelector.Itag) {
    return "no ${type.rawValue} format with itag ${formatOption.itag} found (available ${type.rawValue} formats: $available)"
  }
  if (formatOption is FormatSelector.Selector) {
    return "no ${type.rawValue} format matched the provided selector function (available ${type.rawValue} formats: $available)"
  }

  return "no ${type.rawValue} format matched the given criteria (available ${type.rawValue} formats: $available)"
}

fun chooseFormat(
  formats: List<SabrFormat>,
  formatOption: FormatSelector?,
  preferences: FormatPreferences,
): SabrFormat? {
  if (formats.isEmpty()) return null

  val typeFormats = filterFormatsByType(formats, preferences.isAudio)
  if (typeFormats.isEmpty()) return null

  when (formatOption) {
    is FormatSelector.Itag -> return typeFormats.firstOrNull { it.itag == formatOption.itag }
    is FormatSelector.Format -> return formatOption.format
    is FormatSelector.Selector -> return formatOption.selector(typeFormats)
    null -> Unit
  }

  var filteredFormats = typeFormats

  val language = preferences.language
  if (!language.isNullOrEmpty() && preferences.isAudio) {
    filteredFormats = filteredFormats.filter { it.language == language }
  }

  val quality = preferences.quality
  if (quality != null) {
    filteredFormats = filteredFormats.filter { format ->
      if (preferences.isAudio) {
        format.audioQuality?.lowercase()?.contains(quality.lowercase()) ?: false
      } else {
        format.qualityLabel?.lowercase()?.contains(quality.lowercase()) ?: false
      }
    }
  }

  val container = preferences.container
  if (container != null) {
    filteredFormats = filteredFormats.filter { it.mimeType?.contains(container.rawValue) ?: false }
  }

  val voiceBoost = preferences.voiceBoost
  if (voiceBoost != null) {
    filteredFormats = filteredFormats.filter { it.isVb == voiceBoost }
  }

  val dynamicRangeCompression = preferences.dynamicRangeCompression
  if (dynamicRangeCompression != null) {
    filteredFormats = filteredFormats.filter { it.isDrc == dynamicRangeCompression }
  }

  val superResolution = preferences.superResolution
  if (superResolution != null) {
    filteredFormats = filteredFormats.filter { it.isSr == superResolution }
  }

  val hdr = preferences.hdr
  if (hdr != null) {
    filteredFormats = filteredFormats.filter { it.isHdr == hdr }
  }

  val preferredCodec = if (preferences.isAudio) preferences.preferredAudioCodec?.rawValue else preferences.preferredVideoCodec?.rawValue

  return filteredFormats.withIndex().sortedWith { a, b ->
    val preferenceDifference = (if (matchesCodec(b.value, preferredCodec)) 1 else 0) - (if (matchesCodec(a.value, preferredCodec)) 1 else 0)
    if (preferenceDifference != 0) return@sortedWith preferenceDifference

    val difference = if (preferences.isAudio) {
      b.value.bitrate - a.value.bitrate
    } else {
      (b.value.height ?: 0) - (a.value.height ?: 0)
    }
    if (difference != 0) return@sortedWith difference

    a.index - b.index
  }.firstOrNull()?.value
}

private val codecMimeTypePrefixes: Map<String, List<String>> = mapOf(
  "h264" to listOf("avc1", "avc3"),
  "vp9" to listOf("vp9", "vp09"),
  "av1" to listOf("av01"),
  "aac" to listOf("mp4a"),
  "opus" to listOf("opus"),
)

private fun matchesCodec(format: SabrFormat, codec: String?): Boolean {
  if (codec == null) return false
  return codecMimeTypePrefixes[codec]?.any { format.mimeType?.contains(it) ?: false } ?: false
}

private fun filterFormatsByType(formats: List<SabrFormat>, isAudio: Boolean): List<SabrFormat> =
  formats.filter { format ->
    val mimeType = format.mimeType
    if (mimeType.isNullOrEmpty()) return@filter false
    if (isAudio) mimeType.contains("audio") else mimeType.contains("video")
  }

fun buildSabrFormat(formatStream: FormatStream): SabrFormat {
  val transferCharacteristics = nonEmpty(formatStream.color_info?.transfer_characteristics) ?: formatStream.colorInfo?.transferCharacteristics ?: ""

  val format = SabrFormat(
    itag = formatStream.itag,
    lastModified = nonEmpty(formatStream.last_modified_ms) ?: formatStream.lastModified ?: "0",
    xtags = formatStream.xtags,
    mimeType = formatStream.mime_type ?: formatStream.mimeType,
    bitrate = formatStream.bitrate,
    height = formatStream.height,
    approxDurationMs = formatStream.approx_duration_ms ?: (formatStream.approxDurationMs ?: "0").toLongOrNull() ?: 0,
    fps = formatStream.fps,
    width = formatStream.width,
    audioTrackId = nonEmpty(formatStream.audio_track?.id) ?: formatStream.audioTrackId,
    quality = formatStream.quality,
    isHdr = transferCharacteristics.contains("SMPTEST2084") || transferCharacteristics.contains("ARIB_STD_B67"),
  )

  format.audioQuality = nonEmpty(formatStream.audio_quality) ?: formatStream.audioQuality
  format.numChannels = formatStream.audio_channels ?: formatStream.audioChannels
  format.averageBitrate = formatStream.average_bitrate ?: formatStream.averageBitrate
  format.qualityLabel = nonEmpty(formatStream.quality_label) ?: formatStream.qualityLabel
  val contentLength = (formatStream.contentLength ?: "0").toLongOrNull() ?: 0
  format.contentLength = if (contentLength != 0L) contentLength else formatStream.content_length
  format.targetDurationSec = formatStream.targetDurationSec ?: formatStream.target_duration_sec ?: formatStream.target_duration_dec
  format.hasAudio = !(formatStream.audioQuality ?: formatStream.audio_quality ?: "").isEmpty()
  format.hasVideo = !(formatStream.qualityLabel ?: "").isEmpty() && (formatStream.quality_label ?: "").isEmpty()
  format.hasText = formatStream.captionTrack != null || formatStream.caption_track != null
  format.isVb = formatStream.isVb ?: formatStream.is_vb
  format.isSr = formatStream.isSr ?: formatStream.is_sr
  format.isDrc = formatStream.is_drc
  format.isAutoDubbed = formatStream.is_auto_dubbed
  format.isDescriptive = formatStream.is_descriptive
  format.isDubbed = formatStream.is_dubbed
  format.language = formatStream.language
  format.isOriginal = formatStream.is_original
  format.isSecondary = formatStream.is_secondary
  format.codecCode = CODEC_CODES[formatStream.itag]

  return format
}

private fun nonEmpty(value: String?): String? = if (value.isNullOrEmpty()) null else value

fun createFormatKey(candidates: List<FormatKeyCandidate>): String {
  for (candidate in candidates) {
    if (candidate.itag == null && candidate.xtags == null) continue
    val itag = candidate.itag?.takeIf { it != 0 }?.toString() ?: ""
    return "$itag:${candidate.xtags ?: ""}"
  }

  throw GoogleVideoError("Unsupported format type")
}

fun createFormatKey(input: CreateFormatKeyInput): String = createFormatKey(input.formatKeyCandidates)

fun createFormatKey(input: MediaHeader): String = createFormatKey(input.formatKeyCandidates)

fun createFormatKey(input: FormatInitializationMetadata): String = createFormatKey(input.formatKeyCandidates)

fun createFormatKey(input: FormatId): String = createFormatKey(input.formatKeyCandidates)

fun createSegmentCacheKey(
  mediaHeader: MediaHeader,
  format: SabrFormat? = null,
): String {
  if (mediaHeader.isInitializationSegment && format != null) {
    return "${mediaHeader.itag}:${mediaHeader.xtags}:${format.contentLength?.toString() ?: ""}:${format.mimeType ?: ""}"
  }
  return "${if (mediaHeader.hasSegmentByteRangeStart() && mediaHeader.segmentByteRangeStart != 0L) mediaHeader.segmentByteRangeStart.toString() else "0"}-${mediaHeader.itag}-${mediaHeader.xtags}"
}

fun createSegmentCacheKeyFromMetadata(
  requestMetadata: SabrRequestMetadata,
): String {
  val byteRange = requestMetadata.byteRange
  val format = requestMetadata.format
  if (byteRange == null || format == null) {
    throw GoogleVideoError("Invalid metadata: byteRange or format is missing")
  }

  val pseudoMediaHeader = MediaHeader.newBuilder()
    .setItag(format.itag)
    .setXtags(format.xtags ?: "")
    .setSegmentByteRangeStart(byteRange.start)
    .setIsInitializationSegment(requestMetadata.isInit ?: false)
    .build()

  return createSegmentCacheKey(
    pseudoMediaHeader,
    if (requestMetadata.isInit == true) format else null,
  )
}

fun getUniqueFormatId(format: SabrFormat): String {
  val width = format.width
  if (width != null && width != 0) {
    return format.itag.toString()
  }

  val uidParts = mutableListOf(format.itag.toString())

  val audioTrackId = format.audioTrackId
  if (!audioTrackId.isNullOrEmpty()) {
    uidParts.add(audioTrackId)
  }

  if (format.isDrc == true) {
    uidParts.add("drc")
  }

  return uidParts.joinToString("-")
}

val MediaHeader.formatKeyCandidates: List<FormatKeyCandidate>
  get() {
    val candidates = mutableListOf<FormatKeyCandidate>()
    if (hasFormatId()) candidates.add(formatId.formatKeyCandidates[0])
    candidates.add(FormatKeyCandidate(if (hasItag()) itag else null, if (hasXtags()) xtags else null))
    return candidates
  }

val FormatInitializationMetadata.formatKeyCandidates: List<FormatKeyCandidate>
  get() = if (hasFormatId()) formatId.formatKeyCandidates else emptyList()

val FormatId.formatKeyCandidates: List<FormatKeyCandidate>
  get() = listOf(FormatKeyCandidate(if (hasItag()) itag else null, if (hasXtags()) xtags else null))

fun FormatId(format: SabrFormat): FormatId {
  val builder = FormatId.newBuilder().setItag(format.itag)
  format.lastModified.toULongOrNull()?.let { builder.setLastModified(it.toLong()) }
  format.xtags?.let { builder.setXtags(it) }
  return builder.build()
}
