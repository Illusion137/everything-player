package com.margelo.nitro.everythingplayer.googlevideo.core

import com.margelo.nitro.everythingplayer.googlevideo.protos.video_streaming.FormatInitializationMetadata
import com.margelo.nitro.everythingplayer.googlevideo.protos.video_streaming.MediaHeader
import com.margelo.nitro.everythingplayer.googlevideo.protos.video_streaming.NextRequestPolicy
import com.margelo.nitro.everythingplayer.googlevideo.protos.video_streaming.ReloadPlaybackContext
import com.margelo.nitro.everythingplayer.googlevideo.protos.video_streaming.SabrContextSendingPolicy
import com.margelo.nitro.everythingplayer.googlevideo.protos.video_streaming.SabrContextUpdate
import com.margelo.nitro.everythingplayer.googlevideo.protos.video_streaming.SabrError
import com.margelo.nitro.everythingplayer.googlevideo.protos.video_streaming.SabrRedirect
import com.margelo.nitro.everythingplayer.googlevideo.protos.video_streaming.SnackbarMessage
import com.margelo.nitro.everythingplayer.googlevideo.protos.video_streaming.StreamProtectionStatus
import com.margelo.nitro.everythingplayer.googlevideo.protos.video_streaming.UMPPartId
import com.margelo.nitro.everythingplayer.googlevideo.types.Part
import com.margelo.nitro.everythingplayer.googlevideo.types.SabrRequestError
import com.margelo.nitro.everythingplayer.googlevideo.types.SabrRequestMetadata
import com.margelo.nitro.everythingplayer.googlevideo.types.SabrRequestStreamInfo
import com.margelo.nitro.everythingplayer.googlevideo.utils.CacheManager
import com.margelo.nitro.everythingplayer.googlevideo.utils.concatenateChunks
import com.margelo.nitro.everythingplayer.googlevideo.utils.createFormatKey
import com.margelo.nitro.everythingplayer.googlevideo.utils.createSegmentCacheKey
import com.margelo.nitro.everythingplayer.googlevideo.utils.decodePart
import java.nio.ByteBuffer

private class Segment(
  var headerId: Int?,
  var mediaHeader: MediaHeader,
  var bufferedChunks: MutableList<ByteBuffer>,
  var lastChunkSize: Int,
) {
  var complete: Boolean? = null
}

data class UmpProcessingResult(
  var data: ByteArray? = null,
  var done: Boolean,
)

class SabrUmpProcessor(
  private val requestMetadata: SabrRequestMetadata,
  private val cacheManager: CacheManager? = null,
) {
  private val formatInitMetadata = mutableListOf<FormatInitializationMetadata>()
  private var desiredHeaderId: Int? = null
  private val partialSegments = HashMap<Int, Segment>()
  private val umpReader: UmpReader

  private var returnData: UmpProcessingResult? = null

  init {
    umpReader = UmpReader(
      UmpReaderCallbacks(
        onPart = { type, data ->
          val part = Part(type = type, size = data.getLength(), data = data)
          val result = handlePart(part)
          if (result != null) {
            desiredHeaderId = null
            partialSegments.clear()
            returnData = result
          }
        },
      ),
    )
  }

  suspend fun processChunk(value: ByteArray): UmpProcessingResult? {
    returnData = null
    umpReader.feed(value)
    return returnData
  }

  private fun handlePart(part: Part): UmpProcessingResult? = when (UMPPartId.forNumber(part.type)) {
    UMPPartId.FORMAT_INITIALIZATION_METADATA -> handleFormatInitMetadata(part)
    UMPPartId.NEXT_REQUEST_POLICY -> handleNextRequestPolicy(part)
    UMPPartId.SABR_ERROR -> handleSabrError(part)
    UMPPartId.SABR_REDIRECT -> handleSabrRedirect(part)
    UMPPartId.SABR_CONTEXT_UPDATE -> handleSabrContextUpdate(part)
    UMPPartId.SABR_CONTEXT_SENDING_POLICY -> handleSabrContextSendingPolicy(part)
    UMPPartId.SNACKBAR_MESSAGE -> handleSnackbarMessage(part)
    UMPPartId.STREAM_PROTECTION_STATUS -> handleStreamProtectionStatus(part)
    UMPPartId.RELOAD_PLAYER_RESPONSE -> handleReloadPlayerResponse(part)
    UMPPartId.MEDIA_HEADER -> handleMediaHeader(part)
    UMPPartId.MEDIA -> handleMedia(part)
    UMPPartId.MEDIA_END -> handleMediaEnd(part)
    else -> null
  }

  private fun updateStreamInfo(update: (SabrRequestStreamInfo) -> Unit) {
    val streamInfo = requestMetadata.streamInfo ?: SabrRequestStreamInfo()
    update(streamInfo)
    requestMetadata.streamInfo = streamInfo
  }

  private fun handleFormatInitMetadata(part: Part): UmpProcessingResult? {
    decodePart(part.data.chunks, FormatInitializationMetadata.parser())?.let { formatInitMetadata.add(it) }
    return null
  }

  private fun handleNextRequestPolicy(part: Part): UmpProcessingResult? {
    decodePart(part.data.chunks, NextRequestPolicy.parser())?.let { nextRequestPolicy ->
      updateStreamInfo { it.nextRequestPolicy = nextRequestPolicy }
    }
    return null
  }

  private fun handleMediaHeader(part: Part): UmpProcessingResult? {
    val mediaHeader = decodePart(part.data.chunks, MediaHeader.parser()) ?: return null

    val targetFormatKey = createFormatKey(requestMetadata.format!!)
    val segmentFormatKey = createFormatKey(mediaHeader)

    if (requestMetadata.isSABR != true || segmentFormatKey == targetFormatKey) {
      val headerId = if (mediaHeader.hasHeaderId()) mediaHeader.headerId else null

      val segmentObj = Segment(
        headerId = headerId,
        mediaHeader = mediaHeader,
        bufferedChunks = mutableListOf(),
        lastChunkSize = 0,
      )

      if (desiredHeaderId == null) {
        desiredHeaderId = headerId
      }

      partialSegments[headerId ?: 0] = segmentObj
    }

    return null
  }

  private fun handleMedia(part: Part): UmpProcessingResult? {
    val headerId = part.data.getUint8(0)
    val buffer = part.data.split(1).remainingBuffer

    val segment = partialSegments[headerId]
    if (segment != null) {
      segment.lastChunkSize = buffer.getLength()
      for (chunk in buffer.chunks) {
        segment.bufferedChunks.add(chunk)
      }
    }

    return null
  }

  private fun handleMediaEnd(part: Part): UmpProcessingResult? {
    val headerId = part.data.getUint8(0)

    val segment = partialSegments[headerId]
    if (segment != null && segment.headerId == desiredHeaderId) {
      val segmentData = concatenateChunks(segment.bufferedChunks)

      updateStreamInfo {
        it.formatInitMetadata = formatInitMetadata.toList()
        it.mediaHeader = segment.mediaHeader
      }

      val byteRange = requestMetadata.byteRange
      val format = requestMetadata.format
      if (requestMetadata.isInit == true && byteRange != null && format != null) {
        cacheManager?.setInitSegment(
          createSegmentCacheKey(segment.mediaHeader, format),
          segmentData,
        )

        val start = byteRange.start.coerceIn(0, segmentData.size.toLong()).toInt()
        val end = (byteRange.end + 1).coerceIn(start.toLong(), segmentData.size.toLong()).toInt()

        return UmpProcessingResult(
          data = segmentData.copyOfRange(start, end),
          done = true,
        )
      }

      return UmpProcessingResult(
        data = segmentData,
        done = true,
      )
    }

    return null
  }

  private fun handleSnackbarMessage(part: Part): UmpProcessingResult? {
    decodePart(part.data.chunks, SnackbarMessage.parser())?.let { snackbarMessage ->
      updateStreamInfo { it.snackbarMessage = snackbarMessage }
    }
    return null
  }

  private fun handleSabrError(part: Part): UmpProcessingResult {
    val sabrError = decodePart(part.data.chunks, SabrError.parser())
    requestMetadata.error = SabrRequestError(sabrError = sabrError)
    return UmpProcessingResult(done = true)
  }

  private fun handleStreamProtectionStatus(part: Part): UmpProcessingResult? {
    val streamProtectionStatus = decodePart(part.data.chunks, StreamProtectionStatus.parser()) ?: return null

    updateStreamInfo { it.streamProtectionStatus = streamProtectionStatus }

    if (streamProtectionStatus.status == 3) {
      return UmpProcessingResult(done = true)
    }

    return null
  }

  private fun handleReloadPlayerResponse(part: Part): UmpProcessingResult? {
    val reloadPlaybackContext = decodePart(part.data.chunks, ReloadPlaybackContext.parser()) ?: return null

    updateStreamInfo { it.reloadPlaybackContext = reloadPlaybackContext }

    return UmpProcessingResult(done = true)
  }

  private fun handleSabrRedirect(part: Part): UmpProcessingResult? {
    val redirect = decodePart(part.data.chunks, SabrRedirect.parser()) ?: return null

    updateStreamInfo { it.redirect = redirect }

    if (requestMetadata.isUMP == true && requestMetadata.isSABR != true) {
      return UmpProcessingResult(done = true)
    }

    return null
  }

  private fun handleSabrContextUpdate(part: Part): UmpProcessingResult? {
    decodePart(part.data.chunks, SabrContextUpdate.parser())?.let { sabrContextUpdate ->
      updateStreamInfo { it.sabrContextUpdate = sabrContextUpdate }
    }
    return null
  }

  private fun handleSabrContextSendingPolicy(part: Part): UmpProcessingResult? {
    decodePart(part.data.chunks, SabrContextSendingPolicy.parser())?.let { sabrContextSendingPolicy ->
      updateStreamInfo { it.sabrContextSendingPolicy = sabrContextSendingPolicy }
    }
    return null
  }

  fun dispose() {
    returnData = null
    desiredHeaderId = null
    partialSegments.clear()
    umpReader.dispose()
  }
}
