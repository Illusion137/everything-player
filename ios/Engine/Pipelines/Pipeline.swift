import Foundation

enum EPPipelineStatus: Equatable {
  case idle
  case loading
  case buffering
  case ready
  case playing
  case ended
  case failed(String)
}

protocol EPPipelineDelegate: AnyObject {
  func pipeline(_ pipeline: EPPipeline, didChange status: EPPipelineStatus)
  func pipeline(_ pipeline: EPPipeline, didFail error: EPError)
  func pipelineDidUpdateDuration(_ pipeline: EPPipeline)
  func pipelineDidChangeVideoQuality(_ pipeline: EPPipeline)
}

protocol EPPipeline: AnyObject {
  var track: EPTrack { get }
  var delegate: EPPipelineDelegate? { get set }
  var status: EPPipelineStatus { get }
  var currentTime: Double { get }
  var mediaDuration: Double? { get }
  var bufferedTime: Double { get }
  var volume: Float { get set }
  var rate: Float { get set }
  var videoSource: EPVideoFrameSource? { get }
  var videoQuality: EPVideoQualityState { get }

  func load(at position: Double)
  func play()
  func pause()
  func seek(to seconds: Double)
  func teardown()
  func setVideoQuality(_ id: String?, range: EPVideoQualityRange) throws
}

protocol EPSabrCallbackProvider: AnyObject {
  func mintPoToken(trackId: String) async throws -> Data
  func reloadPlayerResponse(trackId: String, token: String?) async throws -> (serverAbrStreamingUrl: String, videoPlaybackUstreamerConfig: String)
}

func epWithTimeout<T>(_ ms: Double, _ what: String, _ operation: @escaping () async throws -> T) async throws -> T {
  try await withThrowingTaskGroup(of: T.self) { group in
    group.addTask { try await operation() }
    group.addTask {
      try await Task.sleep(nanoseconds: UInt64(max(1, ms) * 1_000_000))
      throw EPError(.sabrCallbackFailed, "\(what) timed out after \(Int(ms))ms")
    }
    guard let result = try await group.next() else {
      throw EPError(.sabrCallbackFailed, "\(what) produced no result")
    }
    group.cancelAll()
    return result
  }
}
