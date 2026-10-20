package com.margelo.nitro.everythingplayer.engine

import androidx.media3.common.C
import com.margelo.nitro.everythingplayer.googlevideo.AUDIO_FORMAT
import com.margelo.nitro.everythingplayer.googlevideo.MockSabrServer
import com.margelo.nitro.everythingplayer.googlevideo.TOTAL_SEGMENTS
import com.margelo.nitro.everythingplayer.googlevideo.createSabrStream
import com.margelo.nitro.everythingplayer.googlevideo.types.FormatSelector
import com.margelo.nitro.everythingplayer.googlevideo.types.SabrPlaybackOptions
import com.margelo.nitro.everythingplayer.googlevideo.utils.EnabledTrackTypes
import com.margelo.nitro.everythingplayer.googlevideo.utils.LogLevel
import com.margelo.nitro.everythingplayer.googlevideo.utils.Logger
import com.margelo.nitro.everythingplayer.googlevideo.utils.MediaType
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import java.io.ByteArrayOutputStream
import java.io.File

class SabrMediaTest {
  private val segmentSize = (AUDIO_FORMAT.contentLength!! / (TOTAL_SEGMENTS + 1)).toInt()

  @Before
  fun setUp() {
    Logger.getInstance().setLogLevels(LogLevel.NONE)
  }

  private fun hub(server: MockSabrServer, generation: Int = 1, maxRetries: Int? = null): EPSabrMediaHub {
    val stream = createSabrStream(server)
    val result = stream.start(
      SabrPlaybackOptions(
        audioFormat = FormatSelector.Itag(AUDIO_FORMAT.itag),
        enabledTrackTypes = EnabledTrackTypes.AUDIO_ONLY,
        isPostLiveDvr = false,
        maxRetries = maxRetries,
      ),
    )
    return EPSabrMediaHub({ stream.seek(toMs = it) }, result, 0, generation)
  }

  private fun drain(hub: EPSabrMediaHub, limit: Int = Int.MAX_VALUE): ByteArray {
    val out = ByteArrayOutputStream()
    val buffer = ByteArray(7919)
    while (out.size() < limit) {
      val read = hub.read(MediaType.AUDIO, buffer, 0, minOf(buffer.size, limit - out.size()))
      if (read == C.RESULT_END_OF_INPUT) break
      out.write(buffer, 0, read)
    }
    return out.toByteArray()
  }

  @Test
  fun deliversTheInitialStreamUntilEndOfInput() {
    val hub = hub(MockSabrServer())
    hub.open(MediaType.AUDIO, 0)
    val bytes = drain(hub)
    assertEquals(AUDIO_FORMAT.contentLength!!.toInt(), bytes.size)
    assertTrue(bytes.take(segmentSize).all { it == 1.toByte() })
    assertTrue(hub.producedAudio)
  }

  @Test
  fun virtualSeekPositionsRestreamWithoutRepeatingTheInitSegment() {
    val server = MockSabrServer()
    val hub = hub(server)
    hub.open(MediaType.AUDIO, 0)
    assertEquals(segmentSize * 2, drain(hub, segmentSize * 2).size)

    val position = EPSabrMediaHub.positionFor(48_000_000)
    hub.open(MediaType.AUDIO, position)
    val afterSeek = drain(hub)
    assertEquals(segmentSize * TOTAL_SEGMENTS, afterSeek.size)
    assertTrue(afterSeek.all { it == 2.toByte() })
    assertTrue(server.requests.any { it.clientAbrState.playerTimeMs == 48_000L })
  }

  @Test
  fun resumesAContinuationAndRejectsUnknownOffsets() {
    val hub = hub(MockSabrServer())
    val base = EPSabrMediaHub.positionFor(0)
    hub.open(MediaType.AUDIO, base)
    val first = drain(hub, 1000)
    hub.open(MediaType.AUDIO, base + first.size)
    val rest = drain(hub)
    assertEquals(AUDIO_FORMAT.contentLength!!.toInt(), first.size + rest.size)

    val error = assertThrows(EPSabrFeedException::class.java) { hub.open(MediaType.AUDIO, base + 12345) }
    assertEquals(1, error.generation)
  }

  @Test
  fun reportsStreamFailuresAsFeedExceptions() {
    val hub = hub(MockSabrServer(simulateSabrError = true), generation = 7, maxRetries = 0)
    hub.open(MediaType.AUDIO, 0)
    val error = assertThrows(EPSabrFeedException::class.java) { drain(hub) }
    assertEquals(7, error.generation)
    assertTrue(error.message!!.startsWith("SABR Error"))
  }

  private fun box(type: String, vararg children: ByteArray): ByteArray {
    val payload = children.fold(ByteArray(0)) { acc, c -> acc + c }
    val size = 8 + payload.size
    return byteArrayOf((size ushr 24).toByte(), (size ushr 16).toByte(), (size ushr 8).toByte(), size.toByte()) + type.toByteArray() + payload
  }

  private fun u32(v: Long) = ByteArray(4) { (v ushr (24 - it * 8)).toByte() }
  private fun u64(v: Long) = ByteArray(8) { (v ushr (56 - it * 8)).toByte() }

  @Test
  fun indexesFragmentedMp4Segments() {
    val mdhd = box("mdhd", u32(0), u32(0), u32(0), u32(48000), u32(0), u32(0))
    val moov = box("moov", box("trak", box("mdia", mdhd)))
    val ftyp = box("ftyp", ByteArray(8))
    fun moof(t: Long) = box("moof", box("mfhd", ByteArray(8)), box("traf", box("tfhd", ByteArray(8)), box("tfdt", u32(1 shl 24), u64(t))))
    val first = moof(0)
    val second = moof(48000L * 24)
    val mdat = box("mdat", ByteArray(32))
    val file = File.createTempFile("sabr", ".m4a").apply { writeBytes(ftyp + moov + first + mdat + second + mdat) }
    val index = EPSabrMedia.mp4Index(file)
    val firstOffset = (ftyp.size + moov.size).toLong()
    assertEquals(listOf(firstOffset to 0L, firstOffset + first.size + mdat.size to 24_000_000L), index)
    file.delete()
  }

  @Test
  fun indexesWebmClusters() {
    fun element(id: ByteArray, payload: ByteArray) = id + byteArrayOf((0x80 or payload.size).toByte()) + payload
    val ebml = element(byteArrayOf(0x1A, 0x45, 0xDF.toByte(), 0xA3.toByte()), ByteArray(4))
    val info = element(byteArrayOf(0x15, 0x49, 0xA9.toByte(), 0x66), element(byteArrayOf(0x2A, 0xD7.toByte(), 0xB1.toByte()), byteArrayOf(0x0F, 0x42, 0x40)))
    fun cluster(timecode: Int) = element(byteArrayOf(0x1F, 0x43, 0xB6.toByte(), 0x75), element(byteArrayOf(0xE7.toByte()), byteArrayOf((timecode ushr 8).toByte(), timecode.toByte())) + ByteArray(10))
    val segmentHeader = byteArrayOf(0x18, 0x53, 0x80.toByte(), 0x67, 0x01) + ByteArray(7) { 0xFF.toByte() }
    val c1 = cluster(0)
    val c2 = cluster(5000)
    val file = File.createTempFile("sabr", ".webm").apply { writeBytes(ebml + segmentHeader + info + c1 + c2) }
    val firstOffset = (ebml.size + segmentHeader.size + info.size).toLong()
    assertEquals(listOf(firstOffset to 0L, firstOffset + c1.size to 5_000_000L), EPSabrMedia.webmIndex(file))
    file.delete()
  }

  @Test
  fun picksQualitiesLikeIos() {
    val range = EPVideoQualityRange(maxHeight = 720)
    val heights = listOf(1080, 720, 480, 360)
    assertEquals(720, range.pick(heights, { it }, { it }))
    assertEquals(1080, EPVideoQualityRange(minHeight = 2160, maxHeight = null).pick(heights, { it }, { it }))
    assertEquals(360, EPVideoQualityRange(maxHeight = 240).pick(heights, { it }, { it }))
  }
}
