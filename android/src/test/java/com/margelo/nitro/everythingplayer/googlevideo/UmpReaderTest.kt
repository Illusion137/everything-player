package com.margelo.nitro.everythingplayer.googlevideo

import com.margelo.nitro.everythingplayer.googlevideo.core.CompositeBuffer
import com.margelo.nitro.everythingplayer.googlevideo.core.UmpReader
import com.margelo.nitro.everythingplayer.googlevideo.core.UmpReaderCallbacks
import com.margelo.nitro.everythingplayer.googlevideo.core.UmpWriter
import com.margelo.nitro.everythingplayer.googlevideo.utils.concatenateChunks
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Test
import java.nio.ByteBuffer

class UmpReaderTest {
  private fun bytes(vararg values: Int) = ByteArray(values.size) { values[it].toByte() }

  private class Recorder {
    val parts = mutableListOf<Pair<Int, CompositeBuffer>>()
    val callbacks = UmpReaderCallbacks(onPart = { type, data -> parts.add(type to data) })
  }

  @Test
  fun shouldReadASingleSmallPartCorrectly() = runBlocking {
    val buffer = CompositeBuffer()
    val writer = UmpWriter(buffer)

    val partType = 1
    val partData = bytes(10, 20, 30)
    writer.write(partType, partData)

    val recorder = Recorder()
    val reader = UmpReader(recorder.callbacks)

    reader.feed(buffer)

    assertEquals(1, recorder.parts.size)
    val (receivedPartType, receivedPartData) = recorder.parts[0]
    assertEquals(partType, receivedPartType)
    assertEquals(partData.size, receivedPartData.getLength())
    assertArrayEquals(partData, concatenateChunks(receivedPartData.chunks))
  }

  @Test
  fun shouldReadMultiplePartsSequentially() = runBlocking {
    val buffer = CompositeBuffer()
    val writer = UmpWriter(buffer)

    val partsToWrite = listOf(
      20 to bytes(1, 2),
      21 to bytes(3, 4, 5),
      150 to bytes(6, 7, 8, 9),
    )

    for ((type, data) in partsToWrite) {
      writer.write(type, data)
    }

    val recorder = Recorder()
    val reader = UmpReader(recorder.callbacks)

    reader.feed(buffer)

    assertEquals(partsToWrite.size, recorder.parts.size)

    for (i in partsToWrite.indices) {
      val (type, data) = recorder.parts[i]
      assertEquals(partsToWrite[i].first, type)
      assertEquals(partsToWrite[i].second.size, data.getLength())
      assertArrayEquals(partsToWrite[i].second, concatenateChunks(data.chunks))
    }
  }

  @Test
  fun shouldBufferIncompletePayloadsUntilTheyAreComplete() = runBlocking {
    val buffer = CompositeBuffer()
    val writer = UmpWriter(buffer)

    val partType = 5
    val partData = ByteArray(100) { 42 }
    writer.write(partType, partData)

    val headerSize = 2
    val firstChunk = buffer.split(headerSize + 50)
    val recorder = Recorder()

    val reader = UmpReader(recorder.callbacks)

    reader.feed(firstChunk.extractedBuffer)
    assertEquals(0, recorder.parts.size)

    reader.feed(firstChunk.remainingBuffer)
    assertEquals(1, recorder.parts.size)
    val (receivedPartType, receivedPartData) = recorder.parts[0]
    assertEquals(partType, receivedPartType)
    assertArrayEquals(partData, concatenateChunks(receivedPartData.chunks))
  }

  @Test
  fun shouldWaitForAnIncompleteHeader() = runBlocking {
    val recorder = Recorder()
    val reader = UmpReader(recorder.callbacks)

    reader.feed(ByteArray(0))
    reader.feed(bytes(0x96))
    assertEquals(0, recorder.parts.size)

    reader.feed(bytes(0x02, 1, 42))
    assertEquals(1, recorder.parts.size)
    val (type, data) = recorder.parts[0]
    assertEquals(150, type)
    assertArrayEquals(bytes(42), concatenateChunks(data.chunks))
  }

  @Test
  fun shouldReportAPartialPartWithA5ByteVarIntSize() = runBlocking {
    val calls = mutableListOf<List<Any>>()
    val reader = UmpReader(
      UmpReaderCallbacks(
        onPart = { _, _ -> },
        onPartialPart = { type, data, offset, totalSize ->
          calls.add(listOf(type, concatenateChunks(data.chunks), offset, totalSize))
          false
        },
      ),
    )

    reader.feed(bytes(15, 0xF0, 0x00, 0xA3, 0xE1, 0x11, 42))

    assertEquals(1, calls.size)
    val (type, data, offset, totalSize) = calls[0]
    assertEquals(15, type)
    assertArrayEquals(bytes(42), data as ByteArray)
    assertEquals(0L, offset)
    assertEquals(300000000L, totalSize)
  }

  @Test
  fun shouldHandleReadingFromMultipleChunks() = runBlocking {
    val partType = 1
    val partData = bytes(1, 2, 3, 4, 5, 6, 7, 8, 9, 10)

    val chunk1 = bytes(1, 10, 1, 2, 3)
    val chunk2 = bytes(4, 5, 6)
    val chunk3 = bytes(7, 8, 9, 10)
    val compositeBuffer = CompositeBuffer(listOf(chunk1, chunk2, chunk3).map { ByteBuffer.wrap(it) })

    val recorder = Recorder()
    val reader = UmpReader(recorder.callbacks)

    reader.feed(compositeBuffer)

    assertEquals(1, recorder.parts.size)
    val (receivedPartType, receivedPartData) = recorder.parts[0]

    assertEquals(partType, receivedPartType)
    assertEquals(partData.size, receivedPartData.getLength())
    assertArrayEquals(partData, concatenateChunks(receivedPartData.chunks))
  }
}
