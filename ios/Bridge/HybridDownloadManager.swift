import Foundation
import NitroModules

final class HybridDownloadManager: HybridDownloadManagerSpec {
  private let downloads = EPDownloads.shared

  func download(track: NativeTrack, options: NativeDownloadOptions) throws -> Promise<NativeDownload> {
    let range = options.videoQuality.map(EPVideoQualityRange.init(native:)) ?? EPPlayerEngine.shared.getVideoQualityRange()
    let record = try downloads.download(EPTrack(native: track), includeVideo: options.includeVideo, videoQuality: range)
    return Promise.resolved(withResult: record.native)
  }

  func pause(trackId: String) throws { downloads.pause(trackId) }
  func resume(trackId: String) throws { downloads.resume(trackId) }
  func cancel(trackId: String) throws { downloads.cancel(trackId) }

  func remove(trackId: String) throws -> Promise<Void> {
    Promise.async { self.downloads.remove(trackId) }
  }

  func removeAll() throws -> Promise<Void> {
    Promise.async { self.downloads.removeAll() }
  }

  func getDownload(trackId: String) throws -> NativeDownload? { downloads.record(trackId)?.native }
  func getDownloads() throws -> [NativeDownload] { downloads.all().map(\.native) }

  func setOnDownloadChanged(callback: @escaping (NativeDownload) -> Void) throws {
    downloads.onChanged = { callback($0.native) }
  }
}
