import Foundation

let MAX_INT32_VALUE = "2147483647"

enum EnabledTrackTypes: Int, Sendable {
    case videoAndAudio = 0
    case audioOnly = 1
    case videoOnly = 2
}

struct FormatPreferences {
    var quality: String?
    var language: String?
    var container: MediaContainer?
    var preferredVideoCodec: PreferredVideoCodec?
    var preferredAudioCodec: PreferredAudioCodec?
    var voiceBoost: Bool?
    var dynamicRangeCompression: Bool?
    var superResolution: Bool?
    var hdr: Bool?
    var isAudio: Bool

    init(
        quality: String? = nil,
        language: String? = nil,
        container: MediaContainer? = nil,
        preferredVideoCodec: PreferredVideoCodec? = nil,
        preferredAudioCodec: PreferredAudioCodec? = nil,
        voiceBoost: Bool? = nil,
        dynamicRangeCompression: Bool? = nil,
        superResolution: Bool? = nil,
        hdr: Bool? = nil,
        isAudio: Bool
    ) {
        self.quality = quality
        self.language = language
        self.container = container
        self.preferredVideoCodec = preferredVideoCodec
        self.preferredAudioCodec = preferredAudioCodec
        self.voiceBoost = voiceBoost
        self.dynamicRangeCompression = dynamicRangeCompression
        self.superResolution = superResolution
        self.hdr = hdr
        self.isAudio = isAudio
    }

    init(_ preferences: AudioFormatPreferences?) {
        self.init(
            quality: preferences?.quality?.rawValue,
            language: preferences?.language,
            container: preferences?.container,
            preferredAudioCodec: preferences?.preferredAudioCodec,
            voiceBoost: preferences?.voiceBoost,
            dynamicRangeCompression: preferences?.dynamicRangeCompression,
            isAudio: true
        )
    }

    init(_ preferences: VideoFormatPreferences?) {
        self.init(
            quality: preferences?.quality,
            container: preferences?.container,
            preferredVideoCodec: preferences?.preferredVideoCodec,
            superResolution: preferences?.superResolution,
            hdr: preferences?.hdr,
            isAudio: false
        )
    }
}

func describeMissingFormat(
    _ type: MediaType,
    _ formatOption: FormatSelector?,
    _ formats: [SabrFormat]
) -> String {
    let availableFormats = filterFormatsByType(formats, type == .audio).map {
        "\($0.itag)[qualityLabel=\($0.qualityLabel ?? $0.audioQuality ?? ""), mimeType=\($0.mimeType ?? ""), isVb=\($0.isVb ?? false), isDrc=\($0.isDrc ?? false)]"
    }.joined(separator: ", ")
    let available = availableFormats.isEmpty ? "none" : availableFormats

    if case .itag(let itag) = formatOption {
        return "no \(type.rawValue) format with itag \(itag) found (available \(type.rawValue) formats: \(available))"
    }
    if case .selector = formatOption {
        return "no \(type.rawValue) format matched the provided selector function (available \(type.rawValue) formats: \(available))"
    }

    return "no \(type.rawValue) format matched the given criteria (available \(type.rawValue) formats: \(available))"
}

func chooseFormat(
    _ formats: [SabrFormat],
    _ formatOption: FormatSelector?,
    _ preferences: FormatPreferences
) -> SabrFormat? {
    if formats.isEmpty { return nil }

    let typeFormats = filterFormatsByType(formats, preferences.isAudio)
    if typeFormats.isEmpty { return nil }

    if case .itag(let itag) = formatOption {
        return typeFormats.first { $0.itag == itag }
    }

    if case .format(let format) = formatOption {
        return format
    }

    if case .selector(let selector) = formatOption {
        return selector(typeFormats)
    }

    var filteredFormats = typeFormats

    if let language = preferences.language, !language.isEmpty, preferences.isAudio {
        filteredFormats = filteredFormats.filter { $0.language == language }
    }

    if let quality = preferences.quality {
        filteredFormats = filteredFormats.filter { format in
            preferences.isAudio
                ? format.audioQuality?.lowercased().contains(quality.lowercased()) ?? false
                : format.qualityLabel?.lowercased().contains(quality.lowercased()) ?? false
        }
    }

    if let container = preferences.container {
        filteredFormats = filteredFormats.filter { $0.mimeType?.contains(container.rawValue) ?? false }
    }

    if let voiceBoost = preferences.voiceBoost {
        filteredFormats = filteredFormats.filter { $0.isVb == voiceBoost }
    }

    if let dynamicRangeCompression = preferences.dynamicRangeCompression {
        filteredFormats = filteredFormats.filter { $0.isDrc == dynamicRangeCompression }
    }

    if let superResolution = preferences.superResolution {
        filteredFormats = filteredFormats.filter { $0.isSr == superResolution }
    }

    if let hdr = preferences.hdr {
        filteredFormats = filteredFormats.filter { $0.isHdr == hdr }
    }

    let preferredCodec = preferences.isAudio ? preferences.preferredAudioCodec?.rawValue : preferences.preferredVideoCodec?.rawValue

    return filteredFormats.enumerated().sorted { a, b in
        let preferenceDifference = (matchesCodec(b.element, preferredCodec) ? 1 : 0) - (matchesCodec(a.element, preferredCodec) ? 1 : 0)
        if preferenceDifference != 0 { return preferenceDifference < 0 }

        let difference = preferences.isAudio
            ? b.element.bitrate - a.element.bitrate
            : (b.element.height ?? 0) - (a.element.height ?? 0)
        if difference != 0 { return difference < 0 }

        return a.offset < b.offset
    }.first?.element
}

private func matchesCodec(_ format: SabrFormat, _ codec: String?) -> Bool {
    guard let codec else { return false }

    let codecMimeTypePrefixes: [String: [String]] = [
        "h264": ["avc1", "avc3"],
        "vp9": ["vp9", "vp09"],
        "av1": ["av01"],
        "aac": ["mp4a"],
        "opus": ["opus"]
    ]

    return codecMimeTypePrefixes[codec]?.contains { format.mimeType?.contains($0) ?? false } ?? false
}

private func filterFormatsByType(_ formats: [SabrFormat], _ isAudio: Bool) -> [SabrFormat] {
    return formats.filter { format in
        guard let mimeType = format.mimeType, !mimeType.isEmpty else { return false }
        return isAudio
            ? mimeType.contains("audio")
            : mimeType.contains("video")
    }
}

func buildSabrFormat(_ formatStream: FormatStream) -> SabrFormat {
    let transferCharacteristics = nonEmpty(formatStream.color_info?.transfer_characteristics) ?? formatStream.colorInfo?.transferCharacteristics ?? ""

    var format = SabrFormat(
        itag: formatStream.itag,
        lastModified: nonEmpty(formatStream.last_modified_ms) ?? formatStream.lastModified ?? "0",
        xtags: formatStream.xtags,
        mimeType: formatStream.mime_type ?? formatStream.mimeType,
        bitrate: formatStream.bitrate,
        height: formatStream.height,
        approxDurationMs: formatStream.approx_duration_ms ?? Int(formatStream.approxDurationMs ?? "0") ?? 0,
        fps: formatStream.fps,
        width: formatStream.width,
        audioTrackId: nonEmpty(formatStream.audio_track?.id) ?? formatStream.audioTrackId,
        quality: formatStream.quality,
        isHdr: transferCharacteristics.contains("SMPTEST2084") || transferCharacteristics.contains("ARIB_STD_B67")
    )

    format.audioQuality = nonEmpty(formatStream.audio_quality) ?? formatStream.audioQuality
    format.numChannels = formatStream.audio_channels ?? formatStream.audioChannels
    format.averageBitrate = formatStream.average_bitrate ?? formatStream.averageBitrate
    format.qualityLabel = nonEmpty(formatStream.quality_label) ?? formatStream.qualityLabel
    let contentLength = Int(formatStream.contentLength ?? "0") ?? 0
    format.contentLength = contentLength != 0 ? contentLength : formatStream.content_length
    format.targetDurationSec = formatStream.targetDurationSec ?? formatStream.target_duration_sec ?? formatStream.target_duration_dec
    format.hasAudio = !(formatStream.audioQuality ?? formatStream.audio_quality ?? "").isEmpty
    format.hasVideo = !(formatStream.qualityLabel ?? "").isEmpty && (formatStream.quality_label ?? "").isEmpty
    format.hasText = formatStream.captionTrack != nil || formatStream.caption_track != nil
    format.isVb = formatStream.isVb ?? formatStream.is_vb
    format.isSr = formatStream.isSr ?? formatStream.is_sr
    format.isDrc = formatStream.is_drc
    format.isAutoDubbed = formatStream.is_auto_dubbed
    format.isDescriptive = formatStream.is_descriptive
    format.isDubbed = formatStream.is_dubbed
    format.language = formatStream.language
    format.isOriginal = formatStream.is_original
    format.isSecondary = formatStream.is_secondary
    format.codecCode = CODEC_CODES[formatStream.itag]

    return format
}

private func nonEmpty(_ value: String?) -> String? {
    guard let value, !value.isEmpty else { return nil }
    return value
}

func createFormatKey(_ input: some CreateFormatKeyInput) throws -> String {
    for candidate in input.formatKeyCandidates where candidate.itag != nil || candidate.xtags != nil {
        let itag = candidate.itag.flatMap { $0 != 0 ? String($0) : nil } ?? ""
        return "\(itag):\(candidate.xtags ?? "")"
    }

    throw GoogleVideoError("Unsupported format type")
}

func createSegmentCacheKey(
    _ mediaHeader: MediaHeader,
    _ format: SabrFormat? = nil
) -> String {
    if mediaHeader.isInitializationSegment, let format {
        return "\(mediaHeader.itag):\(mediaHeader.xtags):\(format.contentLength.map(String.init) ?? ""):\(format.mimeType ?? "")"
    }
    return "\(mediaHeader.hasSegmentByteRangeStart && mediaHeader.segmentByteRangeStart != 0 ? String(mediaHeader.segmentByteRangeStart) : "0")-\(mediaHeader.itag)-\(mediaHeader.xtags)"
}

func createSegmentCacheKeyFromMetadata(
    _ requestMetadata: SabrRequestMetadata
) throws -> String {
    guard let byteRange = requestMetadata.byteRange, let format = requestMetadata.format else {
        throw GoogleVideoError("Invalid metadata: byteRange or format is missing")
    }

    var pseudoMediaHeader = MediaHeader()
    pseudoMediaHeader.itag = Int32(format.itag)
    pseudoMediaHeader.xtags = format.xtags ?? ""
    pseudoMediaHeader.segmentByteRangeStart = Int64(byteRange.start)
    pseudoMediaHeader.isInitializationSegment = requestMetadata.isInit ?? false

    return createSegmentCacheKey(
        pseudoMediaHeader,
        requestMetadata.isInit == true ? format : nil
    )
}

func getUniqueFormatId(_ format: SabrFormat) -> String {
    if let width = format.width, width != 0 {
        return String(format.itag)
    }

    var uidParts = [String(format.itag)]

    if let audioTrackId = format.audioTrackId, !audioTrackId.isEmpty {
        uidParts.append(audioTrackId)
    }

    if format.isDrc == true {
        uidParts.append("drc")
    }

    return uidParts.joined(separator: "-")
}

extension MediaHeader: CreateFormatKeyInput {
    var formatKeyCandidates: [(itag: Int?, xtags: String?)] {
        var candidates: [(itag: Int?, xtags: String?)] = []
        if hasFormatID { candidates.append(formatID.formatKeyCandidates[0]) }
        candidates.append((hasItag ? Int(itag) : nil, hasXtags ? xtags : nil))
        return candidates
    }
}

extension FormatInitializationMetadata: CreateFormatKeyInput {
    var formatKeyCandidates: [(itag: Int?, xtags: String?)] {
        return hasFormatID ? formatID.formatKeyCandidates : []
    }
}

extension FormatId: CreateFormatKeyInput {
    var formatKeyCandidates: [(itag: Int?, xtags: String?)] {
        return [(hasItag ? Int(itag) : nil, hasXtags ? xtags : nil)]
    }
}

extension SabrFormat: CreateFormatKeyInput {
    var formatKeyCandidates: [(itag: Int?, xtags: String?)] {
        return [(itag, xtags)]
    }
}

extension FormatId {
    init(_ format: SabrFormat) {
        self.init()
        itag = Int32(format.itag)
        if let lastModified = UInt64(format.lastModified) { self.lastModified = lastModified }
        if let xtags = format.xtags { self.xtags = xtags }
    }
}
