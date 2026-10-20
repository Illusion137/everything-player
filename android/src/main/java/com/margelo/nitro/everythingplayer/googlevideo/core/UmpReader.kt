package com.margelo.nitro.everythingplayer.googlevideo.core

import java.nio.ByteBuffer

class UmpReaderCallbacks(
  /** Called when a complete UMP part is available. */
  val onPart: suspend (Int, CompositeBuffer) -> Unit,
  /** Only use this if you wish to handle partial UMP parts yourself. */
  val onPartialPart: ((Int, CompositeBuffer, Long, Long) -> Boolean)? = null,
)

/**
 * An efficient UMP reader.
 * @NOTE
 * Based on https://gist.github.com/LuanRT/7c8c79fa558f2430f0b85b09f8a9d818
 */
class UmpReader(private val callbacks: UmpReaderCallbacks) {
  private var compositeBuffer = CompositeBuffer()

  private var pendingType: Int? = null
  private var pendingOffset: Long? = null
  private var pendingTotalSize: Long? = null

  suspend fun feed(chunk: ByteArray) {
    compositeBuffer.append(chunk)
    parse()
  }

  suspend fun feed(chunk: ByteBuffer) {
    compositeBuffer.append(chunk)
    parse()
  }

  suspend fun feed(chunk: CompositeBuffer) {
    compositeBuffer.append(chunk)
    parse()
  }

  private suspend fun parse() {
    // Resume any previously interrupted partial payload block.
    if (pendingType != null) {
      if (compositeBuffer.totalLength == 0) return

      val needed = pendingTotalSize!! - pendingOffset!!
      val split = compositeBuffer.split(needed.coerceAtMost(Int.MAX_VALUE.toLong()).toInt())

      val onPartialPart = callbacks.onPartialPart ?: return
      if (!onPartialPart(pendingType!!, split.extractedBuffer, pendingOffset!!, pendingTotalSize!!)) {
        return
      }

      pendingOffset = pendingOffset!! + split.extractedBuffer.totalLength
      compositeBuffer = split.remainingBuffer

      if (pendingOffset == pendingTotalSize) {
        pendingType = null
        pendingTotalSize = null
        pendingOffset = null
      }
    }

    while (true) {
      var offset = 0

      val (partType, newOffset) = readVarInt(offset)
      offset = newOffset
      val (partSize, finalOffset) = readVarInt(offset)
      offset = finalOffset

      if (partType < 0 || partSize < 0) {
        break
      }

      // If we don't have the full payload available...
      if (!compositeBuffer.canReadBytes(offset, partSize)) {
        // If we can't read at least 1 byte of payload or don't have a paartial handler, wait for more data.
        if (!(callbacks.onPartialPart != null && compositeBuffer.canReadBytes(offset, 1))) {
          break
        }

        val remainingBuff = compositeBuffer.split(offset).remainingBuffer

        if (callbacks.onPartialPart.invoke(partType.toInt(), remainingBuff, 0, partSize)) {
          pendingType = partType.toInt()
          pendingOffset = remainingBuff.totalLength.toLong()
          pendingTotalSize = partSize
          compositeBuffer = CompositeBuffer()
        }
        break
      }

      // Full payload available.
      val payloadStart = compositeBuffer.split(offset).remainingBuffer
      val finalSplit = payloadStart.split(partSize.toInt())

      callbacks.onPart(partType.toInt(), finalSplit.extractedBuffer)

      compositeBuffer = finalSplit.remainingBuffer
    }
  }

  /**
   * Reads a specific varint from the current buffer offset.
   * @returns [decodedValue, updatedOffset] or [-1, originalOffset] if incomplete.
   */
  fun readVarInt(offset: Int): Pair<Long, Int> {
    var offset = offset

    if (!compositeBuffer.canReadBytes(offset, 1)) {
      return -1L to offset
    }

    val firstByte = compositeBuffer.getUint8(offset)
    val byteLength = when {
      firstByte < 128 -> 1
      firstByte < 192 -> 2
      firstByte < 224 -> 3
      firstByte < 240 -> 4
      else -> 5
    }

    if (!compositeBuffer.canReadBytes(offset, byteLength.toLong())) {
      return -1L to offset
    }

    val value: Long

    when (byteLength) {
      1 -> {
        value = compositeBuffer.getUint8(offset).toLong(); offset += 1
      }

      2 -> {
        val b1 = compositeBuffer.getUint8(offset).toLong(); offset += 1
        val b2 = compositeBuffer.getUint8(offset).toLong(); offset += 1
        value = (b1 and 0x3f) or (b2 shl 6)
      }

      3 -> {
        val b1 = compositeBuffer.getUint8(offset).toLong(); offset += 1
        val b2 = compositeBuffer.getUint8(offset).toLong(); offset += 1
        val b3 = compositeBuffer.getUint8(offset).toLong(); offset += 1
        value = (b1 and 0x1f) or (b2 shl 5) or (b3 shl 13)
      }

      4 -> {
        val b1 = compositeBuffer.getUint8(offset).toLong(); offset += 1
        val b2 = compositeBuffer.getUint8(offset).toLong(); offset += 1
        val b3 = compositeBuffer.getUint8(offset).toLong(); offset += 1
        val b4 = compositeBuffer.getUint8(offset).toLong(); offset += 1
        value = (b1 and 0x0f) or (b2 shl 4) or (b3 shl 12) or (b4 shl 20)
      }

      else -> {
        val dataOffset = offset + 1
        compositeBuffer.focus(dataOffset)

        value = if (canReadFromCurrentChunk(dataOffset, 4)) {
          val relativeOffset = dataOffset - compositeBuffer.currentChunkOffset
          val view = getCurrentDataView()
          (view.get(relativeOffset).toLong() and 0xff) or
            ((view.get(relativeOffset + 1).toLong() and 0xff) shl 8) or
            ((view.get(relativeOffset + 2).toLong() and 0xff) shl 16) or
            ((view.get(relativeOffset + 3).toLong() and 0xff) shl 24)
        } else {
          val b1 = compositeBuffer.getUint8(dataOffset).toLong()
          val b2 = compositeBuffer.getUint8(dataOffset + 1).toLong()
          val b3 = compositeBuffer.getUint8(dataOffset + 2).toLong()
          val b4 = compositeBuffer.getUint8(dataOffset + 3).toLong()
          b1 or (b2 shl 8) or (b3 shl 16) or (b4 shl 24)
        }
        offset += 5
      }
    }

    return value to offset
  }

  /**
   * Checks if the specified bytes can be read from the current chunk.
   * @param offset - Position to start reading from.
   * @param length - Number of bytes to read.
   * @returns True if bytes can be read from current chunk, false otherwise.
   */
  fun canReadFromCurrentChunk(offset: Int, length: Int): Boolean {
    val activeChunk = compositeBuffer.chunks[compositeBuffer.currentChunkIndex]
    return offset - compositeBuffer.currentChunkOffset + length <= activeChunk.remaining()
  }

  /**
   * Gets a DataView of the current chunk, creating it if necessary.
   * @returns DataView for the current chunk.
   */
  fun getCurrentDataView(): ByteBuffer {
    if (compositeBuffer.currentDataView == null) {
      compositeBuffer.currentDataView = compositeBuffer.chunks[compositeBuffer.currentChunkIndex]
    }
    return compositeBuffer.currentDataView!!
  }

  fun dispose() {
    compositeBuffer = CompositeBuffer()
  }
}
