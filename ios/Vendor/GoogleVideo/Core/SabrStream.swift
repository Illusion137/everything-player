import Foundation

private let TAG = "SabrStream"

private let MAX_STALLS = 3
private let DEFAULT_MAX_RETRIES = 10
private let DEFAULT_STALL_DETECTION_MS = 30_000
private let REQUEST_TIMEOUT_MS = 30_000
private let INITIAL_RETRY_BACKOFF_MS = 500
private let MAX_RETRY_BACKOFF_MS = 5_000
private let OFFLINE_GRACE_PERIOD_MS: Double = 15_000
private let DEFAULT_HEARTBEAT_INTERVAL_MS = 10_000
private let LIVE_EDGE_SENTINEL_MS = 9_007_199_254_740_991

private let DEFAULT_VIDEO_HWM = 1024 * 1024 * 16
private let DEFAULT_AUDIO_HWM = 1024 * 1024 * 3

private let BANDWIDTH_EMA_PREVIOUS_WEIGHT = 0.8
private let BANDWIDTH_EMA_CURRENT_WEIGHT = 0.2
private let MIN_FETCH_DURATION_FOR_BW_ESTIMATE_MS = 50.0


private enum SeekOrigin: String {
    case server
    case client
}

private struct Runtime {
    var playerTimeMs = 0
    var requestNumber = 0
    var bandwidthEstimateBps = 0.0
    var lastHeartbeatTimeMs = 0.0
    var playbackSessionStartMs: Double?
    var poTokenGenerationId = 0
    var spsRejectCount = 0
}

private struct Lifecycle {
    var aborted = false
    var errored = false
    var busy = false
}

private struct ProgressTracker {
    var lastProgressTime = nowMs()
    var lastBufferedTimeMs = 0.0
    var stallCount = 0
}

final class SabrStream: EventEmitterLike, @unchecked Sendable {
    private let logger = Logger.getInstance()
    private let formats: [SabrFormat]
    private let segmentBuffer: SabrSegmentBuffer
    private let stateLock = NSRecursiveLock()

    private let fetchFunction: FetchFunction
    private var abortController: AbortController?
    private var requestTimeoutTask: Task<Void, Never>?

    private var serverAbrStreamingUrl: URL?
    private var videoPlaybackUstreamerConfig: String
    private let clientInfo: ClientInfo
    private var proofOfOriginToken: Data?
    private var heartbeatParams: HeartbeatParams

    private var nextRequestPolicy: NextRequestPolicy?
    private var ssapPlaybackInfos = OrderedMap<String, SsapPlaybackInfo>()
    private var sabrContextUpdates = OrderedMap<Int, SabrContextUpdate>()
    private var activeSabrContextTypes = Set<Int>()
    private let trackCollection: TrackCollection

    private let videoId: String?
    private var broadcastId: String?

    private var idleResolvers: [() -> Void] = []
    private var drainResolver: (() -> Void)?

    private var shouldStop = false
    private var seekEpoch = 0
    private var lastSeekWallMs: Double?
    private var resumeResolver: (() -> Void)?
    private var warming = false
    private var nextRequestPolicyReceivedMs = 0.0
    private var selectedFormats: SelectedFormats?
    private let videoHighWaterMark: Int
    private let audioHighWaterMark: Int
    private var isMintingPoToken = false
    private var isBroadcast = false

    private var runtime = Runtime()
    private var lifecycle = Lifecycle()
    private var progressTracker = ProgressTracker()

    private let callbacks: SabrStreamCallbacks

    init(_ config: SabrStreamConfig) {
        self.fetchFunction = config.fetchFunction ?? defaultFetchFunction

        self.videoId = config.videoId
        self.formats = config.formats
        self.clientInfo = config.clientInfo
        self.videoPlaybackUstreamerConfig = config.videoPlaybackUstreamerConfig
        self.proofOfOriginToken = config.poToken.flatMap { $0.isEmpty ? nil : base64ToU8($0) }
        self.heartbeatParams = config.heartbeatParams ?? HeartbeatParams()
        self.callbacks = config.callbacks ?? SabrStreamCallbacks()
        self.videoHighWaterMark = config.videoHighWaterMark ?? DEFAULT_VIDEO_HWM
        self.audioHighWaterMark = config.audioHighWaterMark ?? DEFAULT_AUDIO_HWM

        let streamingUrl = URL(string: config.serverAbrStreamingUrl)?.settingSearchParam("alr", "no")
        self.serverAbrStreamingUrl = streamingUrl

        let isBroadcast = ["yt_premiere_broadcast", "yt_live_broadcast"].contains(streamingUrl?.searchParam("source") ?? "")
        self.isBroadcast = isBroadcast

        self.broadcastId = isBroadcast ? streamingUrl.flatMap { getBroadcastId($0) } : nil

        let trackCollection = TrackCollection()
        self.trackCollection = trackCollection

        self.segmentBuffer = SabrSegmentBuffer(trackCollection, isBroadcast, config.stripDuplicateInit ?? true)

        super.init()

        trackCollection.video.output = createTrackStream(videoHighWaterMark)
        trackCollection.audio.output = createTrackStream(audioHighWaterMark)
    }

    var isLive: Bool {
        return isBroadcast
    }

    var isBusy: Bool {
        return lifecycle.busy
    }

    var isAborted: Bool {
        return lifecycle.aborted
    }

    var isErrored: Bool {
        return lifecycle.errored
    }

    var videoEndTimeMs: Int {
        return trackCollection.video.endTimeMs
    }

    var audioEndTimeMs: Int {
        return trackCollection.audio.endTimeMs
    }

    var livePlaybackLatencyMs: Double? {
        if !isBroadcast { return nil }
        return trackCollection.livePlaybackLatencyMs
    }

    var streamingURL: URL {
        get throws {
            return try assertIsDefined(serverAbrStreamingUrl, "Streaming URL is not set")
        }
    }

    func setStreamingURL(_ url: String) {
        guard let parsed = URL(string: url) else { return }
        setStreamingURL(parsed)
    }

    func setStreamingURL(_ url: URL) {
        let streamingUrl = url.settingSearchParam("alr", "no")
        serverAbrStreamingUrl = streamingUrl
        validateStreamingUrl(streamingUrl)
    }

    func setUstreamerConfig(_ config: String) {
        videoPlaybackUstreamerConfig = config
    }

    func waitForIdle() async {
        if lifecycle.busy {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                stateLock.lock()
                if !lifecycle.busy {
                    stateLock.unlock()
                    continuation.resume()
                    return
                }
                idleResolvers.append { continuation.resume() }
                stateLock.unlock()
            }
        }
    }

    func snapshot() async -> SabrSnapshot {
        await waitForIdle()
        return SabrSnapshot(
            playerTimeMs: runtime.playerTimeMs,
            tracks: trackCollection.snapshot()
        )
    }

    @discardableResult
    func abort(_ options: AbortOptions = AbortOptions()) async -> SabrSnapshot? {
        var snapshotData: SabrSnapshot?
        if options.snapshot == true { snapshotData = await snapshot() }

        emit(.abort)

        lifecycle.aborted = true

        abortController?.abort()
        trackCollection.error("Stream aborted")

        takeDrainResolver()?()
        takeResumeResolver()?()

        return snapshotData
    }

    func seek(toMs timeMs: Int) -> StreamStartResult? {
        stateLock.lock()
        guard !lifecycle.aborted, !lifecycle.errored, !shouldStop, !isBroadcast, let selectedFormats else {
            stateLock.unlock()
            return nil
        }
        seekEpoch += 1
        let previous = [trackCollection.video.output, trackCollection.audio.output]
        trackCollection.video.output = createTrackStream(videoHighWaterMark)
        trackCollection.audio.output = createTrackStream(audioHighWaterMark)
        for track in [trackCollection.video, trackCollection.audio] {
            track.discardMediaSegments()
            if let initSegment = track.initSegment { track.streamController.enqueue(initSegment) }
        }
        segmentBuffer.discardPending()
        runtime.playerTimeMs = timeMs
        lastSeekWallMs = nowMs()
        resetProgressTracker(Double(timeMs))
        let inFlight = abortController
        let drain = drainResolver
        drainResolver = nil
        let resume = resumeResolver
        resumeResolver = nil
        warming = false
        stateLock.unlock()

        previous.forEach { $0.controller.close() }
        inFlight?.abort()
        drain?()
        resume?()

        return StreamStartResult(
            videoStream: trackCollection.video.output.stream,
            audioStream: trackCollection.audio.output.stream,
            selectedFormats: selectedFormats
        )
    }

    private var currentSeekEpoch: Int {
        stateLock.lock()
        defer { stateLock.unlock() }
        return seekEpoch
    }

    private func takeResumeResolver() -> (() -> Void)? {
        stateLock.lock()
        defer { stateLock.unlock() }
        let resolver = resumeResolver
        resumeResolver = nil
        return resolver
    }

    private func waitForSeek(after epoch: Int) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            stateLock.lock()
            if seekEpoch != epoch || lifecycle.aborted {
                stateLock.unlock()
                continuation.resume()
                return
            }
            resumeResolver = { continuation.resume() }
            stateLock.unlock()
        }
    }

    func warm(_ options: SabrPlaybackOptions) throws {
        stateLock.lock()
        warming = true
        stateLock.unlock()
        _ = try start(options)
    }

    func start(_ options: SabrPlaybackOptions) throws -> StreamStartResult {
        try assert(runtime.playbackSessionStartMs == nil, "This stream instance has already been started and cannot be reused")
        let (videoFormat, audioFormat) = try selectFormats(options)
        let selected = SelectedFormats(videoFormat: videoFormat, audioFormat: audioFormat)
        stateLock.lock()
        selectedFormats = selected
        stateLock.unlock()

        Task { await setupStreaming(options, audioFormat, videoFormat) }

        return StreamStartResult(
            videoStream: trackCollection.video.output.stream,
            audioStream: trackCollection.audio.output.stream,
            selectedFormats: selected
        )
    }

    private func createTrackStream(_ highWaterMark: Int) -> TrackOutput {
        var controller: ReadableStream<Data>.Controller!
        let stream = ReadableStream<Data>(
            highWaterMark: highWaterMark,
            sizeOf: { $0.count },
            start: { controller = $0 },
            pull: { [weak self] in self?.notifyDrain() },
            cancel: { [weak self] reason in
                guard let self else { return }
                self.logger.debug(TAG, "Stream cancelled by consumer. Reason: \(reason ?? "N/A")")
                Task { await self.abort() }
            }
        )
        return TrackOutput(stream: stream, controller: controller)
    }

    private func takeDrainResolver(onlyIfDrained: Bool = false) -> (() -> Void)? {
        stateLock.lock()
        defer { stateLock.unlock() }
        if onlyIfDrained && trackCollection.needsDrain { return nil }
        let resolver = drainResolver
        drainResolver = nil
        return resolver
    }

    private func notifyDrain() {
        takeDrainResolver(onlyIfDrained: true)?()
    }

    private func waitForDrain() async {
        if !trackCollection.needsDrain { return }
        logger.debug(TAG, "Waiting for drain")
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            stateLock.lock()
            if !trackCollection.needsDrain || lifecycle.aborted {
                stateLock.unlock()
                continuation.resume()
                return
            }
            drainResolver = { continuation.resume() }
            stateLock.unlock()
        }
    }

    private func validateStreamingUrl(_ url: URL) {
        if let broadcastId = getBroadcastId(url) { validateBroadcastId(broadcastId) }
    }

    private func validateBroadcastId(_ bid: String) {
        if isBroadcast && (broadcastId != nil && broadcastId != bid) {
            logger.warn(TAG, "Broadcast ID changed from \(broadcastId!) to \(bid). Stopping.")
            shouldStop = true
        }
    }

    private func selectFormats(_ options: SabrPlaybackOptions) throws -> (videoFormat: SabrFormat?, audioFormat: SabrFormat) {
        let audioOnly = options.enabledTrackTypes == .audioOnly
        let needsVideo = !audioOnly

        let hasAudioSpecs = options.audioFormat != nil || options.audioPreferences != nil
        let hasVideoSpecs = options.videoFormat != nil || options.videoPreferences != nil

        if audioOnly {
            try assert(hasAudioSpecs, "Expected audio format or preferences to be provided")
        } else {
            try assert(hasAudioSpecs && hasVideoSpecs, "Expected both video and audio format or preferences to be provided")
        }

        let audioFormat = chooseFormat(formats, options.audioFormat, FormatPreferences(options.audioPreferences))

        let videoFormat = needsVideo
            ? chooseFormat(formats, options.videoFormat, FormatPreferences(options.videoPreferences))
            : nil

        var missing: [String] = []
        if needsVideo && videoFormat == nil { missing.append(describeMissingFormat(.video, options.videoFormat, formats)) }
        if audioFormat == nil { missing.append(describeMissingFormat(.audio, options.audioFormat, formats)) }
        if !missing.isEmpty { throw GoogleVideoError("Could not select formats: \(missing.joined(separator: "; "))") }

        let selectedAudioFormat = try assertIsDefined(audioFormat, "Expected selected audio format")

        return (videoFormat, selectedAudioFormat)
    }

    private func setupStreaming(
        _ options: SabrPlaybackOptions,
        _ audioFormat: SabrFormat,
        _ videoFormat: SabrFormat?
    ) async {
        do {
            logger.debug(TAG, "Starting SABR stream: videoFormat=\(videoFormat.map { String($0.itag) } ?? "n/a"), audioFormat=\(audioFormat.itag), isBroadcast=\(isBroadcast), isPostLiveDvr=\(options.isPostLiveDvr)")

            tryMintPoToken()

            let maxRetries = options.maxRetries ?? DEFAULT_MAX_RETRIES
            let enabledTrackTypesBitfield = options.enabledTrackTypes ?? .videoAndAudio

            if let snapshot = options.snapshot, !snapshot.tracks.isEmpty {
                if let videoFormat {
                    try assert(
                        try snapshot.tracks.contains { try createFormatKey($0) == createFormatKey(videoFormat) },
                        "The selected video format does not match any format in the provided snapshot"
                    )
                }

                try assert(
                    try snapshot.tracks.contains { try createFormatKey($0) == createFormatKey(audioFormat) },
                    "The selected audio format does not match any format in the provided snapshot"
                )

                for state in snapshot.tracks {
                    try trackCollection.initialize(getMediaType(state.mimeType), state)
                }

                seekTo(snapshot.playerTimeMs, .client)
            } else {
                seekTo(options.startTimeMs ?? (isBroadcast && !options.isPostLiveDvr ? LIVE_EDGE_SENTINEL_MS : 0), .client)
            }

            var abrState = ClientAbrState()
            abrState.playerTimeMs = Int64(runtime.playerTimeMs)
            if let audioTrackId = audioFormat.audioTrackId { abrState.audioTrackID = audioTrackId }
            abrState.clientViewportIsFlexible = false
            abrState.drcEnabled = audioFormat.isVb == true ? false : audioFormat.isDrc ?? false
            if let mediaCapabilities = buildMediaCapabilities(videoFormat, audioFormat) { abrState.mediaCapabilities = mediaCapabilities }
            if let isVb = audioFormat.isVb { abrState.enableVoiceBoost = isVb }
            if let height = videoFormat?.height { abrState.stickyResolution = Int32(height) }
            abrState.elapsedWallTimeMs = 0
            abrState.timeSinceLastActionMs = 0
            abrState.timeSinceLastSeek = 0
            abrState.playbackRate = 1
            abrState.visibility = 1
            abrState.enabledTrackTypesBitfield = Int32(enabledTrackTypesBitfield.rawValue)

            runtime.playbackSessionStartMs = nowMs()

            while !shouldStop {
                if lifecycle.aborted {
                    logger.debug(TAG, "Stream aborted")
                    break
                }

                let elapsedTimeMs = Int64(getElapsedWallTimeMs())

                abrState.timeSinceLastSeek = lastSeekWallMs.map { Int64(nowMs() - $0) } ?? elapsedTimeMs
                abrState.timeSinceLastActionMs = elapsedTimeMs
                abrState.elapsedWallTimeMs = elapsedTimeMs

                if runtime.bandwidthEstimateBps > 0 {
                    abrState.bandwidthEstimate = Int64(runtime.bandwidthEstimateBps.rounded())
                }

                logger.debug(TAG, "Starting new segment fetch, playerTimeMs=\(abrState.playerTimeMs), bandwidthEstimate=\(abrState.hasBandwidthEstimate ? String(abrState.bandwidthEstimate) : "n/a"), elapsedWallTimeMs=\(abrState.elapsedWallTimeMs)")

                try checkForStall(options.stallDetectionMs)

                let currentAbrState = abrState

                let success = await executeWithRetry({
                    try await self.fetchAndProcess(
                        currentAbrState,
                        audioFormat,
                        videoFormat
                    )
                }, maxRetries)

                abrState.playerTimeMs = Int64(runtime.playerTimeMs)

                let parkEpoch: Int? = {
                    stateLock.lock()
                    defer { stateLock.unlock() }
                    return warming ? seekEpoch : nil
                }()
                if success, let parkEpoch {
                    await waitForSeek(after: parkEpoch)
                    abrState.playerTimeMs = Int64(runtime.playerTimeMs)
                    continue
                }

                if trackCollection.endOfStreamReached(enabledTrackTypesBitfield) {
                    if isBroadcast {
                        shouldStop = true
                    } else {
                        let epoch = currentSeekEpoch
                        trackCollection.close()
                        emit(.finish)
                        await waitForSeek(after: epoch)
                        abrState.playerTimeMs = Int64(runtime.playerTimeMs)
                        continue
                    }
                }

                if isBroadcast {
                    Task { await heartbeat() }
                }

                if !success { break }
            }
        } catch {
            if !lifecycle.aborted {
                errorHandler(error)
            }
        }

        if !lifecycle.aborted && !lifecycle.errored {
            trackCollection.close()
            emit(.finish)
        }

        dispose()
    }

    private func heartbeat() async {
        let heartbeatParams = self.heartbeatParams
        let heartbeatCallback = callbacks.onCheckHeartbeat

        guard let heartbeatCallback, let videoId else {
            return
        }

        let intervalMs = heartbeatParams.intervalMilliseconds.map { Int($0) ?? 0 } ?? DEFAULT_HEARTBEAT_INTERVAL_MS
        let timeSinceLastHeartbeat = nowMs() - runtime.lastHeartbeatTimeMs

        if timeSinceLastHeartbeat < Double(intervalMs) {
            return
        }

        do {
            runtime.lastHeartbeatTimeMs = nowMs()

            var heartbeatBody = HeartbeatRequest(
                heartbeatRequestParams: HeartbeatRequestParams(heartbeatChecks: [.liveStreamStatus]),
                videoId: videoId
            )

            if heartbeatParams.heartbeatToken != nil {
                heartbeatBody.heartbeatToken = heartbeatParams.heartbeatToken
            }

            if heartbeatParams.heartbeatServerData != nil {
                heartbeatBody.heartbeatServerData = heartbeatParams.heartbeatServerData
            }

            let response = try await heartbeatCallback(heartbeatBody)
            if shouldStop { return }

            if response.heartbeatServerData != nil {
                self.heartbeatParams.heartbeatServerData = response.heartbeatServerData
            }

            if let broadcastId = response.broadcastId {
                validateBroadcastId(broadcastId)
            }

            if response.status == .ok {
                logger.debug(TAG, "Live stream is online")
                return
            }

            if response.status == .liveStreamOffline {
                if response.offlineSlatePresent == true && response.displayEndscreen != true {
                    logger.debug(TAG, "Live stream is offline but not displaying end screen. Continuing.")
                    return
                }

                if !(response.displayEndscreen == true || response.offlineSlateButtonsPresent == true) {
                    return
                }

                let elapsedTimeSinceLastProgress = nowMs() - progressTracker.lastProgressTime

                if elapsedTimeSinceLastProgress > OFFLINE_GRACE_PERIOD_MS {
                    logger.debug(TAG, "Heartbeat check indicates live stream is offline and no activity for \(elapsedTimeSinceLastProgress)ms. Stopping stream.")
                    shouldStop = true
                    return
                }

                logger.debug(TAG, "Heartbeat check indicates live stream is offline, but progress was made \(elapsedTimeSinceLastProgress)ms ago. Continuing.")
            }
        } catch {
            logger.warn(TAG, "Heartbeat check failed:", errorMessage(error))
        }
    }

    private func dispose() {
        sabrContextUpdates.removeAll()
        ssapPlaybackInfos.removeAll()
        activeSabrContextTypes.removeAll()
        segmentBuffer.reset()

        abortController = nil
        nextRequestPolicy = nil

        runtime.spsRejectCount = 0
        runtime.playerTimeMs = 0
        runtime.requestNumber = 0
        runtime.bandwidthEstimateBps = 0
        isMintingPoToken = false

        resetProgressTracker(0)
        clearRequestTimeout()
        setBusyState(false)
    }

    private func getElapsedWallTimeMs() -> Double {
        guard let playbackSessionStartMs = runtime.playbackSessionStartMs else { return 0 }
        return nowMs() - playbackSessionStartMs
    }

    private func checkForStall(_ stallDetectionMs: Int?) throws {
        if isBroadcast && runtime.playerTimeMs == LIVE_EDGE_SENTINEL_MS {
            return
        }

        let currentTime = nowMs()
        let stallThreshold = stallDetectionMs ?? DEFAULT_STALL_DETECTION_MS

        if currentTime - progressTracker.lastProgressTime > Double(stallThreshold) {
            progressTracker.stallCount += 1

            logger.warn(TAG, "Stream stalled for \(stallThreshold)ms (stall #\(progressTracker.stallCount))")

            if progressTracker.stallCount >= MAX_STALLS {
                if isBroadcast {
                    logger.warn(TAG, "Live stream stalled. Assuming end of stream and stopping download")
                    shouldStop = true
                } else {
                    throw GoogleVideoError("Stream stalled \(MAX_STALLS) times. Aborting")
                }
            }

            progressTracker.lastProgressTime = currentTime
        }
    }

    private func executeWithRetry(
        _ fetchFn: () async throws -> Void,
        _ maxRetries: Int
    ) async -> Bool {
        let backoffTimeMs = Int(Double(nextRequestPolicy?.backoffTimeMs ?? 0) - (nowMs() - nextRequestPolicyReceivedMs))

        if backoffTimeMs > 0 {
            logger.debug(TAG, "Backing off for \(backoffTimeMs)ms before next request")
            await wait(backoffTimeMs)
        }

        let epoch = currentSeekEpoch

        for attempt in 1...(maxRetries + 1) {
            if lifecycle.aborted {
                logger.debug(TAG, "Abort requested, preventing new requests")
                return false
            }

            if currentSeekEpoch != epoch {
                return true
            }

            do {
                setBusyState(true)
                try await fetchFn()
                setBusyState(false)
                return true
            } catch {
                setBusyState(false)

                if lifecycle.aborted {
                    logger.debug(TAG, "Abort requested, not retrying fetch")
                    return false
                }

                if currentSeekEpoch != epoch {
                    return true
                }

                if attempt > maxRetries {
                    logger.warn(TAG, "Retries exhausted while fetching segment: \(errorMessage(error))")
                    errorHandler(error)
                    break
                }

                let retryBackoffMs = min(INITIAL_RETRY_BACKOFF_MS * Int(pow(2.0, Double(attempt - 1))), MAX_RETRY_BACKOFF_MS)
                logger.warn(TAG, "Segment fetch attempt \(attempt)/\(maxRetries) failed - retrying in \(retryBackoffMs)ms", error)
                await wait(retryBackoffMs)
            }
        }

        return false
    }

    private func setBusyState(_ newState: Bool) {
        stateLock.lock()
        lifecycle.busy = newState
        var resolvers: [() -> Void] = []
        if !newState {
            resolvers = idleResolvers
            idleResolvers = []
        }
        stateLock.unlock()
        resolvers.forEach { $0() }
    }

    private func errorHandler(_ err: any Error) {
        lifecycle.errored = true
        trackCollection.error(err)
        emit(.error, err)
    }

    private func fetchAndProcess(
        _ abrState: ClientAbrState,
        _ selectedAudioFormat: SabrFormat?,
        _ selectedVideoFormat: SabrFormat?
    ) async throws {
        let requestPoTokenGeneration = runtime.poTokenGenerationId
        let epoch = currentSeekEpoch

        let requestBody = try buildRequestBody(abrState, selectedAudioFormat, selectedVideoFormat)
        let startTime = nowMs()
        let fetched = try await makeStreamingRequest(requestBody)
        let response = fetched.response
        let contentType = response.value(forHTTPHeaderField: "content-type")

        let expired = response.statusCode == 403 ? try hasExpired() : false
        if expired {
            fetched.cancel()
            try await tryReloadStreamingData()
        }

        guard (200..<300).contains(response.statusCode), contentType == "application/vnd.yt-ump" else {
            fetched.cancel()
            try assert((200..<300).contains(response.statusCode), "Server returned \(response.statusCode)")
            throw GoogleVideoError("Unexpected content type from server: \(contentType ?? "null")")
        }

        var serverSeek = false
        var bytesDownloaded = 0

        let umpReader = UmpReader(UmpReaderCallbacks(onPart: { type, data in
            if self.currentSeekEpoch != epoch { throw CancellationError() }
            switch UMPPartId(rawValue: type) {
            case .sabrError:
                guard let sabrError = decodePart(data.chunks, SabrError.self) else { break }
                throw GoogleVideoError("SABR Error: \(sabrError.type) - \(sabrError.code)")

            case .formatInitializationMetadata:
                guard let formatInitializationMetadata = decodePart(data.chunks, FormatInitializationMetadata.self) else { break }

                if self.videoId != formatInitializationMetadata.videoID {
                    self.logger.warn(TAG, "Video ID mismatch: expected \(self.videoId ?? "nil"), got \(formatInitializationMetadata.videoID). Ignoring format initialization metadata.")
                    return
                }

                if !self.trackCollection.initializedTracksMap.has(try createFormatKey(formatInitializationMetadata)) {
                    let formatType = getMediaType(formatInitializationMetadata.mimeType)
                    let selectedFormat = formatType == .video ? selectedVideoFormat : selectedAudioFormat

                    try self.trackCollection.initialize(formatType, TrackState(
                        formatId: formatInitializationMetadata.formatID,
                        mimeType: formatInitializationMetadata.mimeType,
                        endSegmentNum: Int(formatInitializationMetadata.endSegmentNum),
                        endTimeTicks: Int(formatInitializationMetadata.endTimeTicks),
                        endTimescale: formatInitializationMetadata.endTimeTimescale != 0 ? Int(formatInitializationMetadata.endTimeTimescale) : 1000,
                        targetDurationSec: selectedFormat?.targetDurationSec
                    ))

                    self.logger.debug(TAG, "Initialized format: itag=\(formatInitializationMetadata.formatID.itag), mimeType=\(formatInitializationMetadata.mimeType)")

                    self.emit(.formatInitialization, self.trackCollection.track(formatType))
                }

            case .mediaHeader:
                guard let mediaHeader = decodePart(data.chunks, MediaHeader.self) else { break }

                if self.videoId != mediaHeader.videoID {
                    self.logger.warn(TAG, "Video ID mismatch: expected \(self.videoId ?? "nil"), got \(mediaHeader.videoID). Ignoring media header.")
                    break
                }

                self.logger.debug(TAG, "Received media header: headerId=\(mediaHeader.headerID), itag=\(mediaHeader.itag), segmentNum=\(mediaHeader.segmentNum), startMs=\(mediaHeader.startMs), durationMs=\(mediaHeader.durationMs), segmentLengthBytes=\(mediaHeader.segmentLengthBytes)")
                try self.segmentBuffer.queueMediaHeader(mediaHeader)

            case .media:
                let headerId = Int(data.getUint8(0))
                let dataBuffer = data.split(1).remainingBuffer
                self.segmentBuffer.appendMediaData(headerId, dataBuffer)

            case .mediaEnd:
                let headerId = Int(data.getUint8(0))
                if try self.segmentBuffer.finalizeSegment(headerId) {
                    self.recordProgress(self.trackCollection.buffered)
                    self.logger.debug(TAG, "Finalized segment: headerId=\(headerId)")
                    self.emit(.trackStateUpdate, self.trackCollection)
                }

            case .liveMetadata:
                guard let sabrLiveMetadata = decodePart(data.chunks, SabrLiveMetadata.self) else { break }

                if sabrLiveMetadata.hasBroadcastID, !sabrLiveMetadata.broadcastID.isEmpty {
                    self.validateBroadcastId(sabrLiveMetadata.broadcastID)
                }

                self.emit(.liveMetadataUpdate, sabrLiveMetadata)

            case .sabrSeek:
                guard let sabrSeek = decodePart(data.chunks, SabrSeek.self) else { break }

                if sabrSeek.seekSource == .sabrSeekToHead {
                    let seekTimeMs = ticksToMs(Int(sabrSeek.seekMediaTime), sabrSeek.seekMediaTimescale != 0 ? Int(sabrSeek.seekMediaTimescale) : 1000, floor)
                    self.seekTo(seekTimeMs, .server)
                    self.resetProgressTracker(Double(seekTimeMs))
                    self.ssapPlaybackInfos.removeAll()
                    serverSeek = true
                }

            case .cuepointList:
                guard let cuepointList = decodePart(data.chunks, CuepointList.self) else { break }

                for info in cuepointList.ssapInfos {
                    let cuepointId = info.cuepoint.identifier

                    if !info.hasCuepoint || !info.hasTimeRange {
                        continue
                    }

                    let cuepoint = info.cuepoint
                    let timeRange = info.timeRange

                    if cuepoint.event == .stop {
                        self.ssapPlaybackInfos.removeValue(forKey: cuepointId)
                        self.logger.debug(TAG, "Removed cuepoint: identifier=\(cuepointId)")
                    } else {
                        if self.ssapPlaybackInfos.has(cuepointId) {
                            continue
                        }

                        let timescale = timeRange.timescale != 0 ? Int(timeRange.timescale) : 1000
                        let startTicks = Int(timeRange.startTicks)
                        let startTimeMs = Int64(floor(Double(ticksToMs(startTicks, timescale, floor)) - (cuepoint.playheadTimeSec * 1000)))
                        let durationMs = Int64(cuepoint.totalDurationSec * 1000)

                        var playbackInfo = SsapPlaybackInfo()
                        playbackInfo.cuepointID = cuepointId
                        playbackInfo.startTimeMs = startTimeMs
                        playbackInfo.durationMs = durationMs
                        playbackInfo.state = .ratecontrolClient
                        self.ssapPlaybackInfos[cuepointId] = playbackInfo

                        self.logger.debug(TAG, "Added new cuepoint: cuepointId=\(cuepointId), startTimeMs=\(startTimeMs), durationMs=\(durationMs)")
                    }
                }

            case .sabrContextUpdate:
                guard let contextUpdate = decodePart(data.chunks, SabrContextUpdate.self),
                      contextUpdate.hasType, contextUpdate.hasValue, !contextUpdate.value.isEmpty
                else { break }

                let contextType = Int(contextUpdate.type)

                if contextUpdate.writePolicy == .keepExisting && self.sabrContextUpdates.has(contextType) {
                    break
                }

                self.sabrContextUpdates[contextType] = contextUpdate

                if contextUpdate.sendByDefault {
                    self.activeSabrContextTypes.insert(contextType)
                }

            case .sabrContextSendingPolicy:
                guard let contextSendingPolicy = decodePart(data.chunks, SabrContextSendingPolicy.self) else { break }

                for startPolicy in contextSendingPolicy.startPolicy.map(Int.init) {
                    if !self.activeSabrContextTypes.contains(startPolicy) {
                        self.activeSabrContextTypes.insert(startPolicy)
                        self.logger.debug(TAG, "Activated SABR context: type=\(startPolicy)")
                    }
                }

                for stopPolicy in contextSendingPolicy.stopPolicy.map(Int.init) {
                    if self.activeSabrContextTypes.contains(stopPolicy) {
                        self.activeSabrContextTypes.remove(stopPolicy)
                        self.logger.debug(TAG, "Deactivated SABR context: type=\(stopPolicy)")
                    }
                }

                for discardPolicy in contextSendingPolicy.discardPolicy.map(Int.init) {
                    if self.sabrContextUpdates.has(discardPolicy) {
                        self.sabrContextUpdates.removeValue(forKey: discardPolicy)
                        self.logger.debug(TAG, "Discarded SABR context: type=\(discardPolicy)")
                    }
                }

            case .nextRequestPolicy:
                self.nextRequestPolicy = decodePart(data.chunks, NextRequestPolicy.self)
                self.nextRequestPolicyReceivedMs = nowMs()

            case .streamProtectionStatus:
                guard let streamProtectionStatus = decodePart(data.chunks, StreamProtectionStatus.self),
                      streamProtectionStatus.status != 0
                else { break }

                self.emit(.streamProtectionStatusUpdate, streamProtectionStatus)

                if requestPoTokenGeneration != self.runtime.poTokenGenerationId {
                    break
                }

                let isRejected = streamProtectionStatus.status == 3
                let isPending = streamProtectionStatus.status == 2
                let maxRetries = streamProtectionStatus.maxRetries != 0 ? Int(streamProtectionStatus.maxRetries) : 5
                let spsRejectCount = self.runtime.spsRejectCount

                try assert(spsRejectCount < maxRetries, "Stream protection attestation rejected after \(spsRejectCount) attempts")

                if (isRejected || isPending) && !self.isMintingPoToken {
                    self.logger.warn(TAG,
                        isRejected ?
                            "Stream protection attestation rejected: attempt \(spsRejectCount) of \(maxRetries)" :
                            "Stream protection attestation pending")

                    if isRejected {
                        self.runtime.spsRejectCount += 1
                    }

                    self.tryMintPoToken()
                }

            case .sabrRedirect:
                guard let sabrRedirect = decodePart(data.chunks, SabrRedirect.self), !sabrRedirect.url.isEmpty else { break }
                self.setStreamingURL(sabrRedirect.url)
                self.logger.debug(TAG, "Received SABR redirect: newUrl=\(sabrRedirect.url)")

            case .reloadPlayerResponse:
                guard let reloadPlaybackContext = decodePart(data.chunks, ReloadPlaybackContext.self) else { break }
                self.logger.debug(TAG, "Reload requested: reloadPlaybackParams=\(reloadPlaybackContext.reloadPlaybackParams)")
                try await self.tryReloadStreamingData(reloadPlaybackContext)

            default:
                break
            }
        }))

        let abortController = self.abortController

        abortController?.onAbort(fetched.cancel)

        do {
            for try await value in fetched.body {
                await waitForDrain()

                if abortController?.aborted == true && !lifecycle.aborted {
                    throw GoogleVideoError("Request timed out")
                }

                if lifecycle.aborted {
                    break
                }

                if value.count > 0 {
                    bytesDownloaded += value.count
                    resetRequestTimeout()
                    try await umpReader.feed(value)
                }
            }
        } catch {
            fetched.cancel()
            clearRequestTimeout()
            umpReader.dispose()
            if abortController?.aborted == true && !lifecycle.aborted && currentSeekEpoch == epoch {
                throw GoogleVideoError("Request timed out")
            }
            throw error
        }

        fetched.cancel()
        clearRequestTimeout()
        umpReader.dispose()

        let fetchDurationMs = nowMs() - startTime

        if fetchDurationMs > MIN_FETCH_DURATION_FOR_BW_ESTIMATE_MS && bytesDownloaded > 0 {
            let currentBps = Double(bytesDownloaded * 8) / (fetchDurationMs / 1000)
            let bandwidthEstimateBps = runtime.bandwidthEstimateBps
            runtime.bandwidthEstimateBps = bandwidthEstimateBps == 0
                ? currentBps
                : BANDWIDTH_EMA_PREVIOUS_WEIGHT * bandwidthEstimateBps + BANDWIDTH_EMA_CURRENT_WEIGHT * currentBps
        }

        if !serverSeek && currentSeekEpoch == epoch {
            let buffered = trackCollection.buffered
            if buffered != Double.infinity {
                seekTo(Int(buffered.rounded()), .client)
            }
        }
    }

    private func tryMintPoToken() {
        guard let onMintPoToken = callbacks.onMintPoToken else { return }

        isMintingPoToken = true

        Task {
            do {
                self.proofOfOriginToken = try await onMintPoToken()
                self.runtime.poTokenGenerationId += 1
            } catch {
                self.logger.warn(TAG, "An error occurred while minting proof of origin token: \(errorMessage(error))")
            }
            self.isMintingPoToken = false
        }
    }

    private func buildRequestBody(
        _ abrState: ClientAbrState,
        _ selectedAudioFormat: SabrFormat?,
        _ selectedVideoFormat: SabrFormat?
    ) throws -> Data {
        let ssapPlaybackInfos = self.ssapPlaybackInfos.values
        let videoPlaybackUstreamerConfig = base64ToU8(self.videoPlaybackUstreamerConfig)
        let bufferedRanges = trackCollection.bufferedRanges
        let playbackCookie = nextRequestPolicy?.hasPlaybackCookie == true ? try nextRequestPolicy!.playbackCookie.serializedData() : nil
        let poToken = proofOfOriginToken

        let initializationFormatIds = !isBroadcast ? trackCollection.initializationFormatIds : []
        let selectedAudioFormatIds = selectedAudioFormat.map { [FormatId($0)] } ?? []
        let selectedVideoFormatIds = selectedVideoFormat.map { [FormatId($0)] } ?? []

        let (sabrContexts, unsentSabrContexts) = prepareSabrContexts()

        var streamerContext = StreamerContext()
        streamerContext.clientInfo = clientInfo
        if let playbackCookie { streamerContext.playbackCookie = playbackCookie }
        streamerContext.unsentSabrContexts = unsentSabrContexts
        streamerContext.sabrContexts = sabrContexts
        if let poToken { streamerContext.poToken = poToken }

        var request = VideoPlaybackAbrRequest()
        request.clientAbrState = abrState
        request.bufferedRanges = bufferedRanges
        request.ssapPlaybackInfos = ssapPlaybackInfos
        request.initializationFormatIds = initializationFormatIds
        request.selectedAudioFormatIds = selectedAudioFormatIds
        request.selectedVideoFormatIds = selectedVideoFormatIds
        request.selectedCaptionFormatIds = []
        request.videoPlaybackUstreamerConfig = videoPlaybackUstreamerConfig
        request.streamerContext = streamerContext
        request.field1000 = []

        return try request.serializedData()
    }

    private func prepareSabrContexts() -> (sabrContexts: [SabrContext], unsentSabrContexts: [Int32]) {
        var sabrContexts: [SabrContext] = []
        var unsentSabrContexts: [Int32] = []

        for (type, ctxUpdate) in sabrContextUpdates.entries {
            if activeSabrContextTypes.contains(type) {
                var sabrContext = SabrContext()
                sabrContext.type = ctxUpdate.type
                sabrContext.value = ctxUpdate.value
                sabrContexts.append(sabrContext)
            } else {
                unsentSabrContexts.append(Int32(type))
            }
        }

        return (sabrContexts, unsentSabrContexts)
    }

    private func makeStreamingRequest(_ body: Data) async throws -> FetchResponse {
        serverAbrStreamingUrl = try streamingURL.settingSearchParam("rn", String(runtime.requestNumber))
        let epoch = currentSeekEpoch
        let abortController = AbortController()
        self.abortController = abortController
        resetRequestTimeout()

        defer { runtime.requestNumber += 1 }

        do {
            var request = URLRequest(url: try streamingURL)
            request.httpMethod = "POST"
            request.httpBody = body
            request.setValue("application/x-protobuf", forHTTPHeaderField: "content-type")
            request.setValue("identity", forHTTPHeaderField: "accept-encoding")
            request.setValue("application/vnd.yt-ump", forHTTPHeaderField: "accept")

            let fetchFunction = self.fetchFunction
            let task = Task { try await fetchFunction(request) }
            abortController.onAbort { task.cancel() }

            return try await task.value
        } catch {
            clearRequestTimeout()

            if lifecycle.aborted || currentSeekEpoch != epoch { throw error }

            if let nextFallbackUrl = getNextFallbackUrl(try streamingURL) {
                logger.warn(TAG, "Switching to fallback URL: \(nextFallbackUrl.host ?? "")")
                setStreamingURL(nextFallbackUrl)
            }

            throw error
        }
    }

    private func hasExpired() throws -> Bool {
        guard let expireRawValue = try streamingURL.searchParam("expire"), !expireRawValue.isEmpty else { return false }

        let expireTimestampMs = Double(Int(expireRawValue) ?? 0) * 1000
        let msRemaining = expireTimestampMs - nowMs()

        return msRemaining <= 0
    }

    private func tryReloadStreamingData(_ reloadPlaybackContext: ReloadPlaybackContext? = nil) async throws {
        if let onReloadPlayerResponseCb = callbacks.onReloadPlayerResponse {
            do {
                let response = try await onReloadPlayerResponseCb(reloadPlaybackContext)
                setStreamingURL(response.serverAbrStreamingUrl)
                setUstreamerConfig(response.videoPlaybackUstreamerConfig)

                sabrContextUpdates.removeAll()
                activeSabrContextTypes.removeAll()
                ssapPlaybackInfos.removeAll()
            } catch {
                throw GoogleVideoError("An error occurred while reloading streaming data: \(errorMessage(error))")
            }
        } else {
            throw GoogleVideoError("Streaming data reload requested but no handler was found")
        }
    }

    private func resetRequestTimeout() {
        clearRequestTimeout()
        let abortController = self.abortController
        requestTimeoutTask = Task {
            await wait(REQUEST_TIMEOUT_MS)
            if !Task.isCancelled { abortController?.abort() }
        }
    }

    private func clearRequestTimeout() {
        requestTimeoutTask?.cancel()
        requestTimeoutTask = nil
    }

    private func recordProgress(_ progressMs: Double) {
        if !progressMs.isFinite || progressMs <= progressTracker.lastBufferedTimeMs {
            return
        }

        progressTracker.lastProgressTime = nowMs()
        progressTracker.lastBufferedTimeMs = progressMs
        progressTracker.stallCount = 0
    }

    private func seekTo(_ timeMs: Int, _ source: SeekOrigin) {
        logger.debug(TAG, "Seeking: timeMs=\(timeMs), source=\(source.rawValue)")
        runtime.playerTimeMs = timeMs
    }

    private func resetProgressTracker(_ progressMs: Double) {
        progressTracker = ProgressTracker(
            lastProgressTime: nowMs(),
            lastBufferedTimeMs: progressMs,
            stallCount: 0
        )
    }
}
