import Foundation

struct SabrRequestStreamInfo {
    var playbackCookie: PlaybackCookie?
    var nextRequestPolicy: NextRequestPolicy?
    var formatInitMetadata: [FormatInitializationMetadata]?
    var streamProtectionStatus: StreamProtectionStatus?
    var reloadPlaybackContext: ReloadPlaybackContext?
    var sabrContextSendingPolicy: SabrContextSendingPolicy?
    var sabrContextUpdate: SabrContextUpdate?
    var snackbarMessage: SnackbarMessage?
    var mediaHeader: MediaHeader?
    var redirect: SabrRedirect?

    init() {}
}

struct SabrRequestError {
    var sabrError: SabrError?

    init(sabrError: SabrError? = nil) {
        self.sabrError = sabrError
    }
}

final class SabrRequestMetadata {
    var byteRange: ByteRange?
    var format: SabrFormat?
    var isInit: Bool?
    var isUMP: Bool?
    var isSABR: Bool?
    var streamInfo: SabrRequestStreamInfo?
    var error: SabrRequestError?
    var timestamp: Double

    init(
        byteRange: ByteRange? = nil,
        format: SabrFormat? = nil,
        isInit: Bool? = nil,
        isUMP: Bool? = nil,
        isSABR: Bool? = nil,
        streamInfo: SabrRequestStreamInfo? = nil,
        error: SabrRequestError? = nil,
        timestamp: Double
    ) {
        self.byteRange = byteRange
        self.format = format
        self.isInit = isInit
        self.isUMP = isUMP
        self.isSABR = isSABR
        self.streamInfo = streamInfo
        self.error = error
        self.timestamp = timestamp
    }
}

typealias OnSnackbarMessageCb = (SnackbarMessage) -> Void
typealias OnReloadPlayerResponseCb = (ReloadPlaybackContext) async throws -> Void
typealias OnMintPoTokenCallback = () async throws -> String

struct SabrOptions {
    var enableCaching: Bool?
    var enableVerboseRequestLogging: Bool?
    var maxCacheSizeMB: Int?
    var maxCacheAgeSeconds: Int?
    var playerAdapter: SabrPlayerAdapter?
    var clientInfo: ClientInfo?

    init(
        enableCaching: Bool? = nil,
        enableVerboseRequestLogging: Bool? = nil,
        maxCacheSizeMB: Int? = nil,
        maxCacheAgeSeconds: Int? = nil,
        playerAdapter: SabrPlayerAdapter? = nil,
        clientInfo: ClientInfo? = nil
    ) {
        self.enableCaching = enableCaching
        self.enableVerboseRequestLogging = enableVerboseRequestLogging
        self.maxCacheSizeMB = maxCacheSizeMB
        self.maxCacheAgeSeconds = maxCacheAgeSeconds
        self.playerAdapter = playerAdapter
        self.clientInfo = clientInfo
    }
}

struct PlayerHttpResponse {
    var url: String
    var method: String
    var headers: [String: String]
    var data: Data?
    var makeRequest: (String, [String: String]) async throws -> PlayerHttpResponse

    init(
        url: String,
        method: String,
        headers: [String: String],
        data: Data? = nil,
        makeRequest: @escaping (String, [String: String]) async throws -> PlayerHttpResponse
    ) {
        self.url = url
        self.method = method
        self.headers = headers
        self.data = data
        self.makeRequest = makeRequest
    }
}

struct PlayerHttpRequest {
    var url: String
    var method: String
    var headers: [String: String]
    var segment: RequestSegment
    var body: Data?

    init(url: String, method: String, headers: [String: String], segment: RequestSegment, body: Data? = nil) {
        self.url = url
        self.method = method
        self.headers = headers
        self.segment = segment
        self.body = body
    }
}

struct RequestSegment {
    var getStartTime: () -> Double?
    var isInit: () -> Bool

    init(getStartTime: @escaping () -> Double?, isInit: @escaping () -> Bool) {
        self.getStartTime = getStartTime
        self.isInit = isInit
    }
}

typealias RequestFilter = (PlayerHttpRequest) async throws -> PlayerHttpRequest?
typealias ResponseFilter = (PlayerHttpResponse) async throws -> PlayerHttpResponse?

struct ActiveTrackFormats {
    var audioFormat: SabrFormat?
    var videoFormat: SabrFormat?

    init(audioFormat: SabrFormat? = nil, videoFormat: SabrFormat? = nil) {
        self.audioFormat = audioFormat
        self.videoFormat = videoFormat
    }
}

protocol SabrPlayerAdapter: AnyObject {
    func initialize(
        _ player: Any,
        _ requestMetadataManager: RequestMetadataManager,
        _ cache: CacheManager?
    )
    func getPlayerTime() -> Double
    func getPlaybackRate() -> Double
    func getBandwidthEstimate() -> Double
    func getActiveTrackFormats(_ activeFormat: SabrFormat, _ sabrFormats: [SabrFormat]) -> ActiveTrackFormats
    func registerRequestInterceptor(_ interceptor: @escaping RequestFilter)
    func registerResponseInterceptor(_ interceptor: @escaping ResponseFilter)
    func dispose()
}
