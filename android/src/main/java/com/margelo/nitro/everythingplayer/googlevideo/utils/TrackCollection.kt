package com.margelo.nitro.everythingplayer.googlevideo.utils

import com.margelo.nitro.everythingplayer.googlevideo.core.GoogleVideoError
import com.margelo.nitro.everythingplayer.googlevideo.protos.misc.FormatId
import com.margelo.nitro.everythingplayer.googlevideo.protos.video_streaming.BufferedRange
import com.margelo.nitro.everythingplayer.googlevideo.protos.video_streaming.TimeRange
import com.margelo.nitro.everythingplayer.googlevideo.types.TrackState

class TrackCollection {
  val video = Track(MediaType.VIDEO)
  val audio = Track(MediaType.AUDIO)
  var initializedTracksMap = OrderedMap<String, Track>()

  fun track(type: MediaType): Track = if (type == MediaType.VIDEO) video else audio

  val needsDrain: Boolean
    get() = video.streamFull || audio.streamFull

  val buffered: Double
    get() {
      var bufferedUntil = Double.POSITIVE_INFINITY

      for (track in initializedTracks) {
        val summary = track.bufferedRangeSummary ?: return 0.0
        bufferedUntil = minOf(bufferedUntil, summary.startTimeMs + summary.durationMs)
      }

      return bufferedUntil
    }

  val bufferedRanges: List<BufferedRange>
    get() {
      val ranges = mutableListOf<BufferedRange>()

      for (track in initializedTracks) {
        val summary = track.bufferedRangeSummary ?: continue

        ranges.add(
          BufferedRange.newBuilder()
            .setFormatId(track.formatId ?: FormatId.getDefaultInstance())
            .setStartTimeMs(summary.startTimeMs.toLong())
            .setDurationMs(summary.durationMs.toLong())
            .setStartSegmentIndex(summary.startSegmentIndex)
            .setEndSegmentIndex(summary.endSegmentIndex)
            .setTimeRange(
              TimeRange.newBuilder()
                .setStartTicks(summary.startTimeMs.toLong())
                .setDurationTicks(summary.durationMs.toLong())
                .setTimescale(1000),
            )
            .build(),
        )
      }

      return ranges
    }

  val initializedTracks: List<Track>
    get() = initializedTracksMap.values.toList()

  val initializationFormatIds: List<FormatId>
    get() {
      val formatIds = mutableListOf<FormatId>()
      video.formatId?.let { formatIds.add(it) }
      audio.formatId?.let { formatIds.add(it) }
      return formatIds
    }

  val livePlaybackLatencyMs: Double?
    get() {
      val videoLatency = video.latencyMs
      val audioLatency = audio.latencyMs

      if (videoLatency == null && audioLatency == null) {
        return null
      }

      return maxOf(videoLatency ?: 0.0, audioLatency ?: 0.0)
    }

  fun initialize(type: MediaType, metadata: TrackState) {
    track(type).update(metadata)
    val formatId = metadata.formatId
    if (formatId != null) {
      initializedTracksMap[createFormatKey(formatId)] = track(type)
    }
  }

  fun getInitializedTrack(formatKey: String): Track? = initializedTracksMap[formatKey]

  fun endOfStreamReached(enabledTrackTypes: EnabledTrackTypes): Boolean {
    val videoEndOfStreamReached = video.endOfStreamReached
    val audioEndOfStreamReached = audio.endOfStreamReached

    return (videoEndOfStreamReached && audioEndOfStreamReached) ||
      (enabledTrackTypes == EnabledTrackTypes.VIDEO_ONLY && videoEndOfStreamReached) ||
      (enabledTrackTypes == EnabledTrackTypes.AUDIO_ONLY && audioEndOfStreamReached)
  }

  fun snapshot(): List<TrackState> {
    val trackStates = mutableListOf<TrackState>()

    for (initializedTrack in initializedTracksMap.values) {
      trackStates.add(initializedTrack.snapshot())
    }

    return trackStates
  }

  fun error(err: String) {
    error(GoogleVideoError(err))
  }

  fun error(err: Throwable) {
    video.streamController.error(err)
    audio.streamController.error(err)
  }

  fun close() {
    video.streamController.close()
    audio.streamController.close()
  }
}
