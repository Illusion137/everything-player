import Foundation
import SwiftProtobuf

func u8ToBase64(_ u8: Data) -> String {
    return u8.base64EncodedString()
}

func base64ToU8(_ base64: String) -> Data {
    let standardBase64 = base64.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
    let paddedBase64 = standardBase64.padding(toLength: standardBase64.count + (4 - standardBase64.count % 4) % 4, withPad: "=", startingAt: 0)
    return Data(base64Encoded: paddedBase64) ?? Data()
}

func concatenateChunks(_ chunks: [Data]) -> Data {
    let chunkCount = chunks.count

    var totalLength = 0

    for i in 0..<chunkCount {
        totalLength += chunks[i].count
    }

    var result = Data(count: totalLength)

    var offset = 0

    for i in 0..<chunkCount {
        let chunk = chunks[i]
        result.replaceSubrange(offset..<offset + chunk.count, with: chunk)
        offset += chunk.count
    }

    return result
}

func decodePart<T: SwiftProtobuf.Message>(_ chunks: [Data], _ decoder: T.Type) -> T? {
    if chunks.isEmpty {
        return nil
    }

    return try? T(serializedBytes: concatenateChunks(chunks))
}
