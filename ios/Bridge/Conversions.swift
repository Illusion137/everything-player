import Foundation
import NitroModules

extension EPTrack {
  init(native t: NativeTrack) {
    self.init(
      id: t.id, title: t.title, artist: t.artist, album: t.album, artwork: t.artwork,
      duration: t.duration, startTime: t.startTime, endTime: t.endTime, url: t.url,
      sabr: t.sabr.map(EPSabrInfo.init(native:)), userAgent: t.userAgent,
      contentType: t.contentType, headers: t.headers ?? [:])
  }

  var native: NativeTrack {
    NativeTrack(
      id: id, title: title, artist: artist, album: album, artwork: artwork,
      duration: duration, startTime: startTime, endTime: endTime, url: url,
      sabr: sabr?.native, userAgent: userAgent, contentType: contentType,
      headers: headers.isEmpty ? nil : headers)
  }
}

extension EPSabrInfo {
  init(native s: NativeSabrInfo) {
    self.init(
      videoId: s.videoId, serverAbrStreamingUrl: s.serverAbrStreamingUrl,
      videoPlaybackUstreamerConfig: s.videoPlaybackUstreamerConfig,
      formats: s.formats.map(EPSabrFormat.init(native:)), poToken: s.poToken,
      clientName: Int(s.clientInfo.clientName), clientVersion: s.clientInfo.clientVersion,
      cookie: s.cookie, duration: s.duration)
  }

  var native: NativeSabrInfo {
    NativeSabrInfo(
      videoId: videoId, serverAbrStreamingUrl: serverAbrStreamingUrl,
      videoPlaybackUstreamerConfig: videoPlaybackUstreamerConfig,
      formats: formats.map(\.native), poToken: poToken,
      clientInfo: NativeSabrClientInfo(clientName: Double(clientName), clientVersion: clientVersion),
      cookie: cookie, duration: duration)
  }
}

extension EPSabrFormat {
  init(native f: NativeSabrFormat) {
    self.init(
      itag: Int(f.itag), lastModified: f.lastModified, xtags: f.xtags, mimeType: f.mimeType,
      bitrate: Int(f.bitrate), averageBitrate: f.averageBitrate.map { Int($0) },
      approxDurationMs: Int(f.approxDurationMs), contentLength: f.contentLength.map { Int($0) },
      width: f.width.map { Int($0) }, height: f.height.map { Int($0) }, fps: f.fps.map { Int($0) },
      quality: f.quality, qualityLabel: f.qualityLabel, audioQuality: f.audioQuality,
      audioSampleRate: f.audioSampleRate.map { Int($0) }, audioChannels: f.audioChannels.map { Int($0) },
      audioTrackId: f.audioTrackId, language: f.language, isDrc: f.isDrc, isVb: f.isVb, isSr: f.isSr,
      isHdr: f.isHdr, isDubbed: f.isDubbed, isAutoDubbed: f.isAutoDubbed,
      isDescriptive: f.isDescriptive, isSecondary: f.isSecondary, isOriginal: f.isOriginal)
  }

  var native: NativeSabrFormat {
    NativeSabrFormat(
      itag: Double(itag), lastModified: lastModified, xtags: xtags, mimeType: mimeType,
      bitrate: Double(bitrate), averageBitrate: averageBitrate.map(Double.init),
      approxDurationMs: Double(approxDurationMs), contentLength: contentLength.map(Double.init),
      width: width.map(Double.init), height: height.map(Double.init), fps: fps.map(Double.init),
      quality: quality, qualityLabel: qualityLabel, audioQuality: audioQuality,
      audioSampleRate: audioSampleRate.map(Double.init), audioChannels: audioChannels.map(Double.init),
      audioTrackId: audioTrackId, language: language, isDrc: isDrc, isVb: isVb, isSr: isSr,
      isHdr: isHdr, isDubbed: isDubbed, isAutoDubbed: isAutoDubbed,
      isDescriptive: isDescriptive, isSecondary: isSecondary, isOriginal: isOriginal)
  }
}

extension EPVideoQualityRange {
  init(native r: NativeVideoQualityRange) {
    self.init(minHeight: r.minHeight.map { Int($0) }, maxHeight: r.maxHeight.map { Int($0) }, maxBitrate: r.maxBitrate.map { Int($0) })
  }

  var native: NativeVideoQualityRange {
    NativeVideoQualityRange(minHeight: minHeight.map(Double.init), maxHeight: maxHeight.map(Double.init), maxBitrate: maxBitrate.map(Double.init))
  }
}

extension EPVideoQualityState {
  func native(trackId: String?) -> NativeVideoQualityState {
    NativeVideoQualityState(
      qualities: qualities.map {
        NativeVideoQuality(
          id: $0.id, width: $0.width.map(Double.init), height: $0.height.map(Double.init), fps: $0.fps,
          bitrate: Double($0.bitrate), label: $0.label, codec: $0.codec)
      },
      selectedId: selectedId, automatic: auto, trackId: trackId)
  }
}

extension EPError {
  var native: NativePlaybackError {
    NativePlaybackError(code: code.rawValue, message: message, trackId: trackId)
  }
}

extension EPRemoteEvent {
  var native: NativeRemoteEvent {
    func make(_ type: NativeRemoteEventType, position: Double? = nil, interval: Double? = nil, paused: Bool? = nil,
              permanent: Bool? = nil, id: String? = nil, index: Double? = nil, query: String? = nil) -> NativeRemoteEvent {
      NativeRemoteEvent(type: type, position: position, interval: interval, paused: paused, permanent: permanent, id: id, index: index, query: query)
    }
    switch self {
    case .play: return make(.remotePlay)
    case .pause: return make(.remotePause)
    case .stop: return make(.remoteStop)
    case .next: return make(.remoteNext)
    case .previous: return make(.remotePrevious)
    case let .seek(p): return make(.remoteSeek, position: p)
    case let .jumpForward(i): return make(.remoteJumpForward, interval: i)
    case let .jumpBackward(i): return make(.remoteJumpBackward, interval: i)
    case let .duck(paused, permanent): return make(.remoteDuck, paused: paused, permanent: permanent)
    case let .playId(id, index): return make(.remotePlayId, id: id, index: index.map(Double.init))
    case let .playSearch(q): return make(.remotePlaySearch, query: q)
    case let .skip(i): return make(.remoteSkip, index: Double(i))
    case .like: return make(.remoteLike)
    case .dislike: return make(.remoteDislike)
    case .bookmark: return make(.remoteBookmark)
    }
  }
}

extension EPDownloadRecord {
  var native: NativeDownload {
    var path: String?
    var audio: String?
    var video: String?
    switch EPDownloads.shared.localMedia(for: track) {
    case let .file(url)?:
      path = url.path
    case let .sabr(m)?:
      path = m.audioURL.path
      audio = m.audioURL.path
      video = m.videoURL?.path
    case nil:
      break
    }
    return NativeDownload(
      trackId: trackId,
      state: NativeDownloadState(fromString: state.rawValue) ?? .failed,
      progress: progress, bytesDownloaded: Double(bytesDownloaded), totalBytes: totalBytes.map(Double.init),
      localPath: path, audioPath: audio, videoPath: video, errorCode: errorCode, errorMessage: errorMessage, track: track.native)
  }
}

final class EPJSSabrCallbacks: EPSabrCallbackProvider {
  private let mint: (String) -> Promise<Promise<String>>
  private let reload: (String, NativeReloadPlaybackContext) -> Promise<Promise<NativeReloadPlayerResponse>>

  init(mint: @escaping (String) -> Promise<Promise<String>>,
       reload: @escaping (String, NativeReloadPlaybackContext) -> Promise<Promise<NativeReloadPlayerResponse>>) {
    self.mint = mint
    self.reload = reload
  }

  func mintPoToken(trackId: String) async throws -> Data {
    let encoded = try await mint(trackId).await().await()
    guard let data = Data(base64Encoded: encoded) else {
      throw EPError(.sabrCallbackFailed, "onMintPoToken returned invalid bytes")
    }
    return data
  }

  func reloadPlayerResponse(trackId: String, token: String?) async throws -> (serverAbrStreamingUrl: String, videoPlaybackUstreamerConfig: String) {
    let context = NativeReloadPlaybackContext(reloadPlaybackParams: NativeReloadPlaybackParams(token: token))
    let response = try await reload(trackId, context).await().await()
    return (response.serverAbrStreamingUrl, response.videoPlaybackUstreamerConfig)
  }
}
