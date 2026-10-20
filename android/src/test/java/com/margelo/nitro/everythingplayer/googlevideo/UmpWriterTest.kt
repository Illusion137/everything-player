package com.margelo.nitro.everythingplayer.googlevideo

import com.margelo.nitro.everythingplayer.googlevideo.core.CompositeBuffer
import com.margelo.nitro.everythingplayer.googlevideo.core.GoogleVideoError
import com.margelo.nitro.everythingplayer.googlevideo.core.UmpWriter
import com.margelo.nitro.everythingplayer.googlevideo.utils.concatenateChunks
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Test

class UmpWriterTest {
  private fun bytes(vararg values: Int) = ByteArray(values.size) { values[it].toByte() }

  @Test
  fun shouldEncodeVarIntPartTypesOfEveryLength() {
    val cases = listOf(
      1 to bytes(1),
      150 to bytes(0x96, 0x02),
      20_000 to bytes(0xc0, 0x71, 0x02),
      10_000_000 to bytes(0xe0, 0x68, 0x89, 0x09),
      300_000_000 to bytes(0xf0, 0x00, 0xa3, 0xe1, 0x11),
    )

    for ((partType, encodedType) in cases) {
      val buffer = CompositeBuffer()
      val writer = UmpWriter(buffer)

      writer.write(partType, bytes(42))

      assertArrayEquals("partType=$partType", encodedType + bytes(1, 42), concatenateChunks(buffer.chunks))
    }
  }

  @Test
  fun shouldWriteMultiplePartsSequentially() {
    val buffer = CompositeBuffer()
    val umpWriter = UmpWriter(buffer)

    umpWriter.write(1, bytes(1, 2))
    umpWriter.write(2, bytes(3, 4, 5))
    umpWriter.write(3, bytes(6, 7, 8, 9))

    val expected = bytes(
      1, 2, 1, 2,
      2, 3, 3, 4, 5,
      3, 4, 6, 7, 8, 9,
    )

    assertArrayEquals(expected, concatenateChunks(buffer.chunks))
  }

  @Test
  fun shouldThrowAnErrorForNegativeVarIntValue() {
    val buffer = CompositeBuffer()
    val umpWriter = UmpWriter(buffer)
    val error = assertThrows(GoogleVideoError::class.java) { umpWriter.write(-1, ByteArray(0)) }
    assertEquals("VarInt value cannot be negative.", error.message)
  }
}
