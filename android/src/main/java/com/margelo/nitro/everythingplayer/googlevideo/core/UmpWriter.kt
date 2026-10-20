package com.margelo.nitro.everythingplayer.googlevideo.core

open class GoogleVideoError(override val message: String) : Exception(message)

/** A utility class for writing data in the UMP format. */
class UmpWriter(private val compositeBuffer: CompositeBuffer) {
  fun write(type: Int, data: ByteArray) {
    val partSize = data.size
    writeVarInt(type.toLong())
    writeVarInt(partSize.toLong())
    compositeBuffer.append(data)
  }

  private fun writeVarInt(value: Long) {
    if (value < 0) {
      throw GoogleVideoError("VarInt value cannot be negative.")
    }

    if (value < 128) {
      compositeBuffer.append(byteArrayOf(value.toByte()))
    } else if (value < 16384) {
      compositeBuffer.append(
        byteArrayOf(
          ((value and 0x3f) or 0x80).toByte(),
          (value shr 6).toByte(),
        ),
      )
    } else if (value < 2097152) {
      compositeBuffer.append(
        byteArrayOf(
          ((value and 0x1f) or 0xc0).toByte(),
          ((value shr 5) and 0xff).toByte(),
          (value shr 13).toByte(),
        ),
      )
    } else if (value < 268435456) {
      compositeBuffer.append(
        byteArrayOf(
          ((value and 0x0f) or 0xe0).toByte(),
          ((value shr 4) and 0xff).toByte(),
          ((value shr 12) and 0xff).toByte(),
          (value shr 20).toByte(),
        ),
      )
    } else {
      val data = ByteArray(5)
      val value = value and 0xffffffffL
      data[0] = 0xf0.toByte()
      data[1] = (value and 0xff).toByte()
      data[2] = ((value shr 8) and 0xff).toByte()
      data[3] = ((value shr 16) and 0xff).toByte()
      data[4] = ((value shr 24) and 0xff).toByte()
      compositeBuffer.append(data)
    }
  }
}
