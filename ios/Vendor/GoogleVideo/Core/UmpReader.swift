import Foundation

struct UmpReaderCallbacks {
    /// Called when a complete UMP part is available.
    var onPart: (Int, CompositeBuffer) async throws -> Void
    /// Only use this if you wish to handle partial UMP parts yourself.
    var onPartialPart: ((Int, CompositeBuffer, Int, Int) -> Bool)?

    init(
        onPart: @escaping (Int, CompositeBuffer) async throws -> Void,
        onPartialPart: ((Int, CompositeBuffer, Int, Int) -> Bool)? = nil
    ) {
        self.onPart = onPart
        self.onPartialPart = onPartialPart
    }
}

/// An efficient UMP reader.
/// @NOTE
/// Based on https://gist.github.com/LuanRT/7c8c79fa558f2430f0b85b09f8a9d818
final class UmpReader {
    private var compositeBuffer: CompositeBuffer

    private var pendingType: Int?
    private var pendingOffset: Int?
    private var pendingTotalSize: Int?

    private let callbacks: UmpReaderCallbacks

    init(_ callbacks: UmpReaderCallbacks) {
        self.callbacks = callbacks
        self.compositeBuffer = CompositeBuffer()
    }

    func feed(_ chunk: Data) async throws {
        compositeBuffer.append(chunk)
        return try await parse()
    }

    func feed(_ chunk: CompositeBuffer) async throws {
        compositeBuffer.append(chunk)
        return try await parse()
    }

    private func parse() async throws {
        // Resume any previously interrupted partial payload block.
        if pendingType != nil {
            if compositeBuffer.totalLength == 0 { return }

            let needed = pendingTotalSize! - pendingOffset!
            let split = compositeBuffer.split(needed)

            guard let onPartialPart = callbacks.onPartialPart else { return }
            if !onPartialPart(pendingType!, split.extractedBuffer, pendingOffset!, pendingTotalSize!) {
                return
            }

            pendingOffset! += split.extractedBuffer.totalLength
            compositeBuffer = split.remainingBuffer

            if pendingOffset == pendingTotalSize {
                pendingType = nil
                pendingTotalSize = nil
                pendingOffset = nil
            }
        }

        while true {
            var offset = 0

            let (partType, newOffset) = readVarInt(offset)
            offset = newOffset
            let (partSize, finalOffset) = readVarInt(offset)
            offset = finalOffset

            if partType < 0 || partSize < 0 {
                break
            }

            // If we don't have the full payload available...
            if !compositeBuffer.canReadBytes(offset, partSize) {
                // If we can't read at least 1 byte of payload or don't have a paartial handler, wait for more data.
                if !(callbacks.onPartialPart != nil && compositeBuffer.canReadBytes(offset, 1)) {
                    break
                }

                let remainingBuff = compositeBuffer.split(offset).remainingBuffer

                if callbacks.onPartialPart!(partType, remainingBuff, 0, partSize) {
                    pendingType = partType
                    pendingOffset = remainingBuff.totalLength
                    pendingTotalSize = partSize
                    compositeBuffer = CompositeBuffer()
                }
                break
            }

            // Full payload available.
            let payloadStart = compositeBuffer.split(offset).remainingBuffer
            let finalSplit = payloadStart.split(partSize)

            try await callbacks.onPart(partType, finalSplit.extractedBuffer)

            compositeBuffer = finalSplit.remainingBuffer
        }
    }

    /// Reads a specific varint from the current buffer offset.
    /// - Returns: [decodedValue, updatedOffset] or [-1, originalOffset] if incomplete.
    func readVarInt(_ offset: Int) -> (Int, Int) {
        var offset = offset

        if !compositeBuffer.canReadBytes(offset, 1) {
            return (-1, offset)
        }

        let firstByte = Int(compositeBuffer.getUint8(offset))
        let byteLength = firstByte < 128 ? 1
            : firstByte < 192 ? 2
                : firstByte < 224 ? 3
                    : firstByte < 240 ? 4
                        : 5

        if !compositeBuffer.canReadBytes(offset, byteLength) {
            return (-1, offset)
        }

        var value = 0

        switch byteLength {
        case 1:
            value = Int(compositeBuffer.getUint8(offset)); offset += 1

        case 2:
            let b1 = Int(compositeBuffer.getUint8(offset)); offset += 1
            let b2 = Int(compositeBuffer.getUint8(offset)); offset += 1
            value = (b1 & 0x3f) | (b2 << 6)

        case 3:
            let b1 = Int(compositeBuffer.getUint8(offset)); offset += 1
            let b2 = Int(compositeBuffer.getUint8(offset)); offset += 1
            let b3 = Int(compositeBuffer.getUint8(offset)); offset += 1
            value = (b1 & 0x1f) | (b2 << 5) | (b3 << 13)

        case 4:
            let b1 = Int(compositeBuffer.getUint8(offset)); offset += 1
            let b2 = Int(compositeBuffer.getUint8(offset)); offset += 1
            let b3 = Int(compositeBuffer.getUint8(offset)); offset += 1
            let b4 = Int(compositeBuffer.getUint8(offset)); offset += 1
            value = (b1 & 0x0f) | (b2 << 4) | (b3 << 12) | (b4 << 20)

        default:
            let dataOffset = offset + 1
            compositeBuffer.focus(dataOffset)

            if canReadFromCurrentChunk(dataOffset, 4) {
                let relativeOffset = dataOffset - compositeBuffer.currentChunkOffset
                let view = getCurrentDataView()
                let base = view.startIndex + relativeOffset
                value = Int(UInt32(view[base]) | (UInt32(view[base + 1]) << 8) | (UInt32(view[base + 2]) << 16) | (UInt32(view[base + 3]) << 24))
            } else {
                let b1 = Int(compositeBuffer.getUint8(dataOffset))
                let b2 = Int(compositeBuffer.getUint8(dataOffset + 1))
                let b3 = Int(compositeBuffer.getUint8(dataOffset + 2))
                let b4 = Int(compositeBuffer.getUint8(dataOffset + 3))
                value = (b1 | (b2 << 8) | (b3 << 16) | (b4 << 24))
            }
            offset += 5
        }

        return (value, offset)
    }

    /// Checks if the specified bytes can be read from the current chunk.
    /// - Parameter offset: Position to start reading from.
    /// - Parameter length: Number of bytes to read.
    /// - Returns: True if bytes can be read from current chunk, false otherwise.
    func canReadFromCurrentChunk(_ offset: Int, _ length: Int) -> Bool {
        let activeChunk = compositeBuffer.chunks[compositeBuffer.currentChunkIndex]
        return offset - compositeBuffer.currentChunkOffset + length <= activeChunk.count
    }

    /// Gets a DataView of the current chunk, creating it if necessary.
    /// - Returns: DataView for the current chunk.
    func getCurrentDataView() -> Data {
        if compositeBuffer.currentDataView == nil {
            compositeBuffer.currentDataView = compositeBuffer.chunks[compositeBuffer.currentChunkIndex]
        }
        return compositeBuffer.currentDataView!
    }

    func dispose() {
        compositeBuffer = CompositeBuffer()
    }
}
