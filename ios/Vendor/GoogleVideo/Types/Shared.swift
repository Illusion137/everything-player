import Foundation

struct Part {
    var type: Int
    var size: Int
    var data: CompositeBuffer

    init(type: Int, size: Int, data: CompositeBuffer) {
        self.type = type
        self.size = size
        self.data = data
    }
}

struct SabrFormat: Equatable, Hashable, Sendable {
    var itag: Int
    var lastModified: String
    var xtags: String?
    var fps: Int?
    var width: Int?
    var height: Int?
    var contentLength: Int?
    var audioTrackId: String?
    var mimeType: String?
    var isDrc: Bool?
    var isVb: Bool?
    var isSr: Bool?
    var quality: String?
    var qualityLabel: String?
    var averageBitrate: Int?
    var bitrate: Int
    var audioQuality: String?
    var numChannels: Int?
    var approxDurationMs: Int
    var language: String?
    var isHdr: Bool
    var isDubbed: Bool?
    var isAutoDubbed: Bool?
    var isDescriptive: Bool?
    var isSecondary: Bool?
    var isOriginal: Bool?
    var hasAudio: Bool
    var hasVideo: Bool
    var hasText: Bool
    var targetDurationSec: Double?
    var codecCode: String?

    init(
        itag: Int,
        lastModified: String,
        xtags: String? = nil,
        contentLength: Int? = nil,
        mimeType: String? = nil,
        bitrate: Int,
        height: Int? = nil,
        approxDurationMs: Int,
        fps: Int? = nil,
        width: Int? = nil,
        audioTrackId: String? = nil,
        isDrc: Bool? = nil,
        isVb: Bool? = nil,
        isSr: Bool? = nil,
        quality: String? = nil,
        qualityLabel: String? = nil,
        averageBitrate: Int? = nil,
        audioQuality: String? = nil,
        numChannels: Int? = nil,
        language: String? = nil,
        isHdr: Bool = false,
        isDubbed: Bool? = nil,
        isAutoDubbed: Bool? = nil,
        isDescriptive: Bool? = nil,
        isSecondary: Bool? = nil,
        isOriginal: Bool? = nil,
        hasAudio: Bool = false,
        hasVideo: Bool = false,
        hasText: Bool = false,
        targetDurationSec: Double? = nil,
        codecCode: String? = nil
    ) {
        self.itag = itag
        self.lastModified = lastModified
        self.xtags = xtags
        self.fps = fps
        self.width = width
        self.height = height
        self.contentLength = contentLength
        self.audioTrackId = audioTrackId
        self.mimeType = mimeType
        self.isDrc = isDrc
        self.isVb = isVb
        self.isSr = isSr
        self.quality = quality
        self.qualityLabel = qualityLabel
        self.averageBitrate = averageBitrate
        self.bitrate = bitrate
        self.audioQuality = audioQuality
        self.numChannels = numChannels
        self.approxDurationMs = approxDurationMs
        self.language = language
        self.isHdr = isHdr
        self.isDubbed = isDubbed
        self.isAutoDubbed = isAutoDubbed
        self.isDescriptive = isDescriptive
        self.isSecondary = isSecondary
        self.isOriginal = isOriginal
        self.hasAudio = hasAudio
        self.hasVideo = hasVideo
        self.hasText = hasText
        self.targetDurationSec = targetDurationSec
        self.codecCode = codecCode
    }
}

struct FormatColorInfo: Sendable {
    var transfer_characteristics: String?
    var transferCharacteristics: String?

    init(transfer_characteristics: String? = nil, transferCharacteristics: String? = nil) {
        self.transfer_characteristics = transfer_characteristics
        self.transferCharacteristics = transferCharacteristics
    }
}

struct FormatStream: Sendable {
    var itag: Int
    var last_modified_ms: String?
    var lastModified: String?
    var fps: Int?
    var xtags: String?
    var width: Int?
    var height: Int?
    var mime_type: String?
    var mimeType: String?
    var audio_quality: String?
    var audioQuality: String?
    var bitrate: Int
    var average_bitrate: Int?
    var averageBitrate: Int?
    var quality: String?
    var quality_label: String?
    var qualityLabel: String?
    var audio_track: AudioTrack?
    var audioTrackId: String?
    var audioChannels: Int?
    var audio_channels: Int?
    var caption_track: [String: String]?
    var captionTrack: [String: String]?
    var color_info: FormatColorInfo?
    var colorInfo: FormatColorInfo?
    var is_drc: Bool?
    var isDrc: Bool?
    var isVb: Bool?
    var is_vb: Bool?
    var is_sr: Bool?
    var isSr: Bool?
    var approx_duration_ms: Int?
    var approxDurationMs: String?
    var content_length: Int?
    var contentLength: String?
    var is_auto_dubbed: Bool?
    var is_descriptive: Bool?
    var is_dubbed: Bool?
    var language: String?
    var is_original: Bool?
    var is_secondary: Bool?
    var targetDurationSec: Double?
    var target_duration_sec: Double?
    var target_duration_dec: Double?

    struct AudioTrack: Sendable {
        var id: String

        init(id: String) {
            self.id = id
        }
    }

    init(itag: Int, bitrate: Int) {
        self.itag = itag
        self.bitrate = bitrate
    }
}

protocol CreateFormatKeyInput {
    var formatKeyCandidates: [(itag: Int?, xtags: String?)] { get }
}

struct FetchResponse: Sendable {
    var response: HTTPURLResponse
    var body: AsyncThrowingStream<Data, Error>
    var cancel: @Sendable () -> Void
}

typealias FetchFunction = @Sendable (URLRequest) async throws -> FetchResponse

let defaultFetchFunction: FetchFunction = { request in
    try await StreamingFetcher.shared.fetch(request)
}

final class StreamingFetcher: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    static let shared = StreamingFetcher()

    private final class Pending {
        var response: CheckedContinuation<HTTPURLResponse, Error>?
        let body: AsyncThrowingStream<Data, Error>.Continuation

        init(response: CheckedContinuation<HTTPURLResponse, Error>, body: AsyncThrowingStream<Data, Error>.Continuation) {
            self.response = response
            self.body = body
        }
    }

    private let lock = NSLock()
    private var pending: [Int: Pending] = [:]
    private var session: URLSession!

    override init() {
        super.init()
        session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
    }

    func fetch(_ request: URLRequest) async throws -> FetchResponse {
        let (body, continuation) = AsyncThrowingStream<Data, Error>.makeStream()
        let task = session.dataTask(with: request)
        continuation.onTermination = { _ in task.cancel() }
        let response: HTTPURLResponse = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (rc: CheckedContinuation<HTTPURLResponse, Error>) in
                lock.lock()
                pending[task.taskIdentifier] = Pending(response: rc, body: continuation)
                lock.unlock()
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
        return FetchResponse(response: response, body: body, cancel: { task.cancel() })
    }

    func urlSession(
        _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        lock.lock()
        let rc = pending[dataTask.taskIdentifier]?.response
        pending[dataTask.taskIdentifier]?.response = nil
        lock.unlock()
        if let http = response as? HTTPURLResponse {
            completionHandler(.allow)
            rc?.resume(returning: http)
        } else {
            completionHandler(.cancel)
            rc?.resume(throwing: GoogleVideoError("Invalid response"))
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        let body = pending[dataTask.taskIdentifier]?.body
        lock.unlock()
        body?.yield(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let entry = pending.removeValue(forKey: task.taskIdentifier)
        lock.unlock()
        entry?.response?.resume(throwing: error ?? GoogleVideoError("No response"))
        if let error { entry?.body.finish(throwing: error) } else { entry?.body.finish() }
    }
}
