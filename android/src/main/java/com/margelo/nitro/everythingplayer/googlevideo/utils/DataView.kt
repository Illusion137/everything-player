package com.margelo.nitro.everythingplayer.googlevideo.utils

class DataView(val data: ByteArray) {
  val byteLength: Int get() = data.size

  fun getUint8(offset: Int): Int = data[offset].toInt() and 0xff

  fun getUint32(offset: Int): Long {
    var value = 0L
    for (i in 0 until 4) {
      value = (value shl 8) or getUint8(offset + i).toLong()
    }
    return value
  }

  fun getBigUint64(offset: Int): Long {
    var value = 0L
    for (i in 0 until 8) {
      value = (value shl 8) or getUint8(offset + i).toLong()
    }
    return value
  }
}
