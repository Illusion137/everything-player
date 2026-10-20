package com.margelo.nitro.everythingplayer.googlevideo.utils

fun stripMp4Init(segment: ByteArray): ByteArray {
  val view = DataView(segment)

  var offset = 0L

  while (offset < segment.size - 8) {
    val o = offset.toInt()
    var size = view.getUint32(o)

    val type = String(
      byteArrayOf(
        view.getUint8(o + 4).toByte(),
        view.getUint8(o + 5).toByte(),
        view.getUint8(o + 6).toByte(),
        view.getUint8(o + 7).toByte(),
      ),
      Charsets.UTF_8,
    )

    if (type == "moof" || type == "mdat") {
      return segment.copyOfRange(o, segment.size)
    }

    if (size == 1L) {
      if (offset + 16 > segment.size) break
      size = view.getBigUint64(o + 8)
    } else if (size == 0L) break

    offset += size
  }

  return segment
}

fun stripWebmInit(segment: ByteArray): ByteArray {
  val view = DataView(segment)

  var offset = 0L

  while (offset < segment.size) {
    var firstByte = view.getUint8(offset.toInt())
    var idLength = 1
    var mask = 0x80

    while (idLength <= 4 && (firstByte and mask) == 0) {
      idLength += 1
      mask = mask shr 1
    }

    if (idLength > 4 || offset + idLength >= segment.size) break

    var id = 0L
    for (i in 0 until idLength) {
      id = (id * 256) + view.getUint8((offset + i).toInt())
    }

    if (id == 0x1F43B675L) {
      return segment.copyOfRange(offset.toInt(), segment.size)
    }

    offset += idLength

    firstByte = view.getUint8(offset.toInt())
    var sizeLength = 1
    mask = 0x80

    while (sizeLength <= 8 && (firstByte and mask) == 0) {
      sizeLength += 1
      mask = mask shr 1
    }

    if (sizeLength > 8 || offset + sizeLength > segment.size) break

    var size = (firstByte and mask.inv()).toLong()
    var isUnknown = firstByte == (mask or (mask - 1))

    for (i in 1 until sizeLength) {
      val b = view.getUint8((offset + i).toInt())
      size = (size * 256) + b
      if (b != 0xFF) isUnknown = false
    }

    offset += sizeLength

    if (id == 0x18538067L) {
      continue
    }

    if (isUnknown) {
      break
    }

    offset += size
  }

  return segment
}

fun parseEmsgSegmentMetadata(buffer: ByteArray): EmsgSegmentMetadata? {
  val view = DataView(buffer)

  val firstBox = findBox(view, 0, EMSG_BOX_TYPE) ?: return null

  val firstBody = parseEmsgBody(firstBox)

  var headers = parseHeaderBlock(firstBody.messageData)

  val secondBox = findBox(view, firstBox.offset + firstBox.size, EMSG_BOX_TYPE)
  if (secondBox != null) {
    val secondBody = parseEmsgBody(secondBox)
    val secondHeaders = parseHeaderBlock(secondBody.messageData)
    val current = headers
    if (current != null && secondHeaders != null) {
      headers = current + secondHeaders
    }
  }

  if (headers != null) {
    return EmsgSegmentMetadata(headers, firstBody.schemeIdUri)
  }

  return null
}
