import Foundation

private let MAX_TRACKED_SEGMENTS = 64

final class Track: @unchecked Sendable {
    var formatId: FormatId?
    var mimeType: String?
    var endSegmentNum: Int?
    var endTimeTicks: Int?
    var endTimescale: Int?
    var targetDurationSec: Double?
    var trackedSegments = OrderedMap<Int, CompletedSegment>()
    var bufferedRangeSummary: BufferedRangeSummary?
    var emsgSegmentMetadata: EmsgSegmentMetadata?
    var initSegment: Data?

    private var _output: TrackOutput?

    let type: MediaType

    init(_ type: MediaType) {
        self.type = type
    }

    var output: TrackOutput {
        get { _output! }
        set { _output = newValue }
    }

    var streamLocked: Bool {
        return output.stream.locked
    }

    var streamDesiredSize: Int {
        return output.controller.desiredSize ?? 0
    }

    var streamController: ReadableStream<Data>.Controller {
        return output.controller
    }

    var streamFull: Bool {
        return streamLocked && streamDesiredSize <= 0
    }

    var endTimeMs: Int {
        guard let endTimeTicks, let endTimescale else { return 0 }
        return ticksToMs(endTimeTicks, endTimescale, ceil)
    }

    var endOfStreamReached: Bool {
        guard let endSegmentNum else { return false }
        return endSegmentNum > 0 && trackedSegments.has(endSegmentNum)
    }

    var latencyMs: Double? {
        guard let emsgSegmentMetadata else { return nil }
        return emsgSegmentMetadata.latencyMs
    }

    func update(_ state: TrackState) {
        if let formatId = state.formatId {
            self.formatId = formatId
        }

        if let mimeType = state.mimeType {
            self.mimeType = mimeType
        }

        if let endSegmentNum = state.endSegmentNum {
            self.endSegmentNum = endSegmentNum
        }

        if let endTimeTicks = state.endTimeTicks {
            self.endTimeTicks = endTimeTicks
        }

        if let endTimescale = state.endTimescale {
            self.endTimescale = endTimescale
        }

        if let targetDurationSec = state.targetDurationSec {
            self.targetDurationSec = targetDurationSec
        }

        if let trackedSegments = state.trackedSegments {
            self.trackedSegments = OrderedMap(trackedSegments)
        }

        if let bufferedRangeSummary = state.bufferedRangeSummary {
            self.bufferedRangeSummary = bufferedRangeSummary
        }
    }

    func snapshot() -> TrackState {
        return TrackState(
            formatId: formatId,
            mimeType: mimeType,
            endSegmentNum: endSegmentNum,
            endTimeTicks: endTimeTicks,
            endTimescale: endTimescale,
            targetDurationSec: targetDurationSec,
            bufferedRangeSummary: bufferedRangeSummary,
            trackedSegments: trackedSegments.entries.map { ($0.key, $0.value) }
        )
    }

    func discardMediaSegments() {
        for key in trackedSegments.keys where trackedSegments[key]?.mediaHeader.isInitializationSegment != true {
            trackedSegments.removeValue(forKey: key)
        }
        bufferedRangeSummary = nil
    }

    func recordCompletedSegment(_ info: SegmentInfo, _ emsgMetadata: EmsgSegmentMetadata? = nil) throws {
        var durationMs: Double? = info.durationMs

        if info.durationMs <= 0 && !info.mediaHeader.isInitializationSegment {
            if let targetDurationSec, targetDurationSec != 0 {
                durationMs = targetDurationSec * 1000
            } else {
                durationMs = nil
            }
        }

        if let emsgMetadata {
            emsgSegmentMetadata = emsgMetadata
            if emsgMetadata.targetDurationSec > 0 {
                durationMs = emsgMetadata.targetDurationSec * 1000
            }
        }

        let resolvedDurationMs = try assertIsDefined(durationMs, "Track is missing durationMs: formatKey=\(info.formatKey), segmentNumber=\(info.segmentNumber)")

        let segmentNumber = info.segmentNumber
        let mediaHeader = info.mediaHeader
        let startTimeMs = info.startTimeMs
        let endTimeMs = startTimeMs + resolvedDurationMs

        trackedSegments[segmentNumber] = CompletedSegment(
            segmentNumber: segmentNumber,
            durationMs: resolvedDurationMs,
            startTimeMs: startTimeMs,
            endTimeMs: endTimeMs,
            mediaHeader: mediaHeader
        )

        evictOldestTrackedSegments()
        refreshBufferedRanges()
    }

    private func refreshBufferedRanges() {
        var first: CompletedSegment?
        var last: CompletedSegment?

        for segment in trackedSegments.values {
            if segment.mediaHeader.isInitializationSegment { continue }
            if first == nil || segment.segmentNumber < first!.segmentNumber { first = segment }
            if last == nil || segment.segmentNumber > last!.segmentNumber { last = segment }
        }

        guard let first, let last else {
            bufferedRangeSummary = nil
            return
        }

        bufferedRangeSummary = BufferedRangeSummary(
            startTimeMs: first.startTimeMs,
            durationMs: max(0, last.endTimeMs - first.startTimeMs),
            startSegmentIndex: first.segmentNumber,
            endSegmentIndex: last.segmentNumber
        )
    }

    private func evictOldestTrackedSegments() {
        while trackedSegments.count > MAX_TRACKED_SEGMENTS {
            guard let oldestKey = trackedSegments.keys.first else { break }
            trackedSegments.removeValue(forKey: oldestKey)
        }
    }
}
