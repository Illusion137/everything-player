import Foundation

enum EPHLSDownloader {
  struct Progress {
    var segmentsDone: Int
    var segmentsTotal: Int
    var bytes: Int64
  }

  private struct Job {
    var name: String
    var playlist: EPHLSMediaPlaylist
  }

  static func download(
    track: EPTrack, includeVideo: Bool, range: EPVideoQualityRange, folder: URL,
    progress: @escaping (Progress) -> Void
  ) async throws -> String {
    guard let raw = track.url, let url = URL(string: raw) else { throw EPError(.sourceError, "Invalid URL") }
    let loader = EPHLSLoader(headers: track.requestHeaders)
    let fm = FileManager.default
    try fm.createDirectory(at: folder, withIntermediateDirectories: true)

    var jobs: [Job] = []
    var variant: EPHLSVariant?
    switch try EPHLSParser.parse(try await loader.text(url), base: url) {
    case let .media(playlist):
      jobs.append(Job(name: "main", playlist: playlist))
    case let .master(master):
      let video = includeVideo ? range.pick(master.playableVideoVariants, height: { $0.height }, bitrate: { $0.bandwidth }) : nil
      guard let chosen = video ?? master.audioVariant else {
        throw EPError(.sourceError, "No downloadable H.264/AAC variant")
      }
      variant = chosen
      jobs.append(Job(name: "main", playlist: try await media(chosen.uri, loader)))
      if let audio = master.audioRendition(for: chosen)?.uri {
        jobs.append(Job(name: "audio", playlist: try await media(audio, loader)))
      }
    }
    for job in jobs {
      guard job.playlist.ended else { throw EPError(.sourceError, "Live HLS streams cannot be downloaded") }
      if job.playlist.segments.contains(where: { $0.key.map { $0.method != .aes128 } ?? false }) {
        throw EPError(.sourceError, "Unsupported HLS encryption for download")
      }
    }

    let total = jobs.reduce(0) { $0 + $1.playlist.segments.count }
    var done = 0
    var bytes: Int64 = 0
    for job in jobs {
      let dir = folder.appendingPathComponent(job.name, isDirectory: true)
      try fm.createDirectory(at: dir, withIntermediateDirectories: true)
      var maps: [EPHLSMap: String] = [:]
      var lines = [
        "#EXTM3U", "#EXT-X-VERSION:7", "#EXT-X-PLAYLIST-TYPE:VOD",
        "#EXT-X-TARGETDURATION:\(Int(job.playlist.targetDuration.rounded(.up)))", "#EXT-X-MEDIA-SEQUENCE:0",
      ]
      var lastMap: String?
      var lastDiscontinuity = job.playlist.segments.first?.discontinuity
      for (i, segment) in job.playlist.segments.enumerated() {
        try Task.checkCancellation()
        if let map = segment.map {
          if maps[map] == nil {
            let name = "\(job.name)/init-\(maps.count).mp4"
            let file = folder.appendingPathComponent(name)
            if !fm.fileExists(atPath: file.path) {
              try await loader.mapData(map, key: segment.key, sequence: segment.sequence).write(to: file, options: .atomic)
            }
            maps[map] = name
          }
          if maps[map] != lastMap {
            lastMap = maps[map]
            lines.append("#EXT-X-MAP:URI=\"\(lastMap!)\"")
          }
        }
        if segment.discontinuity != lastDiscontinuity {
          lastDiscontinuity = segment.discontinuity
          lines.append("#EXT-X-DISCONTINUITY")
        }
        let name = "\(job.name)/\(i).seg"
        let file = folder.appendingPathComponent(name)
        if let size = (try? fm.attributesOfItem(atPath: file.path))?[.size] as? Int64 {
          bytes += size
        } else {
          let data = try await loader.segmentData(segment)
          try data.write(to: file, options: .atomic)
          bytes += Int64(data.count)
        }
        lines.append("#EXTINF:\(segment.duration),")
        lines.append(name)
        done += 1
        progress(Progress(segmentsDone: done, segmentsTotal: total, bytes: bytes))
      }
      lines.append("#EXT-X-ENDLIST")
      try lines.joined(separator: "\n").write(to: folder.appendingPathComponent("\(job.name).m3u8"), atomically: true, encoding: .utf8)
    }

    guard let variant else { return "main.m3u8" }
    var master = ["#EXTM3U", "#EXT-X-VERSION:7"]
    var inf = "#EXT-X-STREAM-INF:BANDWIDTH=\(variant.bandwidth)"
    if !variant.codecs.isEmpty { inf += ",CODECS=\"\(variant.codecs.joined(separator: ","))\"" }
    if let w = variant.width, let h = variant.height { inf += ",RESOLUTION=\(w)x\(h)" }
    if jobs.contains(where: { $0.name == "audio" }) {
      master.append("#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID=\"audio\",NAME=\"audio\",DEFAULT=YES,AUTOSELECT=YES,URI=\"audio.m3u8\"")
      inf += ",AUDIO=\"audio\""
    }
    master.append(inf)
    master.append("main.m3u8")
    try master.joined(separator: "\n").write(to: folder.appendingPathComponent("master.m3u8"), atomically: true, encoding: .utf8)
    return "master.m3u8"
  }

  private static func media(_ url: URL, _ loader: EPHLSLoader) async throws -> EPHLSMediaPlaylist {
    guard case let .media(p) = try EPHLSParser.parse(try await loader.text(url), base: url) else {
      throw EPError(.sourceError, "Expected a media playlist")
    }
    return p
  }
}
