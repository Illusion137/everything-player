import Foundation

private struct PendingSegment {
    var info: SegmentInfo
    var bufferedChunks: [Data]
    var loadedLengthBytes: Int
    var type: MediaType
}

private let TAG = "SabrSegmentBuffer"

final class SabrSegmentBuffer {
    private let logger = Logger.getInstance()
    private var pendingSegments: [Int: PendingSegment] = [:]

    private let trackMetadata: TrackCollection
    private let isBroadcast: Bool
    private let stripDuplicateInit: Bool

    init(
        _ trackMetadata: TrackCollection,
        _ isBroadcast: Bool = false,
        _ stripDuplicateInit: Bool = true
    ) {
        self.trackMetadata = trackMetadata
        self.isBroadcast = isBroadcast
        self.stripDuplicateInit = stripDuplicateInit
    }

    func reset() {
        trackMetadata.initializedTracksMap.removeAll()
        pendingSegments.removeAll()
    }

    func discardPending() {
        pendingSegments.removeAll()
    }

    func queueMediaHeader(_ mediaHeader: MediaHeader) throws {
        let headerId = Int(mediaHeader.hasHeaderID ? mediaHeader.headerID : 0)
        let formatKey = try createFormatKey(mediaHeader)

        guard let track = trackMetadata.initializedTracksMap[formatKey] else {
            logger.warn(TAG, "No track found: formatKey=\(formatKey), headerId=\(headerId)")
            return
        }

        let segmentNumber = mediaHeader.isInitializationSegment ? 0 : Int(mediaHeader.segmentNum)

        if track.trackedSegments.has(segmentNumber) {
            logger.debug(TAG, "Ignoring recently downloaded segment: formatKey=\(formatKey), segmentNumber=\(segmentNumber)")
            return
        }

        pendingSegments[headerId] = PendingSegment(
            info: SegmentInfo(
                formatKey: formatKey,
                segmentNumber: segmentNumber,
                mediaHeader: mediaHeader,
                startTimeMs: Double(getStartMs(mediaHeader)),
                durationMs: Double(getDurationMs(mediaHeader))
            ),
            bufferedChunks: [],
            loadedLengthBytes: 0,
            type: track.type
        )
    }

    func appendMediaData(_ headerId: Int, _ buffer: CompositeBuffer) {
        guard pendingSegments[headerId] != nil else {
            logger.debug(TAG, "Received MEDIA for unknown header id \(headerId)")
            return
        }

        pendingSegments[headerId]!.bufferedChunks.append(contentsOf: buffer.chunks)
        pendingSegments[headerId]!.loadedLengthBytes += buffer.getLength()
    }

    func finalizeSegment(_ headerId: Int) throws -> Bool {
        guard let pendingSegment = pendingSegments[headerId] else {
            logger.debug(TAG, "Received MEDIA_END for unknown header id \(headerId)")
            return false
        }

        guard let track = trackMetadata.getInitializedTrack(pendingSegment.info.formatKey) else {
            pendingSegments.removeValue(forKey: headerId)
            return false
        }

        let expectedLengthBytes = Int(pendingSegment.info.mediaHeader.segmentLengthBytes)
        let loadedLengthBytes = pendingSegment.loadedLengthBytes

        if expectedLengthBytes > 0 && loadedLengthBytes != expectedLengthBytes {
            logger.warn(
                TAG,
                "Ignoring partial segment \(pendingSegment.info.segmentNumber) for \(pendingSegment.info.formatKey).\n" +
                    "expected=\(expectedLengthBytes), received=\(loadedLengthBytes)"
            )
            pendingSegments.removeValue(forKey: headerId)
            return false
        }

        var segment = concatenateChunks(pendingSegment.bufferedChunks)

        let emsgMetadata = parseEmsgSegmentMetadata(segment)

        if isBroadcast && stripDuplicateInit && track.trackedSegments.count != 0 {
            segment = track.mimeType?.contains("webm") == true ? stripWebmInit(segment) : stripMp4Init(segment)
        }

        if pendingSegment.info.mediaHeader.isInitializationSegment {
            track.initSegment = segment
        }

        if track.streamLocked || track.streamDesiredSize > 0 {
            track.streamController.enqueue(segment)
        }

        try track.recordCompletedSegment(pendingSegment.info, emsgMetadata)

        pendingSegments.removeValue(forKey: headerId)

        return !pendingSegment.info.mediaHeader.isInitializationSegment
    }
}
