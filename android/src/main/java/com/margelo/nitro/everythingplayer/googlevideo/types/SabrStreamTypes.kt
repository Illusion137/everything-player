package com.margelo.nitro.everythingplayer.googlevideo.types

import com.margelo.nitro.everythingplayer.googlevideo.protos.misc.FormatId
import com.margelo.nitro.everythingplayer.googlevideo.protos.video_streaming.MediaHeader
import com.margelo.nitro.everythingplayer.googlevideo.protos.video_streaming.ReloadPlaybackContext
import com.margelo.nitro.everythingplayer.googlevideo.protos.video_streaming.SabrLiveMetadata
import com.margelo.nitro.everythingplayer.googlevideo.protos.video_streaming.StreamProtectionStatus
import com.margelo.nitro.everythingplayer.googlevideo.utils.ClientInfo
import com.margelo.nitro.everythingplayer.googlevideo.utils.EnabledTrackTypes
import com.margelo.nitro.everythingplayer.googlevideo.utils.EventName
import com.margelo.nitro.everythingplayer.googlevideo.utils.ReadableStream
import com.margelo.nitro.everythingplayer.googlevideo.utils.Track
import com.margelo.nitro.everythingplayer.googlevideo.utils.TrackCollection

class SabrStreamConfig(
  var videoId: String,
  var fetchFunction: FetchFunction? = null,
  var serverAbrStreamingUrl: String,
  var videoPlaybackUstreamerConfig: String,
  var heartbeatParams: HeartbeatParams? = null,
  var poToken: String? = null,
  var clientInfo: ClientInfo,
  var formats: List<SabrFormat>,
  var callbacks: SabrStreamCallbacks? = null,
  var stripDuplicateInit: Boolean? = null,
  var videoHighWaterMark: Int? = null,
  var audioHighWaterMark: Int? = null,
)

class SabrStreamCallbacks(
  var onCheckHeartbeat: (suspend (HeartbeatRequest) -> HeartbeatResponse)? = null,
  var onReloadPlayerResponse: (suspend (ReloadPlaybackContext?) -> ReloadResponse)? = null,
  var onMintPoToken: (suspend () -> ByteArray)? = null,
)

data class SelectedFormats(
  var videoFormat: SabrFormat? = null,
  var audioFormat: SabrFormat,
)

class StreamStartResult(
  var videoStream: ReadableStream<ByteArray>,
  var audioStream: ReadableStream<ByteArray>,
  var selectedFormats: SelectedFormats,
)

object SabrStreamEvent {
  val trackStateUpdate = EventName<TrackCollection>("trackStateUpdate")
  val formatInitialization = EventName<Track>("formatInitialization")
  val streamProtectionStatusUpdate = EventName<StreamProtectionStatus>("streamProtectionStatusUpdate")
  val liveMetadataUpdate = EventName<SabrLiveMetadata>("liveMetadataUpdate")
  val finish = EventName<Unit>("finish")
  val abort = EventName<Unit>("abort")
  val error = EventName<Throwable>("error")
}

enum class HeartbeatCheckType(val rawValue: String) {
  UNKNOWN("HEARTBEAT_CHECK_TYPE_UNKNOWN"),
  LIVE_STREAM_STATUS("HEARTBEAT_CHECK_TYPE_LIVE_STREAM_STATUS"),
  YPC("HEARTBEAT_CHECK_TYPE_YPC"),
  UNPLUGGED("HEARTBEAT_CHECK_TYPE_UNPLUGGED"),
}

data class HeartbeatRequestParams(
  var heartbeatChecks: List<HeartbeatCheckType>? = null,
)

data class HeartbeatRequest(
  var heartbeatRequestParams: HeartbeatRequestParams? = null,
  var heartbeatServerData: String? = null,
  var heartbeatToken: String? = null,
  var videoId: String? = null,
)

enum class PlayabilityStatus(val rawValue: String) {
  OK("OK"),
  ERROR("ERROR"),
  UNPLAYABLE("UNPLAYABLE"),
  LOGIN_REQUIRED("LOGIN_REQUIRED"),
  CONTENT_CHECK_REQUIRED("CONTENT_CHECK_REQUIRED"),
  AGE_CHECK_REQUIRED("AGE_CHECK_REQUIRED"),
  LIVE_STREAM_OFFLINE("LIVE_STREAM_OFFLINE"),
  FULLSCREEN_ONLY("FULLSCREEN_ONLY"),
  GL_PLAYBACK_REQUIRED("GL_PLAYBACK_REQUIRED"),
  AGE_VERIFICATION_REQUIRED("AGE_VERIFICATION_REQUIRED"),
}

data class HeartbeatResponse(
  var status: PlayabilityStatus? = null,
  var broadcastId: String? = null,
  var pollDelayMs: String? = null,
  var displayEndscreen: Boolean? = null,
  var offlineSlatePresent: Boolean? = null,
  var offlineSlateButtonsPresent: Boolean? = null,
  var heartbeatServerData: String? = null,
)

data class HeartbeatParams(
  var heartbeatServerData: String? = null,
  var heartbeatToken: String? = null,
  var intervalMilliseconds: String? = null,
)

data class ReloadResponse(
  var serverAbrStreamingUrl: String,
  var videoPlaybackUstreamerConfig: String,
)

sealed class FormatSelector {
  data class Itag(val itag: Int) : FormatSelector()
  data class Format(val format: SabrFormat) : FormatSelector()
  class Selector(val selector: (List<SabrFormat>) -> SabrFormat?) : FormatSelector()
}

class SabrPlaybackOptions(
  var videoFormat: FormatSelector? = null,
  var audioFormat: FormatSelector? = null,
  var videoPreferences: VideoFormatPreferences? = null,
  var audioPreferences: AudioFormatPreferences? = null,
  var enabledTrackTypes: EnabledTrackTypes? = null,
  var startTimeMs: Long? = null,
  var isPostLiveDvr: Boolean,
  var maxRetries: Int? = null,
  var stallDetectionMs: Long? = null,
  var snapshot: SabrSnapshot? = null,
)

enum class MediaContainer(val rawValue: String) {
  WEBM("webm"),
  MP4("mp4"),
}

enum class PreferredVideoCodec(val rawValue: String) {
  H264("h264"),
  VP9("vp9"),
  AV1("av1"),
}

enum class PreferredAudioCodec(val rawValue: String) {
  AAC("aac"),
  OPUS("opus"),
}

enum class AudioQualityLabel(val rawValue: String) {
  ULTRALOW("AUDIO_QUALITY_ULTRALOW"),
  LOW("AUDIO_QUALITY_LOW"),
  MEDIUM("AUDIO_QUALITY_MEDIUM"),
  HIGH("AUDIO_QUALITY_HIGH"),
}

data class VideoFormatPreferences(
  var quality: String? = null,
  var container: MediaContainer? = null,
  var preferredVideoCodec: PreferredVideoCodec? = null,
  var superResolution: Boolean? = null,
  var hdr: Boolean? = null,
)

data class AudioFormatPreferences(
  var quality: AudioQualityLabel? = null,
  var language: String? = null,
  var container: MediaContainer? = null,
  var preferredAudioCodec: PreferredAudioCodec? = null,
  var voiceBoost: Boolean? = null,
  var dynamicRangeCompression: Boolean? = null,
)

data class AbortOptions(
  var snapshot: Boolean? = null,
)

class TrackOutput(
  var stream: ReadableStream<ByteArray>,
  var controller: ReadableStream.Controller<ByteArray>,
)

data class SabrSnapshot(
  var playerTimeMs: Long,
  var tracks: List<TrackState>,
)

data class TrackState(
  var formatId: FormatId? = null,
  var mimeType: String? = null,
  var endSegmentNum: Int? = null,
  var endTimeTicks: Long? = null,
  var endTimescale: Long? = null,
  var targetDurationSec: Double? = null,
  var bufferedRangeSummary: BufferedRangeSummary? = null,
  var trackedSegments: List<Pair<Int, CompletedSegment>>? = null,
) : CreateFormatKeyInput {
  override val formatKeyCandidates: List<FormatKeyCandidate>
    get() {
      val formatId = formatId ?: return emptyList()
      return listOf(
        FormatKeyCandidate(
          if (formatId.hasItag()) formatId.itag else null,
          if (formatId.hasXtags()) formatId.xtags else null,
        ),
      )
    }
}

data class CompletedSegment(
  var segmentNumber: Int,
  var durationMs: Double,
  var startTimeMs: Double,
  var endTimeMs: Double,
  var mediaHeader: MediaHeader,
)

data class SegmentInfo(
  var formatKey: String,
  var segmentNumber: Int,
  var mediaHeader: MediaHeader,
  var startTimeMs: Double,
  var durationMs: Double,
)

data class BufferedRangeSummary(
  var startTimeMs: Double,
  var durationMs: Double,
  var startSegmentIndex: Int,
  var endSegmentIndex: Int,
)
