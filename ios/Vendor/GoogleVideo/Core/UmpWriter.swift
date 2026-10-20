import Foundation

struct GoogleVideoError: Error, LocalizedError {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? {
        return message
    }
}

/// A utility class for writing data in the UMP format.
final class UmpWriter {
    private let compositeBuffer: CompositeBuffer

    init(_ compositeBuffer: CompositeBuffer) {
        self.compositeBuffer = compositeBuffer
    }

    func write(_ type: Int, _ data: Data) throws {
        let partSize = data.count
        try writeVarInt(type)
        try writeVarInt(partSize)
        compositeBuffer.append(data)
    }

    private func writeVarInt(_ value: Int) throws {
        if value < 0 {
            throw GoogleVideoError("VarInt value cannot be negative.")
        }

        if value < 128 {
            compositeBuffer.append(Data([UInt8(value)]))
        } else if value < 16384 {
            compositeBuffer.append(Data([
                UInt8((value & 0x3f) | 0x80),
                UInt8(value >> 6)
            ]))
        } else if value < 2097152 {
            compositeBuffer.append(Data([
                UInt8((value & 0x1f) | 0xc0),
                UInt8((value >> 5) & 0xff),
                UInt8(value >> 13)
            ]))
        } else if value < 268435456 {
            compositeBuffer.append(Data([
                UInt8((value & 0x0f) | 0xe0),
                UInt8((value >> 4) & 0xff),
                UInt8((value >> 12) & 0xff),
                UInt8(value >> 20)
            ]))
        } else {
            var data = Data(count: 5)
            let value = UInt32(value)
            data[0] = 0xf0
            data[1] = UInt8(value & 0xff)
            data[2] = UInt8((value >> 8) & 0xff)
            data[3] = UInt8((value >> 16) & 0xff)
            data[4] = UInt8((value >> 24) & 0xff)
            compositeBuffer.append(data)
        }
    }
}
