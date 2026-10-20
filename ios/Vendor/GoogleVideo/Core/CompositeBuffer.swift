import Foundation

/// A memory efficient buffer that manages discontinuous chunks as a single stream.
/// @NOTE
/// Based on https://gist.github.com/LuanRT/02d7eab589fb4080cd16e97f6dccf06f
final class CompositeBuffer {
    var chunks: [Data]
    var currentChunkOffset: Int
    var currentChunkIndex: Int
    var currentDataView: Data?
    var totalLength: Int

    init(_ chunks: [Data] = []) {
        self.chunks = []
        self.currentChunkOffset = 0
        self.currentChunkIndex = 0
        self.currentDataView = nil
        self.totalLength = 0

        for chunk in chunks {
            append(chunk)
        }
    }

    /// Appends a chunk to this buffer.
    func append(_ data: Data) {
        chunks.append(data.startIndex == 0 ? data : Data(data))
        totalLength += data.count
    }

    /// Appends all chunks from another {@link CompositeBuffer} to this buffer.
    func append(_ data: CompositeBuffer) {
        for chunk in data.chunks {
            append(chunk)
        }
    }

    /// Splits this buffer at a specified position.
    /// - Parameter position: Offset at which to split the buffer.
    /// - Returns: Obj containing the bytes before `position` as `extractedBuffer` and the bytes from `position` onward as `remainingBuffer`.
    func split(_ position: Int) -> (extractedBuffer: CompositeBuffer, remainingBuffer: CompositeBuffer) {
        var position = position
        let extractedBuffer = CompositeBuffer()
        let remainingBuffer = CompositeBuffer()

        for chunk in chunks {
            if position >= chunk.count {
                extractedBuffer.append(chunk)
                position -= chunk.count
            } else if position > 0 {
                let base = chunk.startIndex
                extractedBuffer.append(chunk[base ..< base + position])
                remainingBuffer.append(chunk[base + position ..< base + chunk.count])
                position = 0
            } else {
                remainingBuffer.append(chunk)
            }
        }

        return (extractedBuffer, remainingBuffer)
    }

    func getLength() -> Int {
        return totalLength
    }

    func canReadBytes(_ position: Int, _ length: Int) -> Bool {
        return position + length <= totalLength
    }

    /// Reads a single unsigned byte at the given position.
    func getUint8(_ position: Int) -> UInt8 {
        focus(position)
        let chunk = chunks[currentChunkIndex]
        return chunk[chunk.startIndex + (position - currentChunkOffset)]
    }

    /// Moves the internal focus to the chunk containing the specified position.
    /// If the position is before the currently focused chunk, focus is reset first.
    /// Cached `currentDataView` is also invalidated.
    func focus(_ position: Int) {
        if !isFocused(position) {
            if position < currentChunkOffset {
                resetFocus()
            }

            while currentChunkIndex < chunks.count &&
                currentChunkOffset + chunks[currentChunkIndex].count <= position {
                currentChunkOffset += chunks[currentChunkIndex].count
                currentChunkIndex += 1
            }

            currentDataView = nil
        }
    }

    /// Checks whether the internal focus already covers the specified position.
    /// - Returns: `true` if `position` is within the currently focused chunk.
    func isFocused(_ position: Int) -> Bool {
        return position >= currentChunkOffset &&
            position < currentChunkOffset + chunks[currentChunkIndex].count
    }

    /// Resets the internal focus to the beginning of the buffer.
    private func resetFocus() {
        currentDataView = nil
        currentChunkIndex = 0
        currentChunkOffset = 0
    }
}
