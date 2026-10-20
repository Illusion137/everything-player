import NitroModules
import UIKit

final class HybridVideoSurface: HybridVideoSurfaceSpec {
  private let surface = EPVideoSurfaceView(frame: .zero)

  var view: UIView { surface }

  var resizeMode: NativeResizeMode? {
    didSet { surface.resizeMode = resizeMode?.stringValue ?? "contain" }
  }
}
