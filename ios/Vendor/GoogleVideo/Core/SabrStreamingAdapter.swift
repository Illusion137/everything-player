import Foundation

struct SabrAdapterError: Error, LocalizedError {
    let message: String
    let code: String?

    init(_ message: String, _ code: String? = nil) {
        self.message = "[SabrStreamingAdapter] \(message)"
        self.code = code
    }

    var errorDescription: String? {
        return message
    }
}

private struct LastSegmentMetadata {
    var formatId: FormatId
    var startSequenceNumber: Int
    var endSequenceNumber: Int
    var startTimeMs: Int64
    var durationMs: Int64
    var timescale: Int
}

private struct InitializedFormat {
    var lastSegmentMetadata: LastSegmentMetadata?
}

private let TAG = "SabrStreamingAdapter"

enum SABR_CONSTANTS {
    static let PROTOCOL = "sabr:"
    static let KEY_PARAM = "key"
    static let DEFAULT_ENABLE_CACHING = true
    static let DEFAULT_ENABLE_VERBOSE_REQUEST_LOGGING = false
    static let DEFAULT_MAX_CACHE_SIZE_MB = 3
    static let DEFAULT_MAX_CACHE_AGE_SECONDS = 300
}

private let BASIC_UMP_REQUEST_BODY = Data([120, 0])

final class SabrStreamingAdapter: @unchecked Sendable {
    private let playerAdapter: SabrPlayerAdapter
    private let requestMetadataManager: RequestMetadataManager
    private var initializedFormats: [String: InitializedFormat] = [:]
    private let logger = Logger.getInstance()

    private var options: SabrOptions!
    private var ustreamerConfig: String?
    private var serverAbrStreamingUrl: String?

    private var sabrFormats: [SabrFormat] = []
    private var sabrContexts = OrderedMap<Int, SabrContextUpdate>()
    private var activeSabrContextTypes = Set<Int>()
    private var lastPlaybackCookie: PlaybackCookie?
    private var lastPlayerTimeSecs = 0.0
    private var cacheManager: CacheManager?
    private var requestNumber = 0

    private var activeDelayPromise: Task<Void, Never>?
    private var onReloadPlayerResponseCallback: OnReloadPlayerResponseCb?
    private var onSnackbarMessageCallback: OnSnackbarMessageCb?
    private var onMintPoTokenCallback: OnMintPoTokenCallback?

    var isDisposed = false

    func onSnackbarMessage(_ cb: @escaping OnSnackbarMessageCb) {
        onSnackbarMessageCallback = cb
    }

    func onReloadPlayerResponse(_ cb: @escaping OnReloadPlayerResponseCb) {
        onReloadPlayerResponseCallback = cb
    }

    func onMintPoToken(_ cb: @escaping OnMintPoTokenCallback) {
        onMintPoTokenCallback = cb
    }

    init(_ options: SabrOptions) throws {
        var merged = options
        merged.enableCaching = options.enableCaching ?? SABR_CONSTANTS.DEFAULT_ENABLE_CACHING
        merged.enableVerboseRequestLogging = options.enableVerboseRequestLogging ?? SABR_CONSTANTS.DEFAULT_ENABLE_VERBOSE_REQUEST_LOGGING
        merged.maxCacheSizeMB = options.maxCacheSizeMB ?? SABR_CONSTANTS.DEFAULT_MAX_CACHE_SIZE_MB
        merged.maxCacheAgeSeconds = options.maxCacheAgeSeconds ?? SABR_CONSTANTS.DEFAULT_MAX_CACHE_AGE_SECONDS
        self.options = merged

        if let playerAdapter = options.playerAdapter {
            self.playerAdapter = playerAdapter
        } else {
            throw SabrAdapterError("A player adapter is required.")
        }

        if merged.enableCaching == true {
            self.cacheManager = CacheManager(
                merged.maxCacheSizeMB!,
                merged.maxCacheAgeSeconds!
            )
        }

        self.requestMetadataManager = RequestMetadataManager()
    }

    func attach(_ player: Any) throws {
        try checkDisposed()
        playerAdapter.initialize(player, requestMetadataManager, cacheManager)
        setupInterceptors()
    }

    func setStreamingURL(_ url: String? = nil) throws {
        try checkDisposed()
        serverAbrStreamingUrl = url
    }

    func setUstreamerConfig(_ ustreamerConfig: String? = nil) throws {
        try checkDisposed()
        self.ustreamerConfig = ustreamerConfig
    }

    func setServerAbrFormats(_ sabrFormats: [SabrFormat]) throws {
        try checkDisposed()
        self.sabrFormats = sabrFormats
    }

    func getCacheManager() -> CacheManager? {
        return cacheManager
    }

    private func setupInterceptors() {
        playerAdapter.registerRequestInterceptor { [unowned self] request in
            try await self.handleRequest(request)
        }
        playerAdapter.registerResponseInterceptor { [unowned self] response in
            try await self.handleResponse(response)
        }
    }

    private func handleRequest(_ originalRequest: PlayerHttpRequest) async throws -> PlayerHttpRequest {
        var request = originalRequest
        guard var originalUri = URLComponents(string: request.url) else {
            throw SabrAdapterError("Invalid request URL: \(request.url)")
        }

        if "\(originalUri.scheme ?? ""):" == SABR_CONSTANTS.PROTOCOL {
            if let activeDelayPromise {
                await activeDelayPromise.value
            }

            guard let serverAbrStreamingUrl, !serverAbrStreamingUrl.isEmpty else {
                throw SabrAdapterError("Server ABR URL not set.")
            }

            if sabrFormats.isEmpty {
                throw SabrAdapterError("No SABR formats available.")
            }

            let requestNumber = String(self.requestNumber)
            self.requestNumber += 1

            guard let sabrUrl = URL(string: serverAbrStreamingUrl) else {
                throw SabrAdapterError("Invalid server ABR URL: \(serverAbrStreamingUrl)")
            }
            request.url = sabrUrl.settingSearchParam("rn", requestNumber).absoluteString

            let keyParam = originalUri.url?.searchParam(SABR_CONSTANTS.KEY_PARAM) ?? ""
            let currentFormat = try sabrFormats.first { try createFormatKey($0) == keyParam }

            guard let currentFormat else {
                throw SabrAdapterError("Could not determine current format from URL: \(request.url)")
            }

            if playerAdapter.getPlayerTime() < lastPlayerTimeSecs {
                initializedFormats.removeAll()
            }

            let activeFormats = playerAdapter.getActiveTrackFormats(currentFormat, sabrFormats)
            var videoPlaybackAbrRequest = try await createVideoPlaybackAbrRequest(request, currentFormat, activeFormats)

            if let height = currentFormat.height, height != 0 {
                videoPlaybackAbrRequest.clientAbrState.stickyResolution = Int32(height)
                videoPlaybackAbrRequest.clientAbrState.lastManualSelectedResolution = Int32(height)
            }

            let formatToDiscard = try addBufferingInfoToAbrRequest(&videoPlaybackAbrRequest, currentFormat, activeFormats)

            if let formatToDiscard {
                videoPlaybackAbrRequest.initializationFormatIds.append(FormatId(formatToDiscard))
            }

            if !request.segment.isInit() {
                videoPlaybackAbrRequest.initializationFormatIds.append(FormatId(currentFormat))
            }

            if options.enableVerboseRequestLogging == true {
                logger.debug(TAG, "Created VideoPlaybackAbrRequest (\(requestNumber)):", videoPlaybackAbrRequest)
            }

            request.body = try videoPlaybackAbrRequest.serializedData()

            requestMetadataManager.metadataMap[requestNumber] = SabrRequestMetadata(
                byteRange: parseRangeHeader(request.headers["Range"]),
                format: currentFormat,
                isInit: request.segment.isInit(),
                isUMP: true,
                isSABR: true,
                timestamp: nowMs()
            )
        } else {
            let webPoToken = try await onMintPoTokenCallback?()
            let rangeValue = request.headers["Range"].flatMap { $0.components(separatedBy: "=").dropFirst().first }

            if originalUri.path.contains("videoplayback/expire") || originalUri.path.contains("source/yt_live_broadcast") {
                originalUri.path += "/ump/1"
                originalUri.path += "/srfvp/1"
                originalUri.path += "/alr/yes"
                if let webPoToken, !webPoToken.isEmpty {
                    originalUri.path += "/pot/\(webPoToken)"
                }
                if let rangeValue {
                    originalUri.path += "/range/\(rangeValue)"
                }
            } else {
                var url = originalUri.url!
                url = url.settingSearchParam("ump", "1")
                url = url.settingSearchParam("srfvp", "1")
                url = url.settingSearchParam("alr", "yes")
                if let webPoToken, !webPoToken.isEmpty {
                    url = url.settingSearchParam("pot", webPoToken)
                }
                if let rangeValue {
                    url = url.settingSearchParam("range", rangeValue)
                }
                originalUri = URLComponents(url: url, resolvingAgainstBaseURL: false)!
            }

            let requestNumber = String(self.requestNumber)
            self.requestNumber += 1
            request.url = originalUri.url!.settingSearchParam("rn", requestNumber).absoluteString
            request.body = BASIC_UMP_REQUEST_BODY

            requestMetadataManager.metadataMap[requestNumber] = SabrRequestMetadata(
                isUMP: true,
                isSABR: false,
                timestamp: nowMs()
            )
        }

        request.method = "POST"

        request.headers.removeValue(forKey: "Range")

        return request
    }

    private func createVideoPlaybackAbrRequest(
        _ request: PlayerHttpRequest,
        _ currentFormat: SabrFormat,
        _ activeFormats: ActiveTrackFormats
    ) async throws -> VideoPlaybackAbrRequest {
        guard let ustreamerConfig, !ustreamerConfig.isEmpty else {
            throw SabrAdapterError("Ustreamer config not set")
        }

        var streamerContext = StreamerContext()
        if let onMintPoTokenCallback {
            streamerContext.poToken = base64ToU8(try await onMintPoTokenCallback())
        }
        if let lastPlaybackCookie {
            streamerContext.playbackCookie = try lastPlaybackCookie.serializedData()
        }
        if let clientInfo = options.clientInfo {
            streamerContext.clientInfo = clientInfo
        }

        for ctxUpdate in sabrContexts.values {
            if activeSabrContextTypes.contains(Int(ctxUpdate.type)) {
                var sabrContext = SabrContext()
                sabrContext.type = ctxUpdate.type
                sabrContext.value = ctxUpdate.value
                streamerContext.sabrContexts.append(sabrContext)
            } else {
                streamerContext.unsentSabrContexts.append(ctxUpdate.type)
            }
        }

        lastPlayerTimeSecs = playerAdapter.getPlayerTime()

        var clientAbrState = ClientAbrState()
        clientAbrState.playbackRate = Float(playerAdapter.getPlaybackRate())
        clientAbrState.playerTimeMs = Int64(((request.segment.getStartTime() ?? lastPlayerTimeSecs) * 1000).rounded())
        clientAbrState.clientViewportIsFlexible = false
        clientAbrState.bandwidthEstimate = Int64(playerAdapter.getBandwidthEstimate().rounded())
        clientAbrState.drcEnabled = currentFormat.isDrc ?? false
        clientAbrState.enabledTrackTypesBitfield = Int32((currentFormat.width ?? 0) != 0 ? EnabledTrackTypes.videoOnly.rawValue : EnabledTrackTypes.audioOnly.rawValue)
        if let audioTrackId = currentFormat.audioTrackId { clientAbrState.audioTrackID = audioTrackId }

        var videoPlaybackAbrRequest = VideoPlaybackAbrRequest()
        videoPlaybackAbrRequest.clientAbrState = clientAbrState
        videoPlaybackAbrRequest.bufferedRanges = []
        videoPlaybackAbrRequest.initializationFormatIds = []
        videoPlaybackAbrRequest.selectedAudioFormatIds = [activeFormats.audioFormat.map { FormatId($0) } ?? FormatId()]
        videoPlaybackAbrRequest.selectedVideoFormatIds = [activeFormats.videoFormat.map { FormatId($0) } ?? FormatId()]
        videoPlaybackAbrRequest.selectedCaptionFormatIds = []
        videoPlaybackAbrRequest.ssapPlaybackInfos = []
        videoPlaybackAbrRequest.videoPlaybackUstreamerConfig = base64ToU8(ustreamerConfig)
        videoPlaybackAbrRequest.streamerContext = streamerContext
        videoPlaybackAbrRequest.field1000 = []

        return videoPlaybackAbrRequest
    }

    private func addBufferingInfoToAbrRequest(
        _ videoPlaybackAbrRequest: inout VideoPlaybackAbrRequest,
        _ currentFormat: SabrFormat,
        _ activeFormats: ActiveTrackFormats
    ) throws -> SabrFormat? {
        var formatToDiscard: SabrFormat?

        let currentFormatKey = try createFormatKey(currentFormat)

        for activeFormat in [activeFormats.audioFormat, activeFormats.videoFormat] {
            guard let activeFormat else { continue }

            let activeFormatKey = try createFormatKey(activeFormat)
            let shouldDiscard = currentFormatKey != activeFormatKey
            let initializedFormat = initializedFormats[activeFormatKey]

            let bufferedRange = shouldDiscard
                ? createFullBufferRange(activeFormat)
                : createPartialBufferRange(initializedFormat)

            if let bufferedRange {
                videoPlaybackAbrRequest.bufferedRanges.append(bufferedRange)

                if shouldDiscard {
                    formatToDiscard = activeFormat
                }
            }
        }

        return formatToDiscard
    }

    private func createFullBufferRange(_ format: SabrFormat) -> BufferedRange {
        var range = BufferedRange()
        range.formatID = FormatId(format)
        range.durationMs = Int64(MAX_INT32_VALUE)!
        range.startTimeMs = 0
        range.startSegmentIndex = Int32(MAX_INT32_VALUE)!
        range.endSegmentIndex = Int32(MAX_INT32_VALUE)!
        range.timeRange.durationTicks = Int64(MAX_INT32_VALUE)!
        range.timeRange.startTicks = 0
        range.timeRange.timescale = 1000
        return range
    }

    private func createPartialBufferRange(_ initializedFormat: InitializedFormat?) -> BufferedRange? {
        guard let metadata = initializedFormat?.lastSegmentMetadata else { return nil }

        var range = BufferedRange()
        range.formatID = metadata.formatId
        range.startSegmentIndex = Int32(metadata.startSequenceNumber)
        range.durationMs = metadata.durationMs
        range.startTimeMs = 0
        range.endSegmentIndex = Int32(metadata.endSequenceNumber)
        range.timeRange.timescale = Int32(metadata.timescale)
        range.timeRange.startTicks = 0
        range.timeRange.durationTicks = metadata.durationMs
        return range
    }

    private func handleResponse(_ response: PlayerHttpResponse) async throws -> PlayerHttpResponse? {
        guard let requestMetadata = requestMetadataManager.getRequestMetadata(response.url, true) else { return response }

        guard let streamInfo = requestMetadata.streamInfo else { return response }
        let format = requestMetadata.format
        let byteRange = requestMetadata.byteRange
        let isSABR = requestMetadata.isSABR

        let retry = { () async throws -> PlayerHttpResponse in
            let formatType = (format?.width ?? 0) != 0 ? "video" : "audio"
            let formatKey = try createFormatKey(format!)
            let url = "\(SABR_CONSTANTS.PROTOCOL)//\(formatType)?\(SABR_CONSTANTS.KEY_PARAM)=\(formatKey)"
            return try await self.makeFollowupRequest(response, url, isSABR, byteRange)
        }

        if let snackbarMessage = streamInfo.snackbarMessage {
            logger.debug(TAG, "Received snackbar message:", snackbarMessage)
            onSnackbarMessageCallback?(snackbarMessage)
        }

        if let redirect = streamInfo.redirect, !redirect.url.isEmpty {
            var redirectUrl = redirect.url

            logger.info(TAG, "Redirecting to \(redirectUrl)")

            if isSABR == true {
                serverAbrStreamingUrl = redirect.url
                let formatType = (format?.width ?? 0) != 0 ? "video" : "audio"
                let formatKey = try createFormatKey(format!)
                redirectUrl = "\(SABR_CONSTANTS.PROTOCOL)//\(formatType)?\(SABR_CONSTANTS.KEY_PARAM)=\(formatKey)"
            }

            if (response.data?.count ?? 0) == 0 {
                return try await makeFollowupRequest(response, redirectUrl, isSABR, byteRange)
            }
        }

        if let nextRequestPolicy = streamInfo.nextRequestPolicy {
            lastPlaybackCookie = nextRequestPolicy.playbackCookie
            let delayMs = Int(nextRequestPolicy.backoffTimeMs)

            if delayMs > 0 && activeDelayPromise == nil {
                logger.info(TAG, "Delaying next requests by \(Double(delayMs) / 1000) seconds.")
                activeDelayPromise = Task {
                    await wait(delayMs)
                    self.logger.info(TAG, "Delay completed, resuming requests.")
                    self.activeDelayPromise = nil
                }
            }
        }

        if let sabrContextSendingPolicy = streamInfo.sabrContextSendingPolicy {
            for startPolicy in sabrContextSendingPolicy.startPolicy.map(Int.init) {
                if !activeSabrContextTypes.contains(startPolicy) {
                    activeSabrContextTypes.insert(startPolicy)
                    logger.debug(TAG, "Activated SABR context for type \(startPolicy)")
                }
            }

            for stopPolicy in sabrContextSendingPolicy.stopPolicy.map(Int.init) {
                if activeSabrContextTypes.contains(stopPolicy) {
                    activeSabrContextTypes.remove(stopPolicy)
                    logger.debug(TAG, "Deactivated SABR context for type \(stopPolicy)")
                }
            }

            for discardPolicy in sabrContextSendingPolicy.discardPolicy.map(Int.init) {
                if sabrContexts.has(discardPolicy) {
                    sabrContexts.removeValue(forKey: discardPolicy)
                    logger.debug(TAG, "Discarded SABR context for type \(discardPolicy)")
                }
            }
        }

        if let sabrContextUpdate = streamInfo.sabrContextUpdate, sabrContextUpdate.hasType, sabrContextUpdate.hasValue, !sabrContextUpdate.value.isEmpty {
            let contextType = Int(sabrContextUpdate.type)

            if !sabrContexts.has(contextType) || sabrContextUpdate.writePolicy == .overwrite {
                logger.debug(TAG, "Received SABR context update (type: \(sabrContextUpdate.type), writePolicy: \(sabrContextUpdate.writePolicy) sendByDefault: \(sabrContextUpdate.sendByDefault))")
                sabrContexts[contextType] = sabrContextUpdate
            }

            if sabrContextUpdate.sendByDefault {
                activeSabrContextTypes.insert(contextType)
            }

            if (response.data?.count ?? 0) == 0 {
                return try await retry()
            }
        }

        if let reloadPlaybackContext = streamInfo.reloadPlaybackContext, let onReloadPlayerResponseCallback {
            logger.info(TAG, "Server requested player reload with new parameters:", reloadPlaybackContext)
            try await onReloadPlayerResponseCallback(reloadPlaybackContext)
            return try await retry()
        }

        if let mediaHeader = streamInfo.mediaHeader {
            let formatKey = try createFormatKey(mediaHeader)

            if mediaHeader.isInitializationSegment {
                return nil
            }

            var initializedFormat = initializedFormats[formatKey] ?? InitializedFormat()

            let segmentNum = Int(mediaHeader.segmentNum)

            initializedFormat.lastSegmentMetadata = LastSegmentMetadata(
                formatId: mediaHeader.formatID,
                startSequenceNumber: segmentNum != 0 ? segmentNum : 1,
                endSequenceNumber: segmentNum != 0 ? segmentNum : 1,
                startTimeMs: mediaHeader.startMs,
                durationMs: mediaHeader.durationMs,
                timescale: mediaHeader.timeRange.timescale != 0 ? Int(mediaHeader.timeRange.timescale) : 1000
            )

            initializedFormats[formatKey] = initializedFormat
        }

        return response
    }

    private func makeFollowupRequest(
        _ originalResponse: PlayerHttpResponse,
        _ url: String,
        _ isSABR: Bool? = nil,
        _ byteRange: ByteRange? = nil
    ) async throws -> PlayerHttpResponse {
        if let activeDelayPromise {
            await activeDelayPromise.value
        }

        var headers: [String: String] = [:]

        if isSABR == true, let byteRange {
            headers["Range"] = "bytes=\(byteRange.start)-\(byteRange.end)"
        }

        var response = originalResponse
        let redirectResponse = try await originalResponse.makeRequest(url, headers)
        response.url = redirectResponse.url
        response.method = redirectResponse.method
        response.headers = redirectResponse.headers
        response.data = redirectResponse.data

        return response
    }

    private func checkDisposed() throws {
        if isDisposed {
            throw SabrAdapterError("Adapter has been disposed.")
        }
    }

    func dispose() {
        if isDisposed { return }

        cacheManager?.dispose()
        cacheManager = nil

        initializedFormats.removeAll()
        requestMetadataManager.metadataMap.removeAll()
        sabrContexts.removeAll()
        activeSabrContextTypes.removeAll()

        lastPlaybackCookie = nil
        lastPlayerTimeSecs = 0
        sabrFormats = []
        serverAbrStreamingUrl = nil
        ustreamerConfig = nil
        activeDelayPromise = nil
        playerAdapter.dispose()
        requestNumber = 0

        onReloadPlayerResponseCallback = nil
        onSnackbarMessageCallback = nil
        onMintPoTokenCallback = nil

        options = nil
        isDisposed = true

        logger.debug(TAG, "Disposed")
    }
}
