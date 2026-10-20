package com.margelo.nitro.everythingplayer.googlevideo.utils

import com.google.protobuf.MessageLite
import com.google.protobuf.Parser
import java.nio.ByteBuffer
import kotlin.io.encoding.Base64
import kotlin.io.encoding.ExperimentalEncodingApi

@OptIn(ExperimentalEncodingApi::class)
fun u8ToBase64(u8: ByteArray): String = Base64.Default.encode(u8)

@OptIn(ExperimentalEncodingApi::class)
fun base64ToU8(base64: String): ByteArray {
  val standardBase64 = base64.replace("-", "+").replace("_", "/")
  val paddedBase64 = standardBase64.padEnd(standardBase64.length + (4 - standardBase64.length % 4) % 4, '=')
  return runCatching { Base64.Default.decode(paddedBase64) }.getOrElse { ByteArray(0) }
}

fun concatenateChunks(chunks: List<ByteBuffer>): ByteArray {
  val chunkCount = chunks.size

  var totalLength = 0

  for (i in 0 until chunkCount) {
    totalLength += chunks[i].remaining()
  }

  val result = ByteArray(totalLength)

  var offset = 0

  for (i in 0 until chunkCount) {
    val chunk = chunks[i].duplicate()
    val length = chunk.remaining()
    chunk.get(result, offset, length)
    offset += length
  }

  return result
}

fun <T : MessageLite> decodePart(chunks: List<ByteBuffer>, decoder: Parser<T>): T? {
  if (chunks.isEmpty()) {
    return null
  }

  return runCatching { decoder.parseFrom(concatenateChunks(chunks)) }.getOrNull()
}
