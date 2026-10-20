import Foundation

func stripMp4Init(_ segment: Data) -> Data {
    let view = DataView(segment)

    var offset = 0

    while offset < segment.count - 8 {
        var size = Int(view.getUint32(offset))

        let type = String(decoding: [
            view.getUint8(offset + 4),
            view.getUint8(offset + 5),
            view.getUint8(offset + 6),
            view.getUint8(offset + 7)
        ], as: UTF8.self)

        if type == "moof" || type == "mdat" {
            return Data(segment.dropFirst(offset))
        }

        if size == 1 {
            if offset + 16 > segment.count { break }
            size = Int(view.getBigUint64(offset + 8))
        } else if size == 0 { break }

        offset += size
    }

    return segment
}

func stripWebmInit(_ segment: Data) -> Data {
    let view = DataView(segment)

    var offset = 0

    while offset < segment.count {
        var firstByte = Int(view.getUint8(offset))
        var idLength = 1
        var mask = 0x80

        while idLength <= 4 && (firstByte & mask) == 0 {
            idLength += 1
            mask >>= 1
        }

        if idLength > 4 || offset + idLength >= segment.count { break }

        var id = 0
        for i in 0..<idLength {
            id = (id * 256) + Int(view.getUint8(offset + i))
        }

        if id == 0x1F43B675 {
            return Data(segment.dropFirst(offset))
        }

        offset += idLength

        firstByte = Int(view.getUint8(offset))
        var sizeLength = 1
        mask = 0x80

        while sizeLength <= 8 && (firstByte & mask) == 0 {
            sizeLength += 1
            mask >>= 1
        }

        if sizeLength > 8 || offset + sizeLength > segment.count { break }

        var size = firstByte & ~mask
        var isUnknown = firstByte == (mask | (mask - 1))

        for i in 1..<sizeLength {
            let b = Int(view.getUint8(offset + i))
            size = (size * 256) + b
            if b != 0xFF { isUnknown = false }
        }

        offset += sizeLength

        if id == 0x18538067 {
            continue
        }

        if isUnknown {
            break
        }

        offset += size
    }

    return segment
}

func parseEmsgSegmentMetadata(_ buffer: Data) -> EmsgSegmentMetadata? {
    let view = DataView(buffer)

    guard let firstBox = findBox(view, 0, EMSG_BOX_TYPE) else { return nil }

    let firstBody = parseEmsgBody(firstBox)

    var headers = parseHeaderBlock(firstBody.messageData)

    if let secondBox = findBox(view, firstBox.offset + firstBox.size, EMSG_BOX_TYPE) {
        let secondBody = parseEmsgBody(secondBox)
        let secondHeaders = parseHeaderBlock(secondBody.messageData)
        if let current = headers, let secondHeaders {
            headers = current.merging(secondHeaders) { _, new in new }
        }
    }

    if let headers {
        return EmsgSegmentMetadata(headers, firstBody.schemeIdUri)
    }

    return nil
}
