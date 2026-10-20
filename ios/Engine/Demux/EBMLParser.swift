import Foundation

struct EPOpusPacket {
  let timestampMs: Double
  let data: Data
}

struct EPOpusStreamInfo {
  let channelCount: Int
  let preSkip: Int
}

final class EPEBMLParser {
  private(set) var streamInfo: EPOpusStreamInfo?
  private var buf = Data()
  private var timestampScaleMs: Double = 1.0
  private var clusterTimestampMs: Double = 0.0

  private enum ID: UInt64 {
    case ebml = 0x1A45DFA3
    case segment = 0x18538067
    case info = 0x1549A966
    case tracks = 0x1654AE6B
    case cluster = 0x1F43B675
    case trackEntry = 0xAE
    case codecPrivate = 0x63A2
    case timestampScale = 0x2AD7B1
    case timestamp = 0xE7
    case simpleBlock = 0xA3
    case blockGroup = 0xA0
    case block = 0xA1
  }

  private static let masterIDs: Set<UInt64> = [
    ID.ebml.rawValue, ID.segment.rawValue, ID.info.rawValue,
    ID.tracks.rawValue, ID.cluster.rawValue, ID.trackEntry.rawValue,
    ID.blockGroup.rawValue,
  ]

  func reset() {
    buf = Data()
    clusterTimestampMs = 0
  }

  func feed(_ data: Data) -> [EPOpusPacket] {
    buf.append(data)
    var packets: [EPOpusPacket] = []
    var pos = buf.startIndex

    while pos < buf.endIndex {
      guard let (id, headerLen, bodyLen) = peekElement(at: pos) else { break }
      let bodyStart = pos + headerLen
      guard let bodySize = bodyLen, !Self.masterIDs.contains(id) else {
        pos = bodyStart
        continue
      }
      if bodyStart + bodySize > buf.endIndex { break }
      let bodyEnd = bodyStart + bodySize
      let body = buf[bodyStart..<bodyEnd]

      switch id {
      case ID.timestampScale.rawValue:
        timestampScaleMs = Double(readUInt(body)) / 1_000_000.0
      case ID.codecPrivate.rawValue:
        if streamInfo == nil { streamInfo = parseOpusHeader(body) }
      case ID.timestamp.rawValue:
        clusterTimestampMs = Double(readUInt(body)) * timestampScaleMs
      case ID.simpleBlock.rawValue, ID.block.rawValue:
        if let pkt = parseBlock(body) { packets.append(pkt) }
      default:
        break
      }
      pos = bodyEnd
    }

    if pos > buf.startIndex { buf = Data(buf[pos...]) }
    return packets
  }

  private func peekElement(at start: Data.Index) -> (UInt64, Int, Int?)? {
    guard let (id, idLen) = readVInt(buf, at: start, isID: true) else { return nil }
    let sizePos = start + idLen
    guard let (rawSize, sizeLen) = readVInt(buf, at: sizePos, isID: false) else { return nil }
    let unknownSize: UInt64 = (1 << (7 * UInt64(sizeLen))) - 1
    if rawSize == unknownSize { return (id, idLen + sizeLen, nil) }
    return (id, idLen + sizeLen, Int(rawSize))
  }

  private func readVInt(_ data: Data, at pos: Data.Index, isID: Bool) -> (UInt64, Int)? {
    guard pos < data.endIndex else { return nil }
    let first = data[pos]
    guard first != 0 else { return nil }
    var width = 1
    var mask: UInt8 = 0x80
    while (first & mask) == 0 && width <= 8 {
      width += 1
      mask >>= 1
    }
    guard pos + width <= data.endIndex else { return nil }
    var value: UInt64 = 0
    for i in 0..<width { value = (value << 8) | UInt64(data[pos + i]) }
    if !isID {
      let maskBits: UInt64 = 0x80 >> (width - 1)
      value &= ~(maskBits << (UInt64(width - 1) * 8))
    }
    return (value, width)
  }

  private func readUInt(_ data: Data) -> UInt64 {
    var v: UInt64 = 0
    for byte in data { v = (v << 8) | UInt64(byte) }
    return v
  }

  private func parseOpusHeader(_ data: Data) -> EPOpusStreamInfo? {
    guard data.count >= 19 else { return nil }
    let base = data.startIndex
    guard data[base..<base + 8].elementsEqual("OpusHead".utf8) else { return nil }
    let channels = Int(data[base + 9])
    let preSkip = Int(data[base + 10]) | (Int(data[base + 11]) << 8)
    return EPOpusStreamInfo(channelCount: max(1, min(2, channels)), preSkip: preSkip)
  }

  private func parseBlock(_ data: Data) -> EPOpusPacket? {
    var pos = data.startIndex
    guard let (_, trackLen) = readVInt(data, at: pos, isID: false) else { return nil }
    pos += trackLen
    guard pos + 3 < data.endIndex else { return nil }
    let delta = Int16(bitPattern: UInt16(data[pos]) << 8 | UInt16(data[pos + 1]))
    pos += 3
    let ts = clusterTimestampMs + Double(delta) * timestampScaleMs
    return EPOpusPacket(timestampMs: ts, data: Data(data[pos...]))
  }
}
