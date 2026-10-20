import Foundation

let EMSG_BOX_TYPE: UInt32 = 0x656d7367

final class BoxReader {
    let data: DataView
    let offset: Int
    let size: Int
    let type: UInt32
    var cursor: Int

    init(data: DataView, offset: Int, size: Int, type: UInt32, cursor: Int) {
        self.data = data
        self.offset = offset
        self.size = size
        self.type = type
        self.cursor = cursor
    }
}

private func makeBoxReader(_ data: DataView, _ offset: Int) -> BoxReader {
    let size = Int(data.getUint32(offset))
    let type = data.getUint32(offset + 4)
    return BoxReader(data: data, offset: offset, size: size, type: type, cursor: 8)
}

private func readUint32Field(_ box: BoxReader) -> Int {
    let value = Int(box.data.getUint32(box.offset + box.cursor))
    box.cursor += 4
    return value
}

private func bytesToString(_ bytes: Data) -> String {
    if bytes.isEmpty { return "" }
    return String(decoding: bytes, as: UTF8.self)
}

private func readString(_ box: BoxReader, _ terminator: UInt8? = nil) -> String {
    var end: Int

    if let terminator {
        end = box.cursor
        while end < box.size && box.data.getUint8(box.offset + end) != terminator {
            end += 1
        }
    } else {
        end = box.size
    }

    let start = box.data.data.startIndex + box.offset + box.cursor
    let length = max(0, end - box.cursor)
    let bytes = box.data.data.subdata(in: start..<start + length)

    box.cursor = min(end + 1, box.size)

    return bytesToString(bytes)
}

private func looksLikeBox(_ data: DataView, _ offset: Int) -> Bool {
    if data.byteLength - offset < 8 { return false }
    let size = Int(data.getUint32(offset))
    if size < 8 || data.byteLength - offset < size { return false }

    for i in 4..<8 {
        let byte = data.getUint8(offset + i)
        if byte < 48 || byte > 122 { return false }
    }

    return true
}

func findBox(_ data: DataView, _ offset: Int, _ targetType: UInt32) -> BoxReader? {
    var offset = offset
    while looksLikeBox(data, offset) {
        let box = makeBoxReader(data, offset)
        if box.type == targetType { return box }
        offset += box.size
    }
    return nil
}

struct EmsgBody {
    var schemeIdUri: String
    var value: String
    var timescale: Int
    var presentationTimeDelta: Int
    var eventDuration: Int
    var id: Int
    var messageData: String
}

func parseEmsgBody(_ box: BoxReader) -> EmsgBody {
    box.cursor += 4
    let schemeIdUri = readString(box, 0)
    let value = readString(box, 0)
    let timescale = readUint32Field(box)
    let presentationTimeDelta = readUint32Field(box)
    let eventDuration = readUint32Field(box)
    let id = readUint32Field(box)
    let messageData = readString(box)

    return EmsgBody(
        schemeIdUri: schemeIdUri,
        value: value,
        timescale: timescale,
        presentationTimeDelta: presentationTimeDelta,
        eventDuration: eventDuration,
        id: id,
        messageData: messageData
    )
}

private let headerLineRegex = try! NSRegularExpression(pattern: "([^:]+):\\s+([\\s\\S]+)")

func parseHeaderBlock(_ text: String) -> [String: String]? {
    let lines = text.components(separatedBy: "\r\n")
    var headers: [String: String] = [:]

    for line in lines {
        if line.isEmpty { return headers }
        let nsLine = line as NSString
        if let match = headerLineRegex.firstMatch(in: line, range: NSRange(location: 0, length: nsLine.length)) {
            headers[nsLine.substring(with: match.range(at: 1))] = nsLine.substring(with: match.range(at: 2))
        }
    }

    return nil
}

private func getNumber(_ headers: [String: String], _ key: String) -> Double {
    guard let value = headers[key], let number = Double(value.trimmingCharacters(in: .whitespaces)), number.isFinite else { return 0 }
    return number
}

final class EmsgSegmentMetadata {
    private let receivedAtMs: Double = nowMs()

    var data: [String: String]
    var uri: String
    var segmentNumber: Double
    var totalSegmentCount: Double
    var segmentDurationsMs: String
    var ingestionTimeSec: Double
    var ingestionUncertaintySec: Double
    var safeFirstFrameTimeSec: Double
    var targetDurationSec: Double
    var cryptoPeriodIndex: Double
    var cryptoPeriodSeconds: Double
    var currentAbsoluteLoudnessLkfs: Double?

    init(_ data: [String: String], _ uri: String = "https://youtube.com") {
        self.data = data
        self.uri = uri
        self.segmentNumber = getNumber(data, "Sequence-Number")
        self.totalSegmentCount = getNumber(data, "Segment-Count")
        self.segmentDurationsMs = data["Segment-Durations-Ms"] ?? ""
        self.ingestionTimeSec = getNumber(data, "Ingestion-Walltime-Us") / 1e6
        self.ingestionUncertaintySec = getNumber(data, "Ingestion-Uncertainty-Us") / 1e6
        self.safeFirstFrameTimeSec =
            (getNumber(data, "First-Frame-Time-Us") +
                getNumber(data, "First-Frame-Uncertainty-Us")) /
            1e6

        self.targetDurationSec = getNumber(data, "Target-Duration-Us") / 1e6
        self.cryptoPeriodIndex = getNumber(data, "Crypto-Period-Index")
        self.cryptoPeriodSeconds = getNumber(data, "Crypto-Period-Seconds")
        self.currentAbsoluteLoudnessLkfs = data["Current-Absolute-Loudness-Lkfs"] != nil
            ? getNumber(data, "Current-Absolute-Loudness-Lkfs") : nil
    }

    var latencyMs: Double {
        let ingestionTimeMs = ingestionTimeSec * 1e3
        let uncertaintyMs = ingestionUncertaintySec * 1e3
        return max(0, (receivedAtMs - ingestionTimeMs) + uncertaintyMs)
    }

    func getStitchedCPNs() -> [String] {
        if let cpn = data["Stitched-Video-Cpn"], !cpn.isEmpty {
            return Array(cpn.components(separatedBy: ",").dropLast())
        }
        return []
    }

    func hasStitchedAdBreakMetadata() -> Bool {
        let keys = [
            "Stitched-Video-Id",
            "Stitched-Video-Cpn",
            "Stitched-Video-Duration-Us",
            "Stitched-Video-Start-Frame-Index",
            "Stitched-Video-Absolute-Loudness-Lkfs",
            "Serialized-State",
            "Is-Ad-Break-Finished"
        ]
        return keys.contains { !(data[$0] ?? "").isEmpty }
    }
}
