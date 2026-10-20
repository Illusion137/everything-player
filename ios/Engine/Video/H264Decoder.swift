import AVFoundation
import VideoToolbox

struct EPVideoFrame {
  let pts: Double
  let buffer: CVPixelBuffer
}

final class EPDecodedFrameQueue: EPVideoFrameSource {
  private let lock = NSLock()
  private var frames: [EPVideoFrame] = []
  private let capacity: Int
  private var needsFirstFrame = true
  var clock: () -> Double = { 0 }

  init(capacity: Int = 24) {
    self.capacity = capacity
  }

  var isFull: Bool {
    lock.lock(); defer { lock.unlock() }
    return frames.count >= capacity
  }

  var lastPts: Double? {
    lock.lock(); defer { lock.unlock() }
    return frames.last?.pts
  }

  func push(_ frame: EPVideoFrame) {
    lock.lock()
    let index = frames.firstIndex { $0.pts > frame.pts } ?? frames.endIndex
    frames.insert(frame, at: index)
    lock.unlock()
  }

  func flush() {
    lock.lock()
    frames.removeAll()
    needsFirstFrame = true
    lock.unlock()
  }

  func pixelBuffer(forHostTime hostTime: CFTimeInterval) -> CVPixelBuffer? {
    let now = clock()
    lock.lock()
    defer { lock.unlock() }
    var picked: CVPixelBuffer?
    while let first = frames.first, first.pts <= now {
      picked = first.buffer
      frames.removeFirst()
    }
    if picked == nil, needsFirstFrame, let first = frames.first {
      picked = first.buffer
    }
    if picked != nil { needsFirstFrame = false }
    return picked
  }
}

final class EPH264Decoder {
  private var session: VTDecompressionSession?
  private var formatDescription: CMVideoFormatDescription?
  private let timescale: Int32
  private let output: (EPVideoFrame) -> Void

  convenience init(avcC: Data, width: Int, height: Int, timescale: UInt32, output: @escaping (EPVideoFrame) -> Void) throws {
    let extensions: [CFString: Any] = [
      kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms: ["avcC": avcC as CFData],
    ]
    var desc: CMVideoFormatDescription?
    let status = CMVideoFormatDescriptionCreate(
      allocator: kCFAllocatorDefault, codecType: kCMVideoCodecType_H264,
      width: Int32(width), height: Int32(height),
      extensions: extensions as CFDictionary, formatDescriptionOut: &desc)
    guard status == noErr, let desc else { throw EPError(.decodeError, "Invalid avcC (\(status))") }
    try self.init(format: desc, timescale: timescale, output: output)
  }

  convenience init(parameterSets: EPH264ParameterSets, timescale: UInt32, output: @escaping (EPVideoFrame) -> Void) throws {
    var desc: CMVideoFormatDescription?
    let status = parameterSets.sps.withUnsafeBytes { sps in
      parameterSets.pps.withUnsafeBytes { pps in
        let pointers = [sps.bindMemory(to: UInt8.self).baseAddress!, pps.bindMemory(to: UInt8.self).baseAddress!]
        let sizes = [parameterSets.sps.count, parameterSets.pps.count]
        return CMVideoFormatDescriptionCreateFromH264ParameterSets(
          allocator: kCFAllocatorDefault, parameterSetCount: 2, parameterSetPointers: pointers,
          parameterSetSizes: sizes, nalUnitHeaderLength: 4, formatDescriptionOut: &desc)
      }
    }
    guard status == noErr, let desc else { throw EPError(.decodeError, "Invalid H.264 parameter sets (\(status))") }
    try self.init(format: desc, timescale: timescale, output: output)
  }

  private init(format desc: CMVideoFormatDescription, timescale: UInt32, output: @escaping (EPVideoFrame) -> Void) throws {
    self.timescale = Int32(clamping: timescale)
    self.output = output
    formatDescription = desc

    let attrs: [CFString: Any] = [
      kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
      kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
    ]
    var callback = VTDecompressionOutputCallbackRecord(
      decompressionOutputCallback: { refCon, _, status, _, imageBuffer, pts, _ in
        guard status == noErr, let refCon, let imageBuffer else { return }
        let decoder = Unmanaged<EPH264Decoder>.fromOpaque(refCon).takeUnretainedValue()
        decoder.output(EPVideoFrame(pts: pts.seconds, buffer: imageBuffer))
      },
      decompressionOutputRefCon: Unmanaged.passUnretained(self).toOpaque())
    var newSession: VTDecompressionSession?
    let s = VTDecompressionSessionCreate(
      allocator: kCFAllocatorDefault, formatDescription: desc, decoderSpecification: nil,
      imageBufferAttributes: attrs as CFDictionary, outputCallback: &callback,
      decompressionSessionOut: &newSession)
    guard s == noErr, let newSession else { throw EPError(.decodeError, "VTDecompressionSessionCreate failed (\(s))") }
    session = newSession
  }

  deinit { invalidate() }

  func invalidate() {
    if let session {
      VTDecompressionSessionWaitForAsynchronousFrames(session)
      VTDecompressionSessionInvalidate(session)
    }
    session = nil
  }

  func decode(_ sample: EPMP4Sample) {
    guard let session, let formatDescription else { return }
    var block: CMBlockBuffer?
    let length = sample.data.count
    guard CMBlockBufferCreateWithMemoryBlock(
      allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: length,
      blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
      dataLength: length, flags: 0, blockBufferOut: &block) == noErr, let block else { return }
    sample.data.withUnsafeBytes { raw in
      _ = CMBlockBufferReplaceDataBytes(with: raw.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: length)
    }
    var timing = CMSampleTimingInfo(
      duration: CMTime(value: sample.duration, timescale: timescale),
      presentationTimeStamp: CMTime(value: sample.pts, timescale: timescale),
      decodeTimeStamp: CMTime(value: sample.dts, timescale: timescale))
    var sampleSize = length
    var sampleBuffer: CMSampleBuffer?
    guard CMSampleBufferCreateReady(
      allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: formatDescription,
      sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
      sampleSizeEntryCount: 1, sampleSizeArray: &sampleSize, sampleBufferOut: &sampleBuffer) == noErr,
      let sampleBuffer else { return }
    VTDecompressionSessionDecodeFrame(
      session, sampleBuffer: sampleBuffer,
      flags: [._EnableAsynchronousDecompression, ._EnableTemporalProcessing],
      frameRefcon: nil, infoFlagsOut: nil)
  }

  func flush() {
    guard let session else { return }
    VTDecompressionSessionFinishDelayedFrames(session)
    VTDecompressionSessionWaitForAsynchronousFrames(session)
  }
}
