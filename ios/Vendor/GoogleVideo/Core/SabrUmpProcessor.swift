import Foundation

private final class Segment {
    var headerId: Int?
    var mediaHeader: MediaHeader
    var complete: Bool?
    var bufferedChunks: [Data]
    var lastChunkSize: Int

    init(headerId: Int?, mediaHeader: MediaHeader, bufferedChunks: [Data], lastChunkSize: Int) {
        self.headerId = headerId
        self.mediaHeader = mediaHeader
        self.bufferedChunks = bufferedChunks
        self.lastChunkSize = lastChunkSize
    }
}

struct UmpProcessingResult {
    var data: Data?
    var done: Bool

    init(data: Data? = nil, done: Bool) {
        self.data = data
        self.done = done
    }
}

final class SabrUmpProcessor {
    private var formatInitMetadata: [FormatInitializationMetadata] = []
    private var desiredHeaderId: Int?
    private var partialSegments: [Int: Segment] = [:]
    private var umpReader: UmpReader!

    private var returnData: UmpProcessingResult?

    private let requestMetadata: SabrRequestMetadata
    private let cacheManager: CacheManager?

    init(_ requestMetadata: SabrRequestMetadata, _ cacheManager: CacheManager? = nil) {
        self.requestMetadata = requestMetadata
        self.cacheManager = cacheManager
        self.umpReader = UmpReader(UmpReaderCallbacks(
            onPart: { [unowned self] type, data in
                let part = Part(type: type, size: data.getLength(), data: data)
                if let result = try self.handlePart(part) {
                    self.desiredHeaderId = nil
                    self.partialSegments.removeAll()
                    self.returnData = result
                }
            }
        ))
    }

    func processChunk(_ value: Data) async throws -> UmpProcessingResult? {
        returnData = nil
        try await umpReader.feed(value)
        return returnData
    }

    private func handlePart(_ part: Part) throws -> UmpProcessingResult? {
        switch UMPPartId(rawValue: part.type) {
        case .formatInitializationMetadata: return handleFormatInitMetadata(part)
        case .nextRequestPolicy: return handleNextRequestPolicy(part)
        case .sabrError: return handleSabrError(part)
        case .sabrRedirect: return handleSabrRedirect(part)
        case .sabrContextUpdate: return handleSabrContextUpdate(part)
        case .sabrContextSendingPolicy: return handleSabrContextSendingPolicy(part)
        case .snackbarMessage: return handleSnackbarMessage(part)
        case .streamProtectionStatus: return handleStreamProtectionStatus(part)
        case .reloadPlayerResponse: return handleReloadPlayerResponse(part)
        case .mediaHeader: return try handleMediaHeader(part)
        case .media: return handleMedia(part)
        case .mediaEnd: return try handleMediaEnd(part)
        default: return nil
        }
    }

    private func updateStreamInfo(_ update: (inout SabrRequestStreamInfo) -> Void) {
        var streamInfo = requestMetadata.streamInfo ?? SabrRequestStreamInfo()
        update(&streamInfo)
        requestMetadata.streamInfo = streamInfo
    }

    private func handleFormatInitMetadata(_ part: Part) -> UmpProcessingResult? {
        if let formatInitMetadata = decodePart(part.data.chunks, FormatInitializationMetadata.self) {
            self.formatInitMetadata.append(formatInitMetadata)
        }
        return nil
    }

    private func handleNextRequestPolicy(_ part: Part) -> UmpProcessingResult? {
        if let nextRequestPolicy = decodePart(part.data.chunks, NextRequestPolicy.self) {
            updateStreamInfo { $0.nextRequestPolicy = nextRequestPolicy }
        }
        return nil
    }

    private func handleMediaHeader(_ part: Part) throws -> UmpProcessingResult? {
        guard let mediaHeader = decodePart(part.data.chunks, MediaHeader.self) else {
            return nil
        }

        let targetFormatKey = try createFormatKey(requestMetadata.format!)
        let segmentFormatKey = try createFormatKey(mediaHeader)

        if requestMetadata.isSABR != true || segmentFormatKey == targetFormatKey {
            let headerId = mediaHeader.hasHeaderID ? Int(mediaHeader.headerID) : nil

            let segmentObj = Segment(
                headerId: headerId,
                mediaHeader: mediaHeader,
                bufferedChunks: [],
                lastChunkSize: 0
            )

            if desiredHeaderId == nil {
                desiredHeaderId = headerId
            }

            partialSegments[headerId ?? 0] = segmentObj
        }

        return nil
    }

    private func handleMedia(_ part: Part) -> UmpProcessingResult? {
        let headerId = Int(part.data.getUint8(0))
        let buffer = part.data.split(1).remainingBuffer

        if let segment = partialSegments[headerId] {
            segment.lastChunkSize = buffer.getLength()
            for chunk in buffer.chunks {
                segment.bufferedChunks.append(chunk)
            }
        }

        return nil
    }

    private func handleMediaEnd(_ part: Part) throws -> UmpProcessingResult? {
        let headerId = Int(part.data.getUint8(0))

        if let segment = partialSegments[headerId], segment.headerId == desiredHeaderId {
            let segmentData = concatenateChunks(segment.bufferedChunks)

            updateStreamInfo {
                $0.formatInitMetadata = self.formatInitMetadata
                $0.mediaHeader = segment.mediaHeader
            }

            if requestMetadata.isInit == true, let byteRange = requestMetadata.byteRange, let format = requestMetadata.format {
                if let cacheManager {
                    cacheManager.setInitSegment(
                        createSegmentCacheKey(segment.mediaHeader, format),
                        segmentData
                    )
                }

                let start = min(max(byteRange.start, 0), segmentData.count)
                let end = min(max(byteRange.end + 1, start), segmentData.count)

                return UmpProcessingResult(
                    data: Data(segmentData.subdata(in: start..<end)),
                    done: true
                )
            }

            return UmpProcessingResult(
                data: segmentData,
                done: true
            )
        }

        return nil
    }

    private func handleSnackbarMessage(_ part: Part) -> UmpProcessingResult? {
        if let snackbarMessage = decodePart(part.data.chunks, SnackbarMessage.self) {
            updateStreamInfo { $0.snackbarMessage = snackbarMessage }
        }
        return nil
    }

    private func handleSabrError(_ part: Part) -> UmpProcessingResult? {
        let sabrError = decodePart(part.data.chunks, SabrError.self)
        requestMetadata.error = SabrRequestError(sabrError: sabrError)
        return UmpProcessingResult(done: true)
    }

    private func handleStreamProtectionStatus(_ part: Part) -> UmpProcessingResult? {
        guard let streamProtectionStatus = decodePart(part.data.chunks, StreamProtectionStatus.self) else {
            return nil
        }

        updateStreamInfo { $0.streamProtectionStatus = streamProtectionStatus }

        if streamProtectionStatus.status == 3 {
            return UmpProcessingResult(done: true)
        }

        return nil
    }

    private func handleReloadPlayerResponse(_ part: Part) -> UmpProcessingResult? {
        guard let reloadPlaybackContext = decodePart(part.data.chunks, ReloadPlaybackContext.self) else {
            return nil
        }

        updateStreamInfo { $0.reloadPlaybackContext = reloadPlaybackContext }

        return UmpProcessingResult(done: true)
    }

    private func handleSabrRedirect(_ part: Part) -> UmpProcessingResult? {
        guard let redirect = decodePart(part.data.chunks, SabrRedirect.self) else {
            return nil
        }

        updateStreamInfo { $0.redirect = redirect }

        if requestMetadata.isUMP == true && requestMetadata.isSABR != true {
            return UmpProcessingResult(done: true)
        }

        return nil
    }

    private func handleSabrContextUpdate(_ part: Part) -> UmpProcessingResult? {
        if let sabrContextUpdate = decodePart(part.data.chunks, SabrContextUpdate.self) {
            updateStreamInfo { $0.sabrContextUpdate = sabrContextUpdate }
        }
        return nil
    }

    private func handleSabrContextSendingPolicy(_ part: Part) -> UmpProcessingResult? {
        if let sabrContextSendingPolicy = decodePart(part.data.chunks, SabrContextSendingPolicy.self) {
            updateStreamInfo { $0.sabrContextSendingPolicy = sabrContextSendingPolicy }
        }
        return nil
    }

    func dispose() {
        returnData = nil
        desiredHeaderId = nil
        partialSegments.removeAll()
        umpReader.dispose()
    }
}
