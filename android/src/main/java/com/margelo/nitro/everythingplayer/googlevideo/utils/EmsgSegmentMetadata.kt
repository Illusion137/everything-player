package com.margelo.nitro.everythingplayer.googlevideo.utils

const val EMSG_BOX_TYPE: Long = 0x656d7367

class BoxReader(
  val data: DataView,
  val offset: Int,
  val size: Int,
  val type: Long,
  var cursor: Int,
)

private fun makeBoxReader(data: DataView, offset: Int): BoxReader {
  val size = data.getUint32(offset).toInt()
  val type = data.getUint32(offset + 4)
  return BoxReader(data, offset, size, type, 8)
}

private fun readUint32Field(box: BoxReader): Long {
  val value = box.data.getUint32(box.offset + box.cursor)
  box.cursor += 4
  return value
}

private fun bytesToString(bytes: ByteArray): String {
  if (bytes.isEmpty()) return ""
  return String(bytes, Charsets.UTF_8)
}

private fun readString(box: BoxReader, terminator: Int? = null): String {
  var end: Int

  if (terminator != null) {
    end = box.cursor
    while (end < box.size && box.data.getUint8(box.offset + end) != terminator) {
      end += 1
    }
  } else {
    end = box.size
  }

  val start = box.offset + box.cursor
  val length = maxOf(0, end - box.cursor)
  val bytes = box.data.data.copyOfRange(start, start + length)

  box.cursor = minOf(end + 1, box.size)

  return bytesToString(bytes)
}

private fun looksLikeBox(data: DataView, offset: Int): Boolean {
  if (data.byteLength - offset < 8) return false
  val size = data.getUint32(offset)
  if (size < 8 || data.byteLength - offset < size) return false

  for (i in 4 until 8) {
    val byte = data.getUint8(offset + i)
    if (byte < 48 || byte > 122) return false
  }

  return true
}

fun findBox(data: DataView, offset: Int, targetType: Long): BoxReader? {
  var offset = offset
  while (looksLikeBox(data, offset)) {
    val box = makeBoxReader(data, offset)
    if (box.type == targetType) return box
    offset += box.size
  }
  return null
}

data class EmsgBody(
  val schemeIdUri: String,
  val value: String,
  val timescale: Long,
  val presentationTimeDelta: Long,
  val eventDuration: Long,
  val id: Long,
  val messageData: String,
)

fun parseEmsgBody(box: BoxReader): EmsgBody {
  box.cursor += 4
  val schemeIdUri = readString(box, 0)
  val value = readString(box, 0)
  val timescale = readUint32Field(box)
  val presentationTimeDelta = readUint32Field(box)
  val eventDuration = readUint32Field(box)
  val id = readUint32Field(box)
  val messageData = readString(box)

  return EmsgBody(
    schemeIdUri = schemeIdUri,
    value = value,
    timescale = timescale,
    presentationTimeDelta = presentationTimeDelta,
    eventDuration = eventDuration,
    id = id,
    messageData = messageData,
  )
}

private val headerLineRegex = Regex("([^:]+):\\s+([\\s\\S]+)")

fun parseHeaderBlock(text: String): Map<String, String>? {
  val lines = text.split("\r\n")
  val headers = LinkedHashMap<String, String>()

  for (line in lines) {
    if (line.isEmpty()) return headers
    val match = headerLineRegex.find(line)
    if (match != null) {
      headers[match.groupValues[1]] = match.groupValues[2]
    }
  }

  return null
}

private fun getNumber(headers: Map<String, String>, key: String): Double {
  val number = headers[key]?.trim()?.toDoubleOrNull() ?: return 0.0
  return if (number.isFinite()) number else 0.0
}

class EmsgSegmentMetadata(var data: Map<String, String>, var uri: String = "https://youtube.com") {
  private val receivedAtMs: Double = nowMs()

  var segmentNumber: Double = getNumber(data, "Sequence-Number")
  var totalSegmentCount: Double = getNumber(data, "Segment-Count")
  var segmentDurationsMs: String = data["Segment-Durations-Ms"] ?: ""
  var ingestionTimeSec: Double = getNumber(data, "Ingestion-Walltime-Us") / 1e6
  var ingestionUncertaintySec: Double = getNumber(data, "Ingestion-Uncertainty-Us") / 1e6
  var safeFirstFrameTimeSec: Double =
    (getNumber(data, "First-Frame-Time-Us") +
      getNumber(data, "First-Frame-Uncertainty-Us")) /
      1e6
  var targetDurationSec: Double = getNumber(data, "Target-Duration-Us") / 1e6
  var cryptoPeriodIndex: Double = getNumber(data, "Crypto-Period-Index")
  var cryptoPeriodSeconds: Double = getNumber(data, "Crypto-Period-Seconds")
  var currentAbsoluteLoudnessLkfs: Double? =
    if (data["Current-Absolute-Loudness-Lkfs"] != null) getNumber(data, "Current-Absolute-Loudness-Lkfs") else null

  val latencyMs: Double
    get() {
      val ingestionTimeMs = ingestionTimeSec * 1e3
      val uncertaintyMs = ingestionUncertaintySec * 1e3
      return maxOf(0.0, (receivedAtMs - ingestionTimeMs) + uncertaintyMs)
    }

  fun getStitchedCPNs(): List<String> {
    val cpn = data["Stitched-Video-Cpn"]
    if (!cpn.isNullOrEmpty()) {
      return cpn.split(",").dropLast(1)
    }
    return emptyList()
  }

  fun hasStitchedAdBreakMetadata(): Boolean {
    val keys = listOf(
      "Stitched-Video-Id",
      "Stitched-Video-Cpn",
      "Stitched-Video-Duration-Us",
      "Stitched-Video-Start-Frame-Index",
      "Stitched-Video-Absolute-Loudness-Lkfs",
      "Serialized-State",
      "Is-Ad-Break-Finished",
    )
    return keys.any { !(data[it] ?: "").isEmpty() }
  }
}
