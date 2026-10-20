import Foundation

struct SabrStreamConfig {
    var videoId: String
    var fetchFunction: FetchFunction?
    var serverAbrStreamingUrl: String
    var videoPlaybackUstreamerConfig: String
    var heartbeatParams: HeartbeatParams?
    var clientInfo: ClientInfo
    var poToken: String?
    var formats: [SabrFormat]
    var callbacks: SabrStreamCallbacks?
    var stripDuplicateInit: Bool?
    var videoHighWaterMark: Int?
    var audioHighWaterMark: Int?

    init(
        videoId: String,
        fetchFunction: FetchFunction? = nil,
        serverAbrStreamingUrl: String,
        videoPlaybackUstreamerConfig: String,
        heartbeatParams: HeartbeatParams? = nil,
        poToken: String? = nil,
        clientInfo: ClientInfo,
        formats: [SabrFormat],
        callbacks: SabrStreamCallbacks? = nil,
        stripDuplicateInit: Bool? = nil,
        videoHighWaterMark: Int? = nil,
        audioHighWaterMark: Int? = nil
    ) {
        self.videoId = videoId
        self.fetchFunction = fetchFunction
        self.serverAbrStreamingUrl = serverAbrStreamingUrl
        self.videoPlaybackUstreamerConfig = videoPlaybackUstreamerConfig
        self.heartbeatParams = heartbeatParams
        self.poToken = poToken
        self.clientInfo = clientInfo
        self.formats = formats
        self.callbacks = callbacks
        self.stripDuplicateInit = stripDuplicateInit
        self.videoHighWaterMark = videoHighWaterMark
        self.audioHighWaterMark = audioHighWaterMark
    }
}

struct SabrStreamCallbacks {
    var onCheckHeartbeat: (@Sendable (HeartbeatRequest) async throws -> HeartbeatResponse)?
    var onReloadPlayerResponse: (@Sendable (ReloadPlaybackContext?) async throws -> ReloadResponse)?
    var onMintPoToken: (@Sendable () async throws -> Data)?

    init(
        onCheckHeartbeat: (@Sendable (HeartbeatRequest) async throws -> HeartbeatResponse)? = nil,
        onReloadPlayerResponse: (@Sendable (ReloadPlaybackContext?) async throws -> ReloadResponse)? = nil,
        onMintPoToken: (@Sendable () async throws -> Data)? = nil
    ) {
        self.onCheckHeartbeat = onCheckHeartbeat
        self.onReloadPlayerResponse = onReloadPlayerResponse
        self.onMintPoToken = onMintPoToken
    }
}

struct SelectedFormats: Sendable {
    var videoFormat: SabrFormat?
    var audioFormat: SabrFormat

    init(videoFormat: SabrFormat? = nil, audioFormat: SabrFormat) {
        self.videoFormat = videoFormat
        self.audioFormat = audioFormat
    }
}

struct StreamStartResult: Sendable {
    var videoStream: ReadableStream<Data>
    var audioStream: ReadableStream<Data>
    var selectedFormats: SelectedFormats

    init(videoStream: ReadableStream<Data>, audioStream: ReadableStream<Data>, selectedFormats: SelectedFormats) {
        self.videoStream = videoStream
        self.audioStream = audioStream
        self.selectedFormats = selectedFormats
    }
}

typealias SabrStreamEvent<Payload> = EventName<Payload>

extension EventName where Payload == TrackCollection {
    static var trackStateUpdate: SabrStreamEvent<TrackCollection> { EventName("trackStateUpdate") }
}

extension EventName where Payload == Track {
    static var formatInitialization: SabrStreamEvent<Track> { EventName("formatInitialization") }
}

extension EventName where Payload == StreamProtectionStatus {
    static var streamProtectionStatusUpdate: SabrStreamEvent<StreamProtectionStatus> { EventName("streamProtectionStatusUpdate") }
}

extension EventName where Payload == SabrLiveMetadata {
    static var liveMetadataUpdate: SabrStreamEvent<SabrLiveMetadata> { EventName("liveMetadataUpdate") }
}

extension EventName where Payload == Void {
    static var finish: SabrStreamEvent<Void> { EventName("finish") }
    static var abort: SabrStreamEvent<Void> { EventName("abort") }
}

extension EventName where Payload == any Error {
    static var error: SabrStreamEvent<any Error> { EventName("error") }
}

enum HeartbeatCheckType: String, Sendable {
    case unknown = "HEARTBEAT_CHECK_TYPE_UNKNOWN"
    case liveStreamStatus = "HEARTBEAT_CHECK_TYPE_LIVE_STREAM_STATUS"
    case ypc = "HEARTBEAT_CHECK_TYPE_YPC"
    case unplugged = "HEARTBEAT_CHECK_TYPE_UNPLUGGED"
}

struct HeartbeatRequestParams: Sendable {
    var heartbeatChecks: [HeartbeatCheckType]?

    init(heartbeatChecks: [HeartbeatCheckType]? = nil) {
        self.heartbeatChecks = heartbeatChecks
    }
}

struct HeartbeatRequest: Sendable {
    var heartbeatRequestParams: HeartbeatRequestParams?
    var heartbeatServerData: String?
    var heartbeatToken: String?
    var videoId: String?

    init(
        heartbeatRequestParams: HeartbeatRequestParams? = nil,
        heartbeatServerData: String? = nil,
        heartbeatToken: String? = nil,
        videoId: String? = nil
    ) {
        self.heartbeatRequestParams = heartbeatRequestParams
        self.heartbeatServerData = heartbeatServerData
        self.heartbeatToken = heartbeatToken
        self.videoId = videoId
    }
}

enum PlayabilityStatus: String, Sendable {
    case ok = "OK"
    case error = "ERROR"
    case unplayable = "UNPLAYABLE"
    case loginRequired = "LOGIN_REQUIRED"
    case contentCheckRequired = "CONTENT_CHECK_REQUIRED"
    case ageCheckRequired = "AGE_CHECK_REQUIRED"
    case liveStreamOffline = "LIVE_STREAM_OFFLINE"
    case fullscreenOnly = "FULLSCREEN_ONLY"
    case glPlaybackRequired = "GL_PLAYBACK_REQUIRED"
    case ageVerificationRequired = "AGE_VERIFICATION_REQUIRED"
}

struct HeartbeatResponse: Sendable {
    var status: PlayabilityStatus?
    var broadcastId: String?
    var pollDelayMs: String?
    var displayEndscreen: Bool?
    var offlineSlatePresent: Bool?
    var offlineSlateButtonsPresent: Bool?
    var heartbeatServerData: String?

    init(
        status: PlayabilityStatus? = nil,
        broadcastId: String? = nil,
        pollDelayMs: String? = nil,
        displayEndscreen: Bool? = nil,
        offlineSlatePresent: Bool? = nil,
        offlineSlateButtonsPresent: Bool? = nil,
        heartbeatServerData: String? = nil
    ) {
        self.status = status
        self.broadcastId = broadcastId
        self.pollDelayMs = pollDelayMs
        self.displayEndscreen = displayEndscreen
        self.offlineSlatePresent = offlineSlatePresent
        self.offlineSlateButtonsPresent = offlineSlateButtonsPresent
        self.heartbeatServerData = heartbeatServerData
    }
}

struct HeartbeatParams: Sendable {
    var heartbeatServerData: String?
    var heartbeatToken: String?
    var intervalMilliseconds: String?

    init(heartbeatServerData: String? = nil, heartbeatToken: String? = nil, intervalMilliseconds: String? = nil) {
        self.heartbeatServerData = heartbeatServerData
        self.heartbeatToken = heartbeatToken
        self.intervalMilliseconds = intervalMilliseconds
    }
}

struct ReloadResponse: Sendable {
    var serverAbrStreamingUrl: String
    var videoPlaybackUstreamerConfig: String

    init(serverAbrStreamingUrl: String, videoPlaybackUstreamerConfig: String) {
        self.serverAbrStreamingUrl = serverAbrStreamingUrl
        self.videoPlaybackUstreamerConfig = videoPlaybackUstreamerConfig
    }
}

enum FormatSelector: Sendable {
    case itag(Int)
    case format(SabrFormat)
    case selector(@Sendable ([SabrFormat]) -> SabrFormat?)
}

struct SabrPlaybackOptions: Sendable {
    var videoFormat: FormatSelector?
    var audioFormat: FormatSelector?
    var videoPreferences: VideoFormatPreferences?
    var audioPreferences: AudioFormatPreferences?
    var maxRetries: Int?
    var stallDetectionMs: Int?
    var enabledTrackTypes: EnabledTrackTypes?
    var startTimeMs: Int?
    var isPostLiveDvr: Bool
    var snapshot: SabrSnapshot?

    init(
        videoFormat: FormatSelector? = nil,
        audioFormat: FormatSelector? = nil,
        videoPreferences: VideoFormatPreferences? = nil,
        audioPreferences: AudioFormatPreferences? = nil,
        enabledTrackTypes: EnabledTrackTypes? = nil,
        startTimeMs: Int? = nil,
        isPostLiveDvr: Bool,
        maxRetries: Int? = nil,
        stallDetectionMs: Int? = nil,
        snapshot: SabrSnapshot? = nil
    ) {
        self.videoFormat = videoFormat
        self.audioFormat = audioFormat
        self.videoPreferences = videoPreferences
        self.audioPreferences = audioPreferences
        self.maxRetries = maxRetries
        self.stallDetectionMs = stallDetectionMs
        self.enabledTrackTypes = enabledTrackTypes
        self.startTimeMs = startTimeMs
        self.isPostLiveDvr = isPostLiveDvr
        self.snapshot = snapshot
    }
}

enum MediaContainer: String, Sendable {
    case webm
    case mp4
}

enum PreferredVideoCodec: String, Sendable {
    case h264
    case vp9
    case av1
}

enum PreferredAudioCodec: String, Sendable {
    case aac
    case opus
}

enum AudioQualityLabel: String, Sendable {
    case ultralow = "AUDIO_QUALITY_ULTRALOW"
    case low = "AUDIO_QUALITY_LOW"
    case medium = "AUDIO_QUALITY_MEDIUM"
    case high = "AUDIO_QUALITY_HIGH"
}

struct VideoFormatPreferences: Sendable {
    var quality: String?
    var container: MediaContainer?
    var preferredVideoCodec: PreferredVideoCodec?
    var superResolution: Bool?
    var hdr: Bool?

    init(
        quality: String? = nil,
        container: MediaContainer? = nil,
        preferredVideoCodec: PreferredVideoCodec? = nil,
        superResolution: Bool? = nil,
        hdr: Bool? = nil
    ) {
        self.quality = quality
        self.container = container
        self.preferredVideoCodec = preferredVideoCodec
        self.superResolution = superResolution
        self.hdr = hdr
    }
}

struct AudioFormatPreferences: Sendable {
    var quality: AudioQualityLabel?
    var language: String?
    var container: MediaContainer?
    var preferredAudioCodec: PreferredAudioCodec?
    var voiceBoost: Bool?
    var dynamicRangeCompression: Bool?

    init(
        quality: AudioQualityLabel? = nil,
        language: String? = nil,
        container: MediaContainer? = nil,
        preferredAudioCodec: PreferredAudioCodec? = nil,
        voiceBoost: Bool? = nil,
        dynamicRangeCompression: Bool? = nil
    ) {
        self.quality = quality
        self.language = language
        self.container = container
        self.preferredAudioCodec = preferredAudioCodec
        self.voiceBoost = voiceBoost
        self.dynamicRangeCompression = dynamicRangeCompression
    }
}

struct AbortOptions: Sendable {
    var snapshot: Bool?

    init(snapshot: Bool? = nil) {
        self.snapshot = snapshot
    }
}

struct TrackOutput: Sendable {
    var stream: ReadableStream<Data>
    var controller: ReadableStream<Data>.Controller

    init(stream: ReadableStream<Data>, controller: ReadableStream<Data>.Controller) {
        self.stream = stream
        self.controller = controller
    }
}

struct SabrSnapshot: Sendable {
    var playerTimeMs: Int
    var tracks: [TrackState]

    init(playerTimeMs: Int, tracks: [TrackState]) {
        self.playerTimeMs = playerTimeMs
        self.tracks = tracks
    }
}

struct TrackState: Sendable, CreateFormatKeyInput {
    var formatId: FormatId?
    var mimeType: String?
    var endSegmentNum: Int?
    var endTimeTicks: Int?
    var endTimescale: Int?
    var targetDurationSec: Double?
    var bufferedRangeSummary: BufferedRangeSummary?
    var trackedSegments: [(Int, CompletedSegment)]?

    init(
        formatId: FormatId? = nil,
        mimeType: String? = nil,
        endSegmentNum: Int? = nil,
        endTimeTicks: Int? = nil,
        endTimescale: Int? = nil,
        targetDurationSec: Double? = nil,
        bufferedRangeSummary: BufferedRangeSummary? = nil,
        trackedSegments: [(Int, CompletedSegment)]? = nil
    ) {
        self.formatId = formatId
        self.mimeType = mimeType
        self.endSegmentNum = endSegmentNum
        self.endTimeTicks = endTimeTicks
        self.endTimescale = endTimescale
        self.targetDurationSec = targetDurationSec
        self.bufferedRangeSummary = bufferedRangeSummary
        self.trackedSegments = trackedSegments
    }

    var formatKeyCandidates: [(itag: Int?, xtags: String?)] {
        guard let formatId else { return [] }
        return [(formatId.hasItag ? Int(formatId.itag) : nil, formatId.hasXtags ? formatId.xtags : nil)]
    }
}

struct CompletedSegment: Sendable {
    var segmentNumber: Int
    var durationMs: Double
    var startTimeMs: Double
    var endTimeMs: Double
    var mediaHeader: MediaHeader

    init(segmentNumber: Int, durationMs: Double, startTimeMs: Double, endTimeMs: Double, mediaHeader: MediaHeader) {
        self.segmentNumber = segmentNumber
        self.durationMs = durationMs
        self.startTimeMs = startTimeMs
        self.endTimeMs = endTimeMs
        self.mediaHeader = mediaHeader
    }
}

struct SegmentInfo: Sendable {
    var formatKey: String
    var segmentNumber: Int
    var mediaHeader: MediaHeader
    var startTimeMs: Double
    var durationMs: Double

    init(formatKey: String, segmentNumber: Int, mediaHeader: MediaHeader, startTimeMs: Double, durationMs: Double) {
        self.formatKey = formatKey
        self.segmentNumber = segmentNumber
        self.mediaHeader = mediaHeader
        self.startTimeMs = startTimeMs
        self.durationMs = durationMs
    }
}

struct BufferedRangeSummary: Sendable {
    var startTimeMs: Double
    var durationMs: Double
    var startSegmentIndex: Int
    var endSegmentIndex: Int

    init(startTimeMs: Double, durationMs: Double, startSegmentIndex: Int, endSegmentIndex: Int) {
        self.startTimeMs = startTimeMs
        self.durationMs = durationMs
        self.startSegmentIndex = startSegmentIndex
        self.endSegmentIndex = endSegmentIndex
    }
}
