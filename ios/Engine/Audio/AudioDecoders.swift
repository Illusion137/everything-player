import AVFoundation

struct EPDecodedAudio {
  let timestampSeconds: Double
  let buffer: AVAudioPCMBuffer
}

protocol EPAudioPacketDecoder: AnyObject {
  var format: AVAudioFormat? { get }
  func feed(_ data: Data, decodeFrom: Double) throws -> [EPDecodedAudio]
}

final class EPOpusStreamDecoder: EPAudioPacketDecoder {
  private let parser = EPEBMLParser()
  private var decoder: OpaquePointer?
  private var channels: Int32 = 2
  private var preSkipRemaining = 0
  private var interleaved: [Float] = []
  private(set) var format: AVAudioFormat?

  deinit {
    if let decoder { opus_decoder_destroy(decoder) }
  }

  func feed(_ data: Data, decodeFrom: Double) throws -> [EPDecodedAudio] {
    let packets = parser.feed(data)
    if decoder == nil, let info = parser.streamInfo {
      channels = Int32(info.channelCount)
      var err: Int32 = OPUS_OK
      guard let dec = opus_decoder_create(48000, channels, &err), err == OPUS_OK else {
        throw EPError(.decodeError, "opus_decoder_create failed (\(err))")
      }
      decoder = dec
      preSkipRemaining = info.preSkip
      format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: AVAudioChannelCount(channels), interleaved: false)
    }
    guard let decoder, let format else { return [] }
    var out: [EPDecodedAudio] = []
    for packet in packets {
      if packet.timestampMs / 1000 < decodeFrom - 0.08 {
        preSkipRemaining = 0
        continue
      }
      guard let buffer = decode(packet.data, decoder: decoder, format: format) else { continue }
      var ts = packet.timestampMs / 1000
      if preSkipRemaining > 0 {
        let skip = min(preSkipRemaining, Int(buffer.frameLength))
        preSkipRemaining -= skip
        guard let trimmed = buffer.dropping(frames: skip) else { continue }
        ts += Double(skip) / 48000
        out.append(EPDecodedAudio(timestampSeconds: ts, buffer: trimmed))
      } else {
        out.append(EPDecodedAudio(timestampSeconds: ts, buffer: buffer))
      }
    }
    return out
  }

  private func decode(_ data: Data, decoder: OpaquePointer, format: AVAudioFormat) -> AVAudioPCMBuffer? {
    data.withUnsafeBytes { raw -> AVAudioPCMBuffer? in
      guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return nil }
      let count = opus_decoder_get_nb_samples(decoder, base, Int32(data.count))
      guard count > 0,
            let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)),
            let channelData = buf.floatChannelData else { return nil }
      let ch = Int(channels)
      if interleaved.count < Int(count) * ch { interleaved = [Float](repeating: 0, count: Int(count) * ch) }
      let decoded = interleaved.withUnsafeMutableBufferPointer { tmp in
        opus_decode_float(decoder, base, Int32(data.count), tmp.baseAddress!, count, 0)
      }
      guard decoded > 0 else { return nil }
      let n = Int(decoded)
      interleaved.withUnsafeBufferPointer { src in
        for c in 0..<ch {
          let dst = channelData[c]
          for f in 0..<n { dst[f] = src[f * ch + c] }
        }
      }
      buf.frameLength = AVAudioFrameCount(n)
      return buf
    }
  }
}

final class EPAACPacketDecoder {
  let config: EPAACConfig
  let format: AVAudioFormat
  private let inputFormat: AVAudioFormat
  private let converter: AVAudioConverter

  convenience init(_ config: EPAACConfig, heAAC: Bool) throws {
    guard heAAC, config.sampleRate <= 24000, config.asc.count >= 2, (config.asc[config.asc.startIndex] >> 3) == 2,
          let core = EPADTS.sampleRates.firstIndex(of: config.sampleRate),
          let ext = EPADTS.sampleRates.firstIndex(of: config.sampleRate * 2) else {
      try self.init(config)
      return
    }
    let channels = config.channels
    var bits: UInt32 = 5
    bits = bits << 4 | UInt32(core)
    bits = bits << 4 | UInt32(channels)
    bits = bits << 4 | UInt32(ext)
    bits = bits << 5 | 2
    bits <<= 2
    let asc = Data([UInt8(bits >> 16 & 0xFF), UInt8(bits >> 8 & 0xFF), UInt8(bits & 0xFF)])
    do {
      try self.init(EPAACConfig(asc: asc, sampleRate: config.sampleRate * 2, channels: channels), formatID: kAudioFormatMPEG4AAC_HE, framesPerPacket: 2048, reportedConfig: config)
    } catch {
      try self.init(config)
    }
  }

  convenience init(_ config: EPAACConfig) throws {
    try self.init(config, formatID: kAudioFormatMPEG4AAC, framesPerPacket: 1024, reportedConfig: config)
  }

  private init(_ decodeConfig: EPAACConfig, formatID: AudioFormatID, framesPerPacket: UInt32, reportedConfig: EPAACConfig) throws {
    config = reportedConfig
    var desc = AudioStreamBasicDescription(
      mSampleRate: decodeConfig.sampleRate, mFormatID: formatID, mFormatFlags: 0, mBytesPerPacket: 0,
      mFramesPerPacket: framesPerPacket, mBytesPerFrame: 0, mChannelsPerFrame: UInt32(max(1, decodeConfig.channels)),
      mBitsPerChannel: 0, mReserved: 0)
    guard let input = AVAudioFormat(streamDescription: &desc),
          let output = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: desc.mSampleRate, channels: desc.mChannelsPerFrame, interleaved: false),
          let conv = AVAudioConverter(from: input, to: output) else {
      throw EPError(.decodeError, "Cannot create AAC converter")
    }
    conv.magicCookie = decodeConfig.asc
    inputFormat = input
    format = output
    converter = conv
  }

  func decode(_ data: Data) -> AVAudioPCMBuffer? {
    let compressed = AVAudioCompressedBuffer(format: inputFormat, packetCapacity: 1, maximumPacketSize: data.count)
    data.withUnsafeBytes { raw in
      compressed.data.copyMemory(from: raw.baseAddress!, byteCount: data.count)
    }
    compressed.byteLength = UInt32(data.count)
    compressed.packetCount = 1
    compressed.packetDescriptions?.pointee = AudioStreamPacketDescription(mStartOffset: 0, mVariableFramesInPacket: 0, mDataByteSize: UInt32(data.count))
    guard let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096) else { return nil }
    var fed = false
    var error: NSError?
    let status = converter.convert(to: pcm, error: &error) { _, outStatus in
      if fed {
        outStatus.pointee = .noDataNow
        return nil
      }
      fed = true
      outStatus.pointee = .haveData
      return compressed
    }
    guard status != .error, pcm.frameLength > 0 else { return nil }
    return pcm
  }
}

final class EPAACStreamDecoder: EPAudioPacketDecoder {
  private let demuxer = EPFMP4Demuxer()
  private var decoder: EPAACPacketDecoder?
  private var timescale: Double = 1

  var format: AVAudioFormat? { decoder?.format }

  func feed(_ data: Data, decodeFrom: Double) throws -> [EPDecodedAudio] {
    let samples = demuxer.feed(data)
    if decoder == nil, let track = demuxer.track {
      guard case let .aac(asc, sampleRate, channels) = track.codec else {
        throw EPError(.decodeError, "Unsupported audio codec in MP4")
      }
      timescale = Double(track.timescale)
      decoder = try EPAACPacketDecoder(EPAACConfig(asc: asc, sampleRate: sampleRate > 0 ? sampleRate : timescale, channels: channels))
    }
    guard let decoder else { return [] }
    var out: [EPDecodedAudio] = []
    for sample in samples where Double(sample.pts) / timescale >= decodeFrom - 0.05 {
      guard let pcm = decoder.decode(sample.data) else { continue }
      out.append(EPDecodedAudio(timestampSeconds: Double(sample.pts) / timescale, buffer: pcm))
    }
    return out
  }
}

final class EPPCMNormalizer {
  let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
  private var converter: AVAudioConverter?
  private var source: AVAudioFormat?

  func normalize(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
    var input = buffer
    if input.format.channelCount == 1, let stereo = Self.duplicateToStereo(input) { input = stereo }
    if input.format.sampleRate == format.sampleRate, input.format.channelCount == format.channelCount { return input }
    if source != input.format {
      converter = AVAudioConverter(from: input.format, to: format)
      converter?.downmix = true
      source = input.format
    }
    guard let converter else { return nil }
    let capacity = AVAudioFrameCount(Double(input.frameLength) * format.sampleRate / input.format.sampleRate) + 64
    guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
    var fed = false
    var error: NSError?
    let status = converter.convert(to: out, error: &error) { _, outStatus in
      if fed {
        outStatus.pointee = .noDataNow
        return nil
      }
      fed = true
      outStatus.pointee = .haveData
      return input
    }
    guard status != .error, out.frameLength > 0 else { return nil }
    return out
  }

  private static func duplicateToStereo(_ b: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
    guard let f = AVAudioFormat(standardFormatWithSampleRate: b.format.sampleRate, channels: 2),
          let out = AVAudioPCMBuffer(pcmFormat: f, frameCapacity: b.frameLength),
          let src = b.floatChannelData, let dst = out.floatChannelData else { return nil }
    let n = Int(b.frameLength)
    dst[0].update(from: src[0], count: n)
    dst[1].update(from: src[0], count: n)
    out.frameLength = b.frameLength
    return out
  }
}

extension AVAudioPCMBuffer {
  func dropping(frames: Int) -> AVAudioPCMBuffer? {
    let remaining = Int(frameLength) - frames
    guard remaining > 0, let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(remaining)),
          let src = floatChannelData, let dst = out.floatChannelData else { return nil }
    for c in 0..<Int(format.channelCount) {
      dst[c].update(from: src[c].advanced(by: frames), count: remaining)
    }
    out.frameLength = AVAudioFrameCount(remaining)
    return out
  }

  static func concatenate(_ buffers: [AVAudioPCMBuffer]) -> AVAudioPCMBuffer? {
    guard let first = buffers.first else { return nil }
    if buffers.count == 1 { return first }
    let total = buffers.reduce(0) { $0 + Int($1.frameLength) }
    guard let out = AVAudioPCMBuffer(pcmFormat: first.format, frameCapacity: AVAudioFrameCount(total)),
          let dst = out.floatChannelData else { return nil }
    var offset = 0
    for b in buffers {
      guard let src = b.floatChannelData else { continue }
      let len = Int(b.frameLength)
      for c in 0..<Int(first.format.channelCount) {
        dst[c].advanced(by: offset).update(from: src[c], count: len)
      }
      offset += len
    }
    out.frameLength = AVAudioFrameCount(offset)
    return out
  }
}
