import Foundation

final class TrackCollection: @unchecked Sendable {
    let video = Track(.video)
    let audio = Track(.audio)
    var initializedTracksMap = OrderedMap<String, Track>()

    init() {}

    func track(_ type: MediaType) -> Track {
        return type == .video ? video : audio
    }

    var needsDrain: Bool {
        return video.streamFull || audio.streamFull
    }

    var buffered: Double {
        var bufferedUntil = Double.infinity

        for track in initializedTracks {
            guard let summary = track.bufferedRangeSummary else { return 0 }
            bufferedUntil = min(bufferedUntil, summary.startTimeMs + summary.durationMs)
        }

        return bufferedUntil
    }

    var bufferedRanges: [BufferedRange] {
        var ranges: [BufferedRange] = []

        for track in initializedTracks {
            guard let summary = track.bufferedRangeSummary else { continue }

            var range = BufferedRange()
            range.formatID = track.formatId ?? FormatId()
            range.startTimeMs = Int64(summary.startTimeMs)
            range.durationMs = Int64(summary.durationMs)
            range.startSegmentIndex = Int32(summary.startSegmentIndex)
            range.endSegmentIndex = Int32(summary.endSegmentIndex)
            range.timeRange.startTicks = Int64(summary.startTimeMs)
            range.timeRange.durationTicks = Int64(summary.durationMs)
            range.timeRange.timescale = 1000
            ranges.append(range)
        }

        return ranges
    }

    var initializedTracks: [Track] {
        return initializedTracksMap.values
    }

    var initializationFormatIds: [FormatId] {
        var formatIds: [FormatId] = []
        if let formatId = video.formatId { formatIds.append(formatId) }
        if let formatId = audio.formatId { formatIds.append(formatId) }
        return formatIds
    }

    var livePlaybackLatencyMs: Double? {
        let videoLatency = video.latencyMs
        let audioLatency = audio.latencyMs

        if videoLatency == nil && audioLatency == nil {
            return nil
        }

        return max(videoLatency ?? 0, audioLatency ?? 0)
    }

    func initialize(_ type: MediaType, _ metadata: TrackState) throws {
        track(type).update(metadata)
        if let formatId = metadata.formatId {
            initializedTracksMap[try createFormatKey(formatId)] = track(type)
        }
    }

    func getInitializedTrack(_ formatKey: String) -> Track? {
        return initializedTracksMap[formatKey]
    }

    func endOfStreamReached(_ enabledTrackTypes: EnabledTrackTypes) -> Bool {
        let videoEndOfStreamReached = video.endOfStreamReached
        let audioEndOfStreamReached = audio.endOfStreamReached

        return (videoEndOfStreamReached && audioEndOfStreamReached)
            || (enabledTrackTypes == .videoOnly && videoEndOfStreamReached)
            || (enabledTrackTypes == .audioOnly && audioEndOfStreamReached)
    }

    func snapshot() -> [TrackState] {
        var trackStates: [TrackState] = []

        for initializedTrack in initializedTracksMap.values {
            trackStates.append(initializedTrack.snapshot())
        }

        return trackStates
    }

    func error(_ err: String) {
        error(GoogleVideoError(err))
    }

    func error(_ err: any Error) {
        video.streamController.error(err)
        audio.streamController.error(err)
    }

    func close() {
        video.streamController.close()
        audio.streamController.close()
    }
}
