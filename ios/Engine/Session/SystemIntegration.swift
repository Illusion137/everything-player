import AVFoundation
import MediaPlayer
import UIKit

final class EPAudioSession {
  var onInterruption: ((_ began: Bool, _ shouldResume: Bool) -> Void)?
  var onOldDeviceUnavailable: (() -> Void)?
  private var tokens: [NSObjectProtocol] = []

  init() {
    let center = NotificationCenter.default
    let session = AVAudioSession.sharedInstance()
    tokens.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: session, queue: .main) { [weak self] note in
      guard let info = note.userInfo,
            let raw = info[AVAudioSessionInterruptionTypeKey] as? UInt,
            let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
      if type == .began {
        self?.onInterruption?(true, false)
      } else {
        let opts = AVAudioSession.InterruptionOptions(rawValue: info[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0)
        self?.onInterruption?(false, opts.contains(.shouldResume))
      }
    })
    tokens.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: session, queue: .main) { [weak self] note in
      guard let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
            AVAudioSession.RouteChangeReason(rawValue: raw) == .oldDeviceUnavailable else { return }
      self?.onOldDeviceUnavailable?()
    })
  }

  func configure() {
    try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, policy: .longFormAudio)
  }

  func activate() {
    try? AVAudioSession.sharedInstance().setActive(true)
  }
}

final class EPRemoteCommands {
  var handler: ((EPRemoteEvent) -> Void)?
  var isPlaying: () -> Bool = { false }
  private var registered: [(MPRemoteCommand, Any)] = []

  func configure(capabilities: Set<String>, forwardInterval: Double, backwardInterval: Double) {
    let center = MPRemoteCommandCenter.shared()
    registered.forEach { $0.0.removeTarget($0.1) }
    registered = []

    func bind(_ command: MPRemoteCommand, _ capability: String, _ make: @escaping (MPRemoteCommandEvent) -> EPRemoteEvent?) {
      let enabled = capabilities.contains(capability)
      command.isEnabled = enabled
      guard enabled else { return }
      let target = command.addTarget { [weak self] event in
        guard let self, let mapped = make(event) else { return .commandFailed }
        self.handler?(mapped)
        return .success
      }
      registered.append((command, target))
    }

    bind(center.playCommand, "play") { _ in .play }
    bind(center.pauseCommand, "pause") { _ in .pause }
    bind(center.stopCommand, "stop") { _ in .stop }
    bind(center.nextTrackCommand, "skip-to-next") { _ in .next }
    bind(center.previousTrackCommand, "skip-to-previous") { _ in .previous }
    bind(center.changePlaybackPositionCommand, "seek-to") { e in
      (e as? MPChangePlaybackPositionCommandEvent).map { .seek($0.positionTime) }
    }
    center.skipForwardCommand.preferredIntervals = [NSNumber(value: forwardInterval)]
    center.skipBackwardCommand.preferredIntervals = [NSNumber(value: backwardInterval)]
    bind(center.skipForwardCommand, "jump-forward") { e in
      .jumpForward((e as? MPSkipIntervalCommandEvent)?.interval ?? forwardInterval)
    }
    bind(center.skipBackwardCommand, "jump-backward") { e in
      .jumpBackward((e as? MPSkipIntervalCommandEvent)?.interval ?? backwardInterval)
    }
    bind(center.likeCommand, "like") { _ in .like }
    bind(center.dislikeCommand, "dislike") { _ in .dislike }
    bind(center.bookmarkCommand, "bookmark") { _ in .bookmark }

    let togglePlay = capabilities.contains("play") || capabilities.contains("pause")
    center.togglePlayPauseCommand.isEnabled = togglePlay
    if togglePlay {
      let target = center.togglePlayPauseCommand.addTarget { [weak self] _ in
        guard let self else { return .commandFailed }
        self.handler?(self.isPlaying() ? .pause : .play)
        return .success
      }
      registered.append((center.togglePlayPauseCommand, target))
    }
  }
}

final class EPNowPlaying {
  private var artworkURL: String?
  private var artwork: MPMediaItemArtwork?
  private var info: [String: Any] = [:]

  func setTrack(_ track: EPTrack?) {
    guard let track else {
      info = [:]
      artworkURL = nil
      artwork = nil
      MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
      return
    }
    info = [
      MPMediaItemPropertyTitle: track.title,
      MPMediaItemPropertyArtist: track.artist,
    ]
    if let album = track.album { info[MPMediaItemPropertyAlbumTitle] = album }
    if track.artwork != artworkURL {
      artworkURL = track.artwork
      artwork = nil
      loadArtwork(track.artwork)
    }
    if let artwork { info[MPMediaItemPropertyArtwork] = artwork }
    MPNowPlayingInfoCenter.default().nowPlayingInfo = info
  }

  func update(position: Double, duration: Double?, rate: Float, playing: Bool) {
    guard !info.isEmpty else { return }
    info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = position
    if let duration, duration > 0 { info[MPMediaItemPropertyPlaybackDuration] = duration }
    info[MPNowPlayingInfoPropertyPlaybackRate] = playing ? Double(rate) : 0
    info[MPNowPlayingInfoPropertyDefaultPlaybackRate] = Double(rate)
    MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    MPNowPlayingInfoCenter.default().playbackState = playing ? .playing : .paused
  }

  private func loadArtwork(_ urlString: String?) {
    guard let urlString, let url = URL(string: urlString) else { return }
    let apply: (UIImage) -> Void = { [weak self] image in
      DispatchQueue.main.async {
        guard let self, self.artworkURL == urlString else { return }
        let art = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
        self.artwork = art
        self.info[MPMediaItemPropertyArtwork] = art
        MPNowPlayingInfoCenter.default().nowPlayingInfo = self.info
      }
    }
    if url.isFileURL {
      if let image = UIImage(contentsOfFile: url.path) { apply(image) }
      return
    }
    URLSession.shared.dataTask(with: url) { data, _, _ in
      if let data, let image = UIImage(data: data) { apply(image) }
    }.resume()
  }
}
