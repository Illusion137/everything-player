package com.margelo.nitro.everythingplayer.googlevideo.core

import java.nio.ByteBuffer

/**
 * A memory efficient buffer that manages discontinuous chunks as a single stream.
 * @NOTE
 * Based on https://gist.github.com/LuanRT/02d7eab589fb4080cd16e97f6dccf06f
 */
class CompositeBuffer(chunks: List<ByteBuffer> = emptyList()) {
  var chunks: MutableList<ByteBuffer> = mutableListOf()
  var currentChunkOffset: Int = 0
  var currentChunkIndex: Int = 0
  var currentDataView: ByteBuffer? = null
  var totalLength: Int = 0

  init {
    for (chunk in chunks) {
      append(chunk)
    }
  }

  /** Appends a chunk to this buffer. */
  fun append(data: ByteBuffer) {
    chunks.add(if (data.position() == 0) data else data.slice())
    totalLength += data.remaining()
  }

  fun append(data: ByteArray) {
    append(ByteBuffer.wrap(data))
  }

  /** Appends all chunks from another {@link CompositeBuffer} to this buffer. */
  fun append(data: CompositeBuffer) {
    for (chunk in data.chunks) {
      append(chunk)
    }
  }

  /**
   * Splits this buffer at a specified position.
   * @param position - Offset at which to split the buffer.
   * @returns Obj containing the bytes before `position` as `extractedBuffer` and the bytes from `position` onward as `remainingBuffer`.
   */
  fun split(position: Int): SplitResult {
    var position = position
    val extractedBuffer = CompositeBuffer()
    val remainingBuffer = CompositeBuffer()

    for (chunk in chunks) {
      val count = chunk.remaining()
      if (position >= count) {
        extractedBuffer.append(chunk)
        position -= count
      } else if (position > 0) {
        extractedBuffer.append(chunk.subview(0, position))
        remainingBuffer.append(chunk.subview(position, count))
        position = 0
      } else {
        remainingBuffer.append(chunk)
      }
    }

    return SplitResult(extractedBuffer, remainingBuffer)
  }

  fun getLength(): Int = totalLength

  fun canReadBytes(position: Int, length: Long): Boolean = position + length <= totalLength

  /** Reads a single unsigned byte at the given position. */
  fun getUint8(position: Int): Int {
    focus(position)
    val chunk = chunks[currentChunkIndex]
    return chunk.get(position - currentChunkOffset).toInt() and 0xff
  }

  /**
   * Moves the internal focus to the chunk containing the specified position.
   * If the position is before the currently focused chunk, focus is reset first.
   * Cached `currentDataView` is also invalidated.
   */
  fun focus(position: Int) {
    if (!isFocused(position)) {
      if (position < currentChunkOffset) {
        resetFocus()
      }

      while (currentChunkIndex < chunks.size &&
        currentChunkOffset + chunks[currentChunkIndex].remaining() <= position
      ) {
        currentChunkOffset += chunks[currentChunkIndex].remaining()
        currentChunkIndex += 1
      }

      currentDataView = null
    }
  }

  /**
   * Checks whether the internal focus already covers the specified position.
   * @returns `true` if `position` is within the currently focused chunk.
   */
  fun isFocused(position: Int): Boolean =
    currentChunkIndex < chunks.size &&
      position >= currentChunkOffset &&
      position < currentChunkOffset + chunks[currentChunkIndex].remaining()

  /** Resets the internal focus to the beginning of the buffer. */
  private fun resetFocus() {
    currentDataView = null
    currentChunkIndex = 0
    currentChunkOffset = 0
  }

  class SplitResult(val extractedBuffer: CompositeBuffer, val remainingBuffer: CompositeBuffer)
}

internal fun ByteBuffer.subview(start: Int, end: Int): ByteBuffer {
  val view = duplicate()
  view.position(position() + start)
  view.limit(position() + end)
  return view.slice()
}
