package com.margelo.nitro.everythingplayer.googlevideo.utils

import com.margelo.nitro.everythingplayer.googlevideo.protos.misc.FormatId
import com.margelo.nitro.everythingplayer.googlevideo.types.BufferedRangeSummary
import com.margelo.nitro.everythingplayer.googlevideo.types.CompletedSegment
import com.margelo.nitro.everythingplayer.googlevideo.types.SegmentInfo
import com.margelo.nitro.everythingplayer.googlevideo.types.TrackOutput
import com.margelo.nitro.everythingplayer.googlevideo.types.TrackState
import kotlin.math.ceil

private const val MAX_TRACKED_SEGMENTS = 64

class Track(val type: MediaType) {
  var formatId: FormatId? = null
  var mimeType: String? = null
  var endSegmentNum: Int? = null
  var endTimeTicks: Long? = null
  var endTimescale: Long? = null
  var targetDurationSec: Double? = null
  var trackedSegments = OrderedMap<Int, CompletedSegment>()
  var bufferedRangeSummary: BufferedRangeSummary? = null
  var emsgSegmentMetadata: EmsgSegmentMetadata? = null
  var initSegment: ByteArray? = null

  private var _output: TrackOutput? = null

  var output: TrackOutput
    get() = _output!!
    set(value) {
      _output = value
    }

  val streamLocked: Boolean
    get() = output.stream.locked

  val streamDesiredSize: Int
    get() = output.controller.desiredSize ?: 0

  val streamController
    get() = output.controller

  val streamFull: Boolean
    get() = streamLocked && streamDesiredSize <= 0

  val endTimeMs: Long
    get() {
      val endTimeTicks = endTimeTicks ?: return 0
      val endTimescale = endTimescale ?: return 0
      return ticksToMs(endTimeTicks, endTimescale, ::ceil)
    }

  val endOfStreamReached: Boolean
    get() {
      val endSegmentNum = endSegmentNum ?: return false
      return endSegmentNum > 0 && trackedSegments.has(endSegmentNum)
    }

  val latencyMs: Double?
    get() = emsgSegmentMetadata?.latencyMs

  fun update(state: TrackState) {
    state.formatId?.let { formatId = it }
    state.mimeType?.let { mimeType = it }
    state.endSegmentNum?.let { endSegmentNum = it }
    state.endTimeTicks?.let { endTimeTicks = it }
    state.endTimescale?.let { endTimescale = it }
    state.targetDurationSec?.let { targetDurationSec = it }
    state.trackedSegments?.let { segments -> trackedSegments = OrderedMap<Int, CompletedSegment>().apply { segments.forEach { put(it.first, it.second) } } }
    state.bufferedRangeSummary?.let { bufferedRangeSummary = it }
  }

  fun snapshot(): TrackState = TrackState(
    formatId = formatId,
    mimeType = mimeType,
    endSegmentNum = endSegmentNum,
    endTimeTicks = endTimeTicks,
    endTimescale = endTimescale,
    targetDurationSec = targetDurationSec,
    bufferedRangeSummary = bufferedRangeSummary,
    trackedSegments = trackedSegments.entries.map { it.key to it.value },
  )

  fun discardMediaSegments() {
    for (key in trackedSegments.keys.toList()) {
      if (trackedSegments[key]?.mediaHeader?.isInitializationSegment != true) trackedSegments.remove(key)
    }
    bufferedRangeSummary = null
  }

  fun recordCompletedSegment(info: SegmentInfo, emsgMetadata: EmsgSegmentMetadata? = null) {
    var durationMs: Double? = info.durationMs

    if (info.durationMs <= 0 && !info.mediaHeader.isInitializationSegment) {
      val targetDurationSec = targetDurationSec
      durationMs = if (targetDurationSec != null && targetDurationSec != 0.0) targetDurationSec * 1000 else null
    }

    if (emsgMetadata != null) {
      emsgSegmentMetadata = emsgMetadata
      if (emsgMetadata.targetDurationSec > 0) {
        durationMs = emsgMetadata.targetDurationSec * 1000
      }
    }

    val resolvedDurationMs = assertIsDefined(durationMs, "Track is missing durationMs: formatKey=${info.formatKey}, segmentNumber=${info.segmentNumber}")

    val segmentNumber = info.segmentNumber
    val mediaHeader = info.mediaHeader
    val startTimeMs = info.startTimeMs
    val endTimeMs = startTimeMs + resolvedDurationMs

    trackedSegments[segmentNumber] = CompletedSegment(
      segmentNumber = segmentNumber,
      durationMs = resolvedDurationMs,
      startTimeMs = startTimeMs,
      endTimeMs = endTimeMs,
      mediaHeader = mediaHeader,
    )

    evictOldestTrackedSegments()
    refreshBufferedRanges()
  }

  private fun refreshBufferedRanges() {
    var first: CompletedSegment? = null
    var last: CompletedSegment? = null

    for (segment in trackedSegments.values) {
      if (segment.mediaHeader.isInitializationSegment) continue
      if (first == null || segment.segmentNumber < first.segmentNumber) first = segment
      if (last == null || segment.segmentNumber > last.segmentNumber) last = segment
    }

    if (first == null || last == null) {
      bufferedRangeSummary = null
      return
    }

    bufferedRangeSummary = BufferedRangeSummary(
      startTimeMs = first.startTimeMs,
      durationMs = maxOf(0.0, last.endTimeMs - first.startTimeMs),
      startSegmentIndex = first.segmentNumber,
      endSegmentIndex = last.segmentNumber,
    )
  }

  private fun evictOldestTrackedSegments() {
    while (trackedSegments.size > MAX_TRACKED_SEGMENTS) {
      val oldestKey = trackedSegments.keys.firstOrNull() ?: break
      trackedSegments.remove(oldestKey)
    }
  }
}
