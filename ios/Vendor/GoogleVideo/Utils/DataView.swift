import Foundation

struct DataView {
    let data: Data

    init(_ data: Data) {
        self.data = data
    }

    var byteLength: Int { data.count }

    func getUint8(_ offset: Int) -> UInt8 {
        return data[data.startIndex + offset]
    }

    func getUint32(_ offset: Int) -> UInt32 {
        var value: UInt32 = 0
        for i in 0..<4 {
            value = (value << 8) | UInt32(getUint8(offset + i))
        }
        return value
    }

    func getBigUint64(_ offset: Int) -> UInt64 {
        var value: UInt64 = 0
        for i in 0..<8 {
            value = (value << 8) | UInt64(getUint8(offset + i))
        }
        return value
    }
}
