package com.margelo.nitro.everythingplayer.engine

import android.net.Uri
import androidx.annotation.OptIn
import androidx.media3.common.C
import androidx.media3.common.util.UnstableApi
import androidx.media3.datasource.BaseDataSource
import androidx.media3.datasource.DataSource
import androidx.media3.datasource.DataSpec
import androidx.media3.datasource.FileDataSource
import androidx.media3.exoplayer.source.MediaSource
import androidx.media3.exoplayer.source.ProgressiveMediaSource
import androidx.media3.exoplayer.upstream.DefaultLoadErrorHandlingPolicy
import androidx.media3.exoplayer.upstream.LoadErrorHandlingPolicy
import androidx.media3.extractor.ChunkIndex
import androidx.media3.extractor.Extractor
import androidx.media3.extractor.ExtractorInput
import androidx.media3.extractor.ExtractorOutput
import androidx.media3.extractor.ExtractorsFactory
import androidx.media3.extractor.PositionHolder
import androidx.media3.extractor.SeekMap
import androidx.media3.extractor.SeekPoint
import androidx.media3.extractor.mkv.MatroskaExtractor
import androidx.media3.extractor.mp4.FragmentedMp4Extractor
import androidx.media3.extractor.text.SubtitleParser
import com.margelo.nitro.everythingplayer.googlevideo.types.StreamStartResult
import com.margelo.nitro.everythingplayer.googlevideo.utils.MediaType
import com.margelo.nitro.everythingplayer.googlevideo.utils.ReadableStream
import kotlinx.coroutines.runBlocking
import java.io.File
import java.io.IOException
import java.io.InterruptedIOException
import java.io.RandomAccessFile
import java.util.EnumMap

class EPSabrFeedException(val generation: Int, cause: Throwable) : IOException(cause.message ?: cause.toString(), cause)

@OptIn(UnstableApi::class)
class EPSabrMediaHub(
  private val seek: (Long) -> StreamStartResult?,
  initial: StreamStartResult,
  initialStartMs: Long,
  val generation: Int,
) {
  private class Feed {
    var epoch = -1
    var basePosition = 0L
    var delivered = 0L
    var mediaChunks = 0
    var skipInit = false
    var initSegment: ByteArray? = null
    var pending: ByteArray? = null
    var pendingOffset = 0
  }

  private val lock = Any()
  private var epoch = 0
  private var epochStartMs = initialStartMs
  private var readers = readersOf(initial)
  private val feeds = EnumMap<MediaType, Feed>(MediaType::class.java)

  @Volatile var producedAudio = false
    private set

  private fun readersOf(result: StreamStartResult): Map<MediaType, ReadableStream.Reader<ByteArray>> = mapOf(
    MediaType.AUDIO to result.audioStream.getReader(),
    MediaType.VIDEO to result.videoStream.getReader(),
  )

  private fun feed(type: MediaType): Feed = feeds.getOrPut(type) { Feed() }

  fun open(type: MediaType, position: Long) {
    android.util.Log.d("EPDBG", "hub$generation open ${type.rawValue} pos=$position base=${position / SEEK_BASE} off=${position % SEEK_BASE} epoch=$epoch start=$epochStartMs feed=${feeds[type]?.epoch}/${feeds[type]?.delivered}/${feeds[type]?.mediaChunks}")
    synchronized(lock) {
      val feed = feed(type)
      val base = if (position < SEEK_BASE) 0L else position - position % SEEK_BASE
      val offset = position - base
      if (offset > 0) {
        if (feed.epoch >= 0 && feed.basePosition == base && feed.delivered == offset) return
        throw EPSabrFeedException(generation, IOException("Cannot resume SABR ${type.rawValue} stream at $position"))
      }
      val target = if (base == 0L) null else base / SEEK_BASE - 1
      when {
        feed.epoch < 0 && epoch == 0 && target == null -> attach(feed, skipInit = false)
        target == null -> seekLocked(feed, epochStartMs)
        else -> seekLocked(feed, target)
      }
      feed.basePosition = base
      feed.delivered = 0
    }
  }

  private fun attach(feed: Feed, skipInit: Boolean) {
    feed.epoch = epoch
    feed.mediaChunks = 0
    feed.skipInit = skipInit
    feed.pending = null
    feed.pendingOffset = 0
  }

  private fun seekLocked(feed: Feed, targetMs: Long) {
    if (targetMs == epochStartMs) {
      if (feed.epoch == epoch && feed.mediaChunks == 0) {
        feed.pending = null
        return
      }
      if (feed.epoch < epoch) {
        attach(feed, skipInit = feed.initSegment != null)
        return
      }
    }
    val result = seek(targetMs)
      ?: throw EPSabrFeedException(generation, IOException("SABR stream cannot seek to ${targetMs}ms"))
    android.util.Log.d("EPDBG", "hub$generation SABR SEEK to ${targetMs}ms")
    epoch += 1
    epochStartMs = targetMs
    readers = readersOf(result)
    attach(feed, skipInit = feed.initSegment != null)
  }

  fun read(type: MediaType, buffer: ByteArray, offset: Int, length: Int): Int {
    if (length == 0) return 0
    val feed = synchronized(lock) { feed(type) }
    while (true) {
      val pending = feed.pending
      if (pending != null) {
        val count = minOf(length, pending.size - feed.pendingOffset)
        System.arraycopy(pending, feed.pendingOffset, buffer, offset, count)
        feed.pendingOffset += count
        feed.delivered += count
        if (feed.pendingOffset >= pending.size) {
          feed.pending = null
          feed.pendingOffset = 0
        }
        return count
      }

      val reader = synchronized(lock) { readers.getValue(type) }
      val result = try {
        runBlocking { reader.read() }
      } catch (e: InterruptedException) {
        throw InterruptedIOException()
      } catch (e: Throwable) {
        throw EPSabrFeedException(generation, e)
      }

      val chunk = result.value
      if (result.done || chunk == null) {
        val switched = synchronized(lock) {
          if (feed.epoch < epoch) {
            attach(feed, skipInit = feed.initSegment != null)
            true
          } else {
            false
          }
        }
        if (switched) continue
        android.util.Log.d("EPDBG", "hub$generation EOF ${type.rawValue}")
        return C.RESULT_END_OF_INPUT
      }

      synchronized(lock) {
        if (feed.epoch < epoch) attach(feed, skipInit = feed.initSegment != null)
      }

      val init = feed.initSegment
      if (feed.skipInit && init != null && init.contentEquals(chunk)) {
        feed.skipInit = false
        continue
      }
      feed.skipInit = false
      if (init == null) {
        feed.initSegment = chunk
      } else {
        feed.mediaChunks += 1
        if (type == MediaType.AUDIO) producedAudio = true
      }
      if (feed.mediaChunks == 1) android.util.Log.d("EPDBG", "hub$generation first media chunk ${type.rawValue} epoch=${feed.epoch} bytes=${chunk.size}")
      feed.pending = chunk
      feed.pendingOffset = 0
    }
  }

  fun dataSourceFactory(type: MediaType): DataSource.Factory = DataSource.Factory { EPSabrDataSource(this, type) }

  companion object {
    const val SEEK_BASE = 1L shl 36

    fun positionFor(timeUs: Long): Long = SEEK_BASE * (maxOf(0L, timeUs) / 1000 + 1)
  }
}

@OptIn(UnstableApi::class)
private class EPSabrDataSource(private val hub: EPSabrMediaHub, private val type: MediaType) : BaseDataSource(true) {
  private var uri: Uri? = null
  private var opened = false

  override fun open(dataSpec: DataSpec): Long {
    transferInitializing(dataSpec)
    hub.open(type, dataSpec.position)
    uri = dataSpec.uri
    opened = true
    transferStarted(dataSpec)
    return C.LENGTH_UNSET.toLong()
  }

  override fun read(buffer: ByteArray, offset: Int, length: Int): Int {
    val read = hub.read(type, buffer, offset, length)
    if (read > 0) bytesTransferred(read)
    return read
  }

  override fun getUri(): Uri? = uri

  override fun close() {
    uri = null
    if (opened) {
      opened = false
      transferEnded()
    }
  }
}

@OptIn(UnstableApi::class)
private class EPSeekMapExtractor(
  private val delegate: Extractor,
  private val seekMap: (SeekMap) -> SeekMap,
) : Extractor {
  override fun sniff(input: ExtractorInput): Boolean = delegate.sniff(input)

  override fun init(output: ExtractorOutput) {
    delegate.init(object : ExtractorOutput by output {
      override fun seekMap(seekMap: SeekMap) {
        output.seekMap(this@EPSeekMapExtractor.seekMap(seekMap))
      }
    })
  }

  override fun read(input: ExtractorInput, seekPosition: PositionHolder): Int = delegate.read(input, seekPosition)

  override fun seek(position: Long, timeUs: Long) = delegate.seek(position, timeUs)

  override fun release() = delegate.release()
}

@OptIn(UnstableApi::class)
private class EPSabrSeekMap(private val durationUs: Long) : SeekMap {
  override fun isSeekable(): Boolean = true

  override fun getDurationUs(): Long = durationUs

  override fun getSeekPoints(timeUs: Long): SeekMap.SeekPoints =
    SeekMap.SeekPoints(SeekPoint(timeUs, EPSabrMediaHub.positionFor(timeUs)))
}

@OptIn(UnstableApi::class)
object EPSabrMedia {
  private const val CONTINUE_LOADING_CHECK_INTERVAL_BYTES = 8 shl 20

  private val loadErrorPolicy = object : DefaultLoadErrorHandlingPolicy() {
    override fun getRetryDelayMsFor(loadErrorInfo: LoadErrorHandlingPolicy.LoadErrorInfo): Long {
      var cause: Throwable? = loadErrorInfo.exception
      while (cause != null) {
        if (cause is EPSabrFeedException) return C.TIME_UNSET
        cause = cause.cause
      }
      return super.getRetryDelayMsFor(loadErrorInfo)
    }
  }

  private fun baseExtractor(isWebm: Boolean): Extractor =
    if (isWebm) {
      MatroskaExtractor(SubtitleParser.Factory.UNSUPPORTED, MatroskaExtractor.FLAG_DISABLE_SEEK_FOR_CUES)
    } else {
      FragmentedMp4Extractor(SubtitleParser.Factory.UNSUPPORTED, 0)
    }

  fun streamSource(hub: EPSabrMediaHub, type: MediaType, isWebm: Boolean, durationUs: Long): MediaSource {
    val extractors = ExtractorsFactory {
      arrayOf(EPSeekMapExtractor(baseExtractor(isWebm)) { original -> EPSabrSeekMap(durationUs.takeIf { it > 0 } ?: original.durationUs) })
    }
    return ProgressiveMediaSource.Factory(hub.dataSourceFactory(type), extractors)
      .setLoadErrorHandlingPolicy(loadErrorPolicy)
      .setContinueLoadingCheckIntervalBytes(CONTINUE_LOADING_CHECK_INTERVAL_BYTES)
      .createMediaSource(androidx.media3.common.MediaItem.fromUri(Uri.parse("sabr://${type.rawValue}")))
  }

  fun fileSource(file: File, isWebm: Boolean, durationUs: Long): MediaSource {
    val index = runCatching { if (isWebm) webmIndex(file) else mp4Index(file) }.getOrNull()
    val extractors = ExtractorsFactory {
      arrayOf(
        EPSeekMapExtractor(baseExtractor(isWebm)) { original ->
          val duration = durationUs.takeIf { it > 0 } ?: original.durationUs
          index?.let { chunkIndex(it, file.length(), duration) } ?: original
        },
      )
    }
    return ProgressiveMediaSource.Factory(FileDataSource.Factory(), extractors)
      .createMediaSource(androidx.media3.common.MediaItem.fromUri(Uri.fromFile(file)))
  }

  private fun chunkIndex(points: List<Pair<Long, Long>>, fileLength: Long, durationUs: Long): SeekMap? {
    if (points.isEmpty()) return null
    val offsets = LongArray(points.size) { points[it].first }
    val times = LongArray(points.size) { points[it].second }
    val sizes = IntArray(points.size) { i ->
      ((if (i + 1 < points.size) offsets[i + 1] else fileLength) - offsets[i]).coerceIn(0, Int.MAX_VALUE.toLong()).toInt()
    }
    val end = if (durationUs != C.TIME_UNSET && durationUs > times.last()) durationUs else times.last()
    val durations = LongArray(points.size) { i -> maxOf(0L, (if (i + 1 < points.size) times[i + 1] else end) - times[i]) }
    return ChunkIndex(sizes, offsets, durations, times)
  }

  private fun RandomAccessFile.u32(at: Long): Long {
    seek(at)
    return readInt().toLong() and 0xffffffffL
  }

  private fun RandomAccessFile.type(at: Long): String {
    seek(at)
    val bytes = ByteArray(4)
    readFully(bytes)
    return String(bytes, Charsets.US_ASCII)
  }

  private fun RandomAccessFile.boxSize(at: Long): Pair<Long, Int> {
    val size = u32(at)
    return when (size) {
      1L -> {
        seek(at + 8)
        readLong() to 16
      }
      0L -> (length() - at) to 8
      else -> size to 8
    }
  }

  private fun RandomAccessFile.children(start: Long, end: Long, block: (String, Long, Long, Int) -> Unit) {
    var at = start
    while (at + 8 <= end) {
      val (size, header) = boxSize(at)
      if (size < header) break
      block(type(at + 4), at, size, header)
      at += size
    }
  }

  fun mp4Index(file: File): List<Pair<Long, Long>> = RandomAccessFile(file, "r").use { raf ->
    var timescale = 0L
    val moofs = mutableListOf<Pair<Long, Long>>()
    raf.children(0, raf.length()) { type, at, size, header ->
      when (type) {
        "moov" -> raf.children(at + header, at + size) { t, a, s, h ->
          if (t == "trak" && timescale == 0L) raf.children(a + h, a + s) { t2, a2, s2, h2 ->
            if (t2 == "mdia") raf.children(a2 + h2, a2 + s2) { t3, a3, _, h3 ->
              if (t3 == "mdhd") {
                raf.seek(a3 + h3)
                val version = raf.readUnsignedByte()
                timescale = raf.u32(a3 + h3 + if (version == 1) 20 else 12)
              }
            }
          }
        }
        "moof" -> raf.children(at + header, at + size) { t, a, s, h ->
          if (t == "traf") raf.children(a + h, a + s) { t2, a2, _, h2 ->
            if (t2 == "tfdt") {
              raf.seek(a2 + h2)
              val version = raf.readUnsignedByte()
              val decodeTime = if (version == 1) {
                raf.seek(a2 + h2 + 4)
                raf.readLong()
              } else {
                raf.u32(a2 + h2 + 4)
              }
              if (moofs.lastOrNull()?.first != at) moofs.add(at to decodeTime)
            }
          }
        }
      }
    }
    if (timescale <= 0) return@use emptyList()
    moofs.map { (offset, ticks) -> offset to ticks * 1_000_000 / timescale }
  }

  private fun RandomAccessFile.vint(keepMarker: Boolean): Pair<Long, Int>? {
    val first = read()
    if (first < 0) return null
    var length = 1
    var mask = 0x80
    while (length <= 8 && first and mask == 0) {
      length++
      mask = mask shr 1
    }
    if (length > 8) return null
    var value = (if (keepMarker) first else first and (mask - 1)).toLong()
    var allOnes = first and (mask - 1) == mask - 1
    repeat(length - 1) {
      val b = read()
      if (b < 0) return null
      if (b != 0xff) allOnes = false
      value = (value shl 8) or b.toLong()
    }
    return (if (!keepMarker && allOnes) -1L else value) to length
  }

  private fun RandomAccessFile.uint(size: Long): Long {
    var value = 0L
    repeat(size.toInt()) { value = (value shl 8) or read().toLong() }
    return value
  }

  fun webmIndex(file: File): List<Pair<Long, Long>> = RandomAccessFile(file, "r").use { raf ->
    val length = raf.length()
    var timecodeScale = 1_000_000L
    val clusters = mutableListOf<Pair<Long, Long>>()
    var at = 0L
    var inSegment = false
    while (at < length) {
      raf.seek(at)
      val (id, idLength) = raf.vint(keepMarker = true) ?: break
      val (size, sizeLength) = raf.vint(keepMarker = false) ?: break
      val dataStart = at + idLength + sizeLength
      when {
        id == 0x18538067L -> {
          inSegment = true
          at = dataStart
          continue
        }
        inSegment && id == 0x1549A966L && size > 0 -> {
          var child = dataStart
          while (child < dataStart + size) {
            raf.seek(child)
            val (cid, cidLength) = raf.vint(keepMarker = true) ?: break
            val (csize, csizeLength) = raf.vint(keepMarker = false) ?: break
            if (cid == 0x2AD7B1L) {
              raf.seek(child + cidLength + csizeLength)
              timecodeScale = raf.uint(csize)
            }
            if (csize < 0) break
            child += cidLength + csizeLength + csize
          }
        }
        inSegment && id == 0x1F43B675L -> {
          raf.seek(dataStart)
          val (cid, _) = raf.vint(keepMarker = true) ?: break
          val (csize, _) = raf.vint(keepMarker = false) ?: break
          if (cid == 0xE7L && csize in 1..8) clusters.add(at to raf.uint(csize) * timecodeScale / 1000)
        }
      }
      if (size < 0) break
      at = dataStart + size
    }
    clusters
  }
}
