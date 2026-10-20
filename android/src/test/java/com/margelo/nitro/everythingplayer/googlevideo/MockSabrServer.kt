package com.margelo.nitro.everythingplayer.googlevideo

import com.margelo.nitro.everythingplayer.googlevideo.core.CompositeBuffer
import com.margelo.nitro.everythingplayer.googlevideo.core.SabrStream
import com.margelo.nitro.everythingplayer.googlevideo.core.UmpWriter
import com.margelo.nitro.everythingplayer.googlevideo.protos.video_streaming.FormatInitializationMetadata
import com.margelo.nitro.everythingplayer.googlevideo.protos.video_streaming.MediaHeader
import com.margelo.nitro.everythingplayer.googlevideo.protos.video_streaming.NextRequestPolicy
import com.margelo.nitro.everythingplayer.googlevideo.protos.video_streaming.SabrError
import com.margelo.nitro.everythingplayer.googlevideo.protos.video_streaming.StreamProtectionStatus
import com.margelo.nitro.everythingplayer.googlevideo.protos.video_streaming.UMPPartId
import com.margelo.nitro.everythingplayer.googlevideo.protos.video_streaming.VideoPlaybackAbrRequest
import com.margelo.nitro.everythingplayer.googlevideo.types.FetchFunction
import com.margelo.nitro.everythingplayer.googlevideo.types.FetchResponse
import com.margelo.nitro.everythingplayer.googlevideo.types.HttpResponse
import com.margelo.nitro.everythingplayer.googlevideo.types.SabrFormat
import com.margelo.nitro.everythingplayer.googlevideo.types.SabrStreamConfig
import com.margelo.nitro.everythingplayer.googlevideo.utils.ClientInfo
import com.margelo.nitro.everythingplayer.googlevideo.utils.FormatId
import com.margelo.nitro.everythingplayer.googlevideo.utils.ReadableStream
import com.margelo.nitro.everythingplayer.googlevideo.utils.concatenateChunks
import kotlinx.coroutines.channels.Channel
import java.nio.ByteBuffer
import java.util.concurrent.atomic.AtomicInteger
import kotlin.math.roundToLong

internal const val VIDEO_ID = "test-video-id"
internal const val TOTAL_SEGMENTS = 5
internal const val SEGMENT_DURATION_MS = 24000L
internal const val TOTAL_DURATION_MS = TOTAL_SEGMENTS * SEGMENT_DURATION_MS

internal val AUDIO_FORMAT = SabrFormat(
  itag = 140,
  lastModified = "1700000000",
  contentLength = 117138,
  mimeType = "audio/mp4; codecs=\"mp4a.40.2\"",
  bitrate = 128000,
  approxDurationMs = TOTAL_DURATION_MS,
)

internal val VIDEO_FORMAT = SabrFormat(
  itag = 137,
  lastModified = "1700000000",
  contentLength = 234270,
  mimeType = "video/mp4; codecs=\"avc1.640028\"",
  bitrate = 4337000,
  height = 1080,
  approxDurationMs = TOTAL_DURATION_MS,
)

internal val CLIENT_INFO: ClientInfo = ClientInfo.newBuilder()
  .setClientName(1)
  .setClientVersion("2.20690101.00.00")
  .build()

internal class MockSabrServer(
  private val streamProtectionStatus: Int = 1,
  private val streamProtectionMaxRetries: Int = 0,
  private val responseStatus: Int = 200,
  private val simulateSabrError: Boolean = false,
) {
  val calls = AtomicInteger(0)
  val requests = mutableListOf<VideoPlaybackAbrRequest>()
  private var nextHeaderId = 0

  private fun segmentSizeFor(format: SabrFormat) = ((format.contentLength ?: 0) / (TOTAL_SEGMENTS + 1)).toInt()

  private fun response(status: Int, body: ByteArray, headers: Map<String, String>): FetchResponse {
    val channel = Channel<ByteArray>(Channel.UNLIMITED)
    if (body.isNotEmpty()) channel.trySend(body)
    channel.close()
    return FetchResponse(HttpResponse("https://ytjs.dev/sabr", status, headers), channel) { channel.cancel() }
  }

  val fetch: FetchFunction = fetch@{ request ->
    calls.incrementAndGet()

    if (responseStatus != 200) {
      return@fetch response(responseStatus, ByteArray(0), emptyMap())
    }

    val requestBody = VideoPlaybackAbrRequest.parseFrom(request.body!!)
    synchronized(requests) { requests.add(requestBody) }

    val buffer = CompositeBuffer()
    val umpWriter = UmpWriter(buffer)

    umpWriter.write(UMPPartId.NEXT_REQUEST_POLICY_VALUE, NextRequestPolicy.newBuilder().setBackoffTimeMs(0).setVideoId(VIDEO_ID).build().toByteArray())
    umpWriter.write(
      UMPPartId.STREAM_PROTECTION_STATUS_VALUE,
      StreamProtectionStatus.newBuilder().setStatus(streamProtectionStatus).setMaxRetries(streamProtectionMaxRetries).build().toByteArray(),
    )

    if (simulateSabrError) {
      umpWriter.write(UMPPartId.SABR_ERROR_VALUE, SabrError.newBuilder().setType("whatthehell").setCode(123).build().toByteArray())
    } else {
      val requestedFormats = requestBody.selectedVideoFormatIdsList + requestBody.selectedAudioFormatIdsList

      val initializedFormats = requestBody.initializationFormatIdsList.map { it.itag }

      for (requestedFormat in requestedFormats) {
        val format = if (requestedFormat.itag == VIDEO_FORMAT.itag) VIDEO_FORMAT else AUDIO_FORMAT
        val segmentSize = segmentSizeFor(format)

        val bufferedRange = requestBody.bufferedRangesList.firstOrNull { it.formatId.itag == format.itag }
        val segmentsDownloaded = if (bufferedRange != null) (bufferedRange.durationMs.toDouble() / SEGMENT_DURATION_MS).roundToLong().toInt() else 0

        if (!initializedFormats.contains(format.itag)) {
          umpWriter.write(
            UMPPartId.FORMAT_INITIALIZATION_METADATA_VALUE,
            FormatInitializationMetadata.newBuilder()
              .setVideoId(VIDEO_ID)
              .setFormatId(FormatId(format))
              .setMimeType(format.mimeType)
              .setEndSegmentNum(TOTAL_SEGMENTS.toLong())
              .setEndTimeMs(TOTAL_DURATION_MS)
              .setEndTimeTicks(TOTAL_DURATION_MS)
              .setEndTimeTimescale(1000)
              .build()
              .toByteArray(),
          )

          val initHeaderId = nextHeaderId++
          umpWriter.write(
            UMPPartId.MEDIA_HEADER_VALUE,
            MediaHeader.newBuilder()
              .setHeaderId(initHeaderId)
              .setVideoId(VIDEO_ID)
              .setItag(format.itag)
              .setLmt(format.lastModified.toLong())
              .setFormatId(FormatId(format))
              .setIsInitializationSegment(true)
              .setSegmentNum(0)
              .setSegmentByteRangeStart(0)
              .setSegmentLengthBytes(segmentSize.toLong())
              .setStartMs(0)
              .setDurationMs(0)
              .build()
              .toByteArray(),
          )
          umpWriter.write(UMPPartId.MEDIA_VALUE, byteArrayOf(initHeaderId.toByte()) + ByteArray(segmentSize) { 1 })
          umpWriter.write(UMPPartId.MEDIA_END_VALUE, byteArrayOf(initHeaderId.toByte()))
        }

        if (segmentsDownloaded >= TOTAL_SEGMENTS) {
          continue
        }

        val segmentNum = segmentsDownloaded + 1
        val startMs = segmentsDownloaded * SEGMENT_DURATION_MS
        val startRange = (segmentsDownloaded + 1).toLong() * segmentSize

        val headerId = nextHeaderId++
        umpWriter.write(
          UMPPartId.MEDIA_HEADER_VALUE,
          MediaHeader.newBuilder()
            .setHeaderId(headerId)
            .setVideoId(VIDEO_ID)
            .setItag(format.itag)
            .setLmt(format.lastModified.toLong())
            .setFormatId(FormatId(format))
            .setIsInitializationSegment(false)
            .setSegmentNum(segmentNum)
            .setSegmentByteRangeStart(startRange)
            .setSegmentLengthBytes(segmentSize.toLong())
            .setStartMs(startMs)
            .setDurationMs(SEGMENT_DURATION_MS)
            .build()
            .toByteArray(),
        )
        umpWriter.write(UMPPartId.MEDIA_VALUE, byteArrayOf(headerId.toByte()) + ByteArray(segmentSize) { 2 })
        umpWriter.write(UMPPartId.MEDIA_END_VALUE, byteArrayOf(headerId.toByte()))
      }
    }

    response(200, concatenateChunks(buffer.chunks), mapOf("content-type" to "application/vnd.yt-ump"))
  }
}

internal suspend fun collectStreamChunks(stream: ReadableStream<ByteArray>): List<ByteArray> {
  val chunks = mutableListOf<ByteArray>()
  val reader = stream.getReader()

  while (true) {
    val (done, value) = reader.read()
    if (done) break
    chunks.add(value!!)
  }

  return chunks
}

internal fun totalLength(chunks: List<ByteArray>) = concatenateChunks(chunks.map { ByteBuffer.wrap(it) }).size.toLong()

internal fun createSabrStream(server: MockSabrServer) = SabrStream(
  SabrStreamConfig(
    videoId = VIDEO_ID,
    fetchFunction = server.fetch,
    serverAbrStreamingUrl = "https://ytjs.dev/sabr",
    videoPlaybackUstreamerConfig = "abc",
    poToken = "abc",
    clientInfo = CLIENT_INFO,
    formats = listOf(VIDEO_FORMAT, AUDIO_FORMAT),
  ),
)

