package com.margelo.nitro.everythingplayer.googlevideo

import com.margelo.nitro.everythingplayer.googlevideo.protos.misc.FormatId
import com.margelo.nitro.everythingplayer.googlevideo.protos.video_streaming.MediaHeader
import com.margelo.nitro.everythingplayer.googlevideo.types.AudioFormatPreferences
import com.margelo.nitro.everythingplayer.googlevideo.types.FormatSelector
import com.margelo.nitro.everythingplayer.googlevideo.types.PreferredAudioCodec
import com.margelo.nitro.everythingplayer.googlevideo.types.SabrFormat
import com.margelo.nitro.everythingplayer.googlevideo.types.VideoFormatPreferences
import com.margelo.nitro.everythingplayer.googlevideo.utils.ByteRange
import com.margelo.nitro.everythingplayer.googlevideo.utils.FormatPreferences
import com.margelo.nitro.everythingplayer.googlevideo.utils.ReadableStream
import com.margelo.nitro.everythingplayer.googlevideo.utils.base64ToU8
import com.margelo.nitro.everythingplayer.googlevideo.utils.chooseFormat
import com.margelo.nitro.everythingplayer.googlevideo.utils.createFormatKey
import com.margelo.nitro.everythingplayer.googlevideo.utils.getBroadcastId
import com.margelo.nitro.everythingplayer.googlevideo.utils.getNextFallbackUrl
import com.margelo.nitro.everythingplayer.googlevideo.utils.parseEmsgSegmentMetadata
import com.margelo.nitro.everythingplayer.googlevideo.utils.parseRangeHeader
import com.margelo.nitro.everythingplayer.googlevideo.utils.searchParam
import com.margelo.nitro.everythingplayer.googlevideo.utils.settingSearchParam
import com.margelo.nitro.everythingplayer.googlevideo.utils.stripMp4Init
import com.margelo.nitro.everythingplayer.googlevideo.utils.stripWebmInit
import com.margelo.nitro.everythingplayer.googlevideo.utils.u8ToBase64
import kotlinx.coroutines.async
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.ByteArrayOutputStream

class UtilsTest {
  private fun bytes(vararg values: Int) = ByteArray(values.size) { values[it].toByte() }

  private fun box(type: String, payload: ByteArray): ByteArray {
    val size = 8 + payload.size
    return bytes(size ushr 24, size ushr 16, size ushr 8, size) + type.toByteArray() + payload
  }

  @Test
  fun readableStreamTracksDesiredSizeAndDeliversInOrder() = runBlocking {
    var controller: ReadableStream.Controller<ByteArray>? = null
    var pulls = 0
    val stream = ReadableStream<ByteArray>(10, { it.size }, start = { controller = it }, pull = { pulls++ })

    controller!!.enqueue(ByteArray(4))
    controller!!.enqueue(ByteArray(4))
    assertEquals(2, controller!!.desiredSize)
    assertFalse(stream.locked)

    val reader = stream.getReader()
    assertTrue(stream.locked)
    assertEquals(4, reader.read().value!!.size)
    assertEquals(6, controller!!.desiredSize)

    val pending = async { reader.read() }
    reader.read()
    controller!!.enqueue(bytes(7))
    delay(10)
    controller!!.close()
    assertArrayEquals(bytes(7), pending.await().value)
    assertTrue(reader.read().done)
    assertTrue(pulls >= 3)
  }

  @Test
  fun readableStreamPropagatesErrorsAndCancel() = runBlocking {
    var controller: ReadableStream.Controller<ByteArray>? = null
    var cancelReason: String? = null
    val stream = ReadableStream<ByteArray>(10, { it.size }, start = { controller = it }, onCancel = { cancelReason = it })
    val reader = stream.getReader()
    val pending = async { runCatching { reader.read() } }
    delay(10)
    controller!!.error(IllegalStateException("boom"))
    assertEquals("boom", pending.await().exceptionOrNull()?.message)
    assertNull(controller!!.desiredSize)

    var c2: ReadableStream.Controller<ByteArray>? = null
    val s2 = ReadableStream<ByteArray>(10, { it.size }, start = { c2 = it }, onCancel = { cancelReason = it })
    c2!!.enqueue(ByteArray(3))
    s2.getReader().cancel("bye")
    assertEquals("bye", cancelReason)
    assertTrue(s2.getReader().read().done)
  }

  @Test
  fun urlSearchParamsRoundTrip() {
    val url = "https://rr1---sn-abc.googlevideo.com/videoplayback?expire=123&id=o-AB.1&mn=sn-abc%2Csn-def&fvip=4#frag"
    assertEquals("123", url.searchParam("expire"))
    assertEquals("sn-abc,sn-def", url.searchParam("mn"))
    assertNull(url.searchParam("missing"))

    val updated = url.settingSearchParam("rn", "5").settingSearchParam("expire", "a&b=c+d")
    assertEquals("https://rr1---sn-abc.googlevideo.com/videoplayback?expire=a%26b%3Dc%2Bd&id=o-AB.1&mn=sn-abc%2Csn-def&fvip=4&rn=5#frag", updated)
    assertEquals("a&b=c+d", updated.searchParam("expire"))
    assertEquals("https://x.y/sabr?alr=no", "https://x.y/sabr".settingSearchParam("alr", "no"))
  }

  @Test
  fun fallbackUrlAndBroadcastId() {
    val url = "https://rr1---sn-abc.googlevideo.com/videoplayback?mn=sn-abc%2Csn-def&fvip=4&id=o-AB.2"
    assertEquals("https://rr4---sn-def.googlevideo.com/videoplayback?mn=sn-abc%2Csn-def&fvip=4&id=o-AB.2&fallback_count=1", getNextFallbackUrl(url))
    assertNull(getNextFallbackUrl(getNextFallbackUrl(url)!!))
    assertEquals("2", getBroadcastId(url))
    assertNull(getBroadcastId("https://a.b/c?id=abc"))
  }

  @Test
  fun rangeHeaderAndBase64() {
    assertEquals(ByteRange(100, 200), parseRangeHeader("bytes=100-200"))
    assertEquals(ByteRange(100, 0), parseRangeHeader("bytes=100-"))
    assertNull(parseRangeHeader("bytes"))
    assertNull(parseRangeHeader(null))

    val data = bytes(0xfb, 0xff, 0x01, 0x02)
    assertEquals("+/8BAg==", u8ToBase64(data))
    assertArrayEquals(data, base64ToU8("-_8BAg"))
    assertArrayEquals(ByteArray(0), base64ToU8("@@@"))
  }

  @Test
  fun formatKeysAndSelection() {
    val opus = SabrFormat(itag = 251, lastModified = "1", mimeType = "audio/webm; codecs=\"opus\"", bitrate = 130000, approxDurationMs = 1, audioQuality = "AUDIO_QUALITY_MEDIUM")
    val aac = SabrFormat(itag = 140, lastModified = "1", mimeType = "audio/mp4; codecs=\"mp4a.40.2\"", bitrate = 140000, approxDurationMs = 1, audioQuality = "AUDIO_QUALITY_MEDIUM")
    val low = SabrFormat(itag = 249, lastModified = "1", mimeType = "audio/webm; codecs=\"opus\"", bitrate = 50000, approxDurationMs = 1, audioQuality = "AUDIO_QUALITY_LOW")
    val v720 = SabrFormat(itag = 136, lastModified = "1", xtags = "x", mimeType = "video/mp4; codecs=\"avc1\"", bitrate = 1, height = 720, approxDurationMs = 1, qualityLabel = "720p")
    val v1080 = SabrFormat(itag = 137, lastModified = "1", mimeType = "video/mp4; codecs=\"avc1\"", bitrate = 1, height = 1080, approxDurationMs = 1, qualityLabel = "1080p")
    val formats = listOf(low, opus, aac, v720, v1080)

    assertEquals(aac, chooseFormat(formats, null, FormatPreferences(null as AudioFormatPreferences?)))
    assertEquals(opus, chooseFormat(formats, null, FormatPreferences(AudioFormatPreferences(preferredAudioCodec = PreferredAudioCodec.OPUS))))
    assertEquals(v1080, chooseFormat(formats, null, FormatPreferences(null as VideoFormatPreferences?)))
    assertEquals(v720, chooseFormat(formats, null, FormatPreferences(VideoFormatPreferences(quality = "720"))))
    assertEquals(low, chooseFormat(formats, FormatSelector.Itag(249), FormatPreferences(null as AudioFormatPreferences?)))
    assertNull(chooseFormat(formats, FormatSelector.Itag(136), FormatPreferences(null as AudioFormatPreferences?)))

    assertEquals("136:x", createFormatKey(v720))
    assertEquals("137:", createFormatKey(FormatId.newBuilder().setItag(137).build()))
    assertEquals("140:", createFormatKey(MediaHeader.newBuilder().setItag(140).build()))
    assertEquals("251:y", createFormatKey(MediaHeader.newBuilder().setItag(140).setFormatId(FormatId.newBuilder().setItag(251).setXtags("y")).build()))
  }

  @Test
  fun stripsDuplicateInitSegments() {
    val ftyp = box("ftyp", ByteArray(8))
    val moov = box("moov", ByteArray(16))
    val moof = box("moof", ByteArray(4))
    val mdat = box("mdat", ByteArray(4))
    assertArrayEquals(moof + mdat, stripMp4Init(ftyp + moov + moof + mdat))
    assertArrayEquals(ftyp, stripMp4Init(ftyp))

    val ebml = bytes(0x1A, 0x45, 0xDF, 0xA3, 0x82, 0, 0)
    val segmentHeader = bytes(0x18, 0x53, 0x80, 0x67, 0x01, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF)
    val info = bytes(0x15, 0x49, 0xA9, 0x66, 0x81, 0)
    val cluster = bytes(0x1F, 0x43, 0xB6, 0x75, 0x81, 0)
    assertArrayEquals(cluster, stripWebmInit(ebml + segmentHeader + info + cluster))
  }

  @Test
  fun parsesEmsgSegmentMetadata() {
    val message = "Sequence-Number: 42\r\nTarget-Duration-Us: 5000000\r\nIngestion-Walltime-Us: 1000000\r\n\r\n"
    val body = ByteArrayOutputStream().apply {
      write(ByteArray(4))
      write("urn:youtube\u0000".toByteArray())
      write("v\u0000".toByteArray())
      write(ByteArray(16))
      write(message.toByteArray())
    }.toByteArray()
    val metadata = parseEmsgSegmentMetadata(box("emsg", body) + box("moof", ByteArray(0)))!!
    assertEquals(42.0, metadata.segmentNumber, 0.0)
    assertEquals(5.0, metadata.targetDurationSec, 0.0)
    assertEquals(1.0, metadata.ingestionTimeSec, 0.0)
    assertEquals("urn:youtube", metadata.uri)
    assertNull(parseEmsgSegmentMetadata(box("moof", ByteArray(0))))
  }
}
