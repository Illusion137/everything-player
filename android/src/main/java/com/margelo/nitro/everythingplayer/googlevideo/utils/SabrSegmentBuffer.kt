package com.margelo.nitro.everythingplayer.googlevideo.utils

import com.margelo.nitro.everythingplayer.googlevideo.core.CompositeBuffer
import com.margelo.nitro.everythingplayer.googlevideo.protos.video_streaming.MediaHeader
import com.margelo.nitro.everythingplayer.googlevideo.types.SegmentInfo
import java.nio.ByteBuffer

private class PendingSegment(
  var info: SegmentInfo,
  var bufferedChunks: MutableList<ByteBuffer>,
  var loadedLengthBytes: Long,
  var type: MediaType,
)

private const val TAG = "SabrSegmentBuffer"

class SabrSegmentBuffer(
  private val trackMetadata: TrackCollection,
  private val isBroadcast: Boolean = false,
  private val stripDuplicateInit: Boolean = true,
) {
  private val logger = Logger.getInstance()
  private val pendingSegments = HashMap<Int, PendingSegment>()

  fun reset() {
    trackMetadata.initializedTracksMap.clear()
    pendingSegments.clear()
  }

  fun discardPending() {
    pendingSegments.clear()
  }

  fun queueMediaHeader(mediaHeader: MediaHeader) {
    val headerId = if (mediaHeader.hasHeaderId()) mediaHeader.headerId else 0
    val formatKey = createFormatKey(mediaHeader)

    val track = trackMetadata.initializedTracksMap[formatKey]
    if (track == null) {
      logger.warn(TAG, "No track found: formatKey=$formatKey, headerId=$headerId")
      return
    }

    val segmentNumber = if (mediaHeader.isInitializationSegment) 0 else mediaHeader.segmentNum

    if (track.trackedSegments.has(segmentNumber)) {
      logger.debug(TAG, "Ignoring recently downloaded segment: formatKey=$formatKey, segmentNumber=$segmentNumber")
      return
    }

    pendingSegments[headerId] = PendingSegment(
      info = SegmentInfo(
        formatKey = formatKey,
        segmentNumber = segmentNumber,
        mediaHeader = mediaHeader,
        startTimeMs = getStartMs(mediaHeader).toDouble(),
        durationMs = getDurationMs(mediaHeader).toDouble(),
      ),
      bufferedChunks = mutableListOf(),
      loadedLengthBytes = 0,
      type = track.type,
    )
  }

  fun appendMediaData(headerId: Int, buffer: CompositeBuffer) {
    val pendingSegment = pendingSegments[headerId]
    if (pendingSegment == null) {
      logger.debug(TAG, "Received MEDIA for unknown header id $headerId")
      return
    }

    pendingSegment.bufferedChunks.addAll(buffer.chunks)
    pendingSegment.loadedLengthBytes += buffer.getLength()
  }

  fun finalizeSegment(headerId: Int): Boolean {
    val pendingSegment = pendingSegments[headerId]
    if (pendingSegment == null) {
      logger.debug(TAG, "Received MEDIA_END for unknown header id $headerId")
      return false
    }

    val track = trackMetadata.getInitializedTrack(pendingSegment.info.formatKey)
    if (track == null) {
      pendingSegments.remove(headerId)
      return false
    }

    val expectedLengthBytes = pendingSegment.info.mediaHeader.segmentLengthBytes
    val loadedLengthBytes = pendingSegment.loadedLengthBytes

    if (expectedLengthBytes > 0 && loadedLengthBytes != expectedLengthBytes) {
      logger.warn(
        TAG,
        "Ignoring partial segment ${pendingSegment.info.segmentNumber} for ${pendingSegment.info.formatKey}.\n" +
          "expected=$expectedLengthBytes, received=$loadedLengthBytes",
      )
      pendingSegments.remove(headerId)
      return false
    }

    var segment = concatenateChunks(pendingSegment.bufferedChunks)

    val emsgMetadata = parseEmsgSegmentMetadata(segment)

    if (isBroadcast && stripDuplicateInit && track.trackedSegments.size != 0) {
      segment = if (track.mimeType?.contains("webm") == true) stripWebmInit(segment) else stripMp4Init(segment)
    }

    if (pendingSegment.info.mediaHeader.isInitializationSegment) {
      track.initSegment = segment
    }

    if (track.streamLocked || track.streamDesiredSize > 0) {
      track.streamController.enqueue(segment)
    }

    track.recordCompletedSegment(pendingSegment.info, emsgMetadata)

    pendingSegments.remove(headerId)

    return !pendingSegment.info.mediaHeader.isInitializationSegment
  }
}
