import AVFoundation
import QuartzCore
import UIKit

protocol EPVideoFrameSource: AnyObject {
  func pixelBuffer(forHostTime hostTime: CFTimeInterval) -> CVPixelBuffer?
}

final class EPVideoHub {
  static let shared = EPVideoHub()

  private let surfaces = NSHashTable<EPVideoSurfaceView>.weakObjects()
  private weak var source: EPVideoFrameSource?
  private var displayLink: CADisplayLink?
  private var lastFrame: CVPixelBuffer?

  func setSource(_ newSource: EPVideoFrameSource?) {
    onMain {
      if self.source === newSource { return }
      self.source = newSource
      self.lastFrame = nil
      if newSource == nil { self.surfaces.allObjects.forEach { $0.display(nil) } }
      self.updateDisplayLink()
    }
  }

  func clearSourceIfCurrent(_ candidate: EPVideoFrameSource) {
    onMain {
      if self.source === candidate { self.setSource(nil) }
    }
  }

  func add(_ surface: EPVideoSurfaceView) {
    surfaces.add(surface)
    surface.display(lastFrame)
    updateDisplayLink()
  }

  func remove(_ surface: EPVideoSurfaceView) {
    surfaces.remove(surface)
    updateDisplayLink()
  }

  private func updateDisplayLink() {
    let needed = source != nil && surfaces.count > 0
    if needed && displayLink == nil {
      let link = CADisplayLink(target: DisplayLinkProxy(self), selector: #selector(DisplayLinkProxy.tick(_:)))
      link.add(to: .main, forMode: .common)
      displayLink = link
    } else if !needed, let link = displayLink {
      link.invalidate()
      displayLink = nil
    }
  }

  fileprivate func tick(_ link: CADisplayLink) {
    guard let source else { return }
    let visible = surfaces.allObjects.filter { $0.isVisibleForVideo }
    guard !visible.isEmpty else { return }
    guard let frame = source.pixelBuffer(forHostTime: link.targetTimestamp) else { return }
    lastFrame = frame
    visible.forEach { $0.display(frame) }
  }

  private final class DisplayLinkProxy {
    weak var hub: EPVideoHub?
    init(_ hub: EPVideoHub) { self.hub = hub }
    @objc func tick(_ link: CADisplayLink) { hub?.tick(link) }
  }
}

final class EPVideoSurfaceView: UIView {
  private let displayLayer = AVSampleBufferDisplayLayer()
  private var formatDescription: CMVideoFormatDescription?

  var resizeMode: String = "contain" {
    didSet { applyResizeMode() }
  }

  override init(frame: CGRect) {
    super.init(frame: frame)
    backgroundColor = .black
    clipsToBounds = true
    displayLayer.videoGravity = .resizeAspect
    layer.addSublayer(displayLayer)
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

  override func layoutSubviews() {
    super.layoutSubviews()
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    displayLayer.frame = bounds
    CATransaction.commit()
  }

  override func didMoveToWindow() {
    super.didMoveToWindow()
    if window != nil { EPVideoHub.shared.add(self) } else { EPVideoHub.shared.remove(self) }
  }

  var isVisibleForVideo: Bool { window != nil && !isHidden && alpha > 0 && bounds.width > 0 }

  func display(_ buffer: CVPixelBuffer?) {
    guard let buffer else {
      displayLayer.flushAndRemoveImage()
      return
    }
    if formatDescription == nil || !CMVideoFormatDescriptionMatchesImageBuffer(formatDescription!, imageBuffer: buffer) {
      formatDescription = nil
      CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: buffer, formatDescriptionOut: &formatDescription)
    }
    guard let formatDescription else { return }
    var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
    var sample: CMSampleBuffer?
    guard CMSampleBufferCreateReadyWithImageBuffer(
      allocator: kCFAllocatorDefault, imageBuffer: buffer, formatDescription: formatDescription,
      sampleTiming: &timing, sampleBufferOut: &sample) == noErr, let sample else { return }
    if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true),
       CFArrayGetCount(attachments) > 0 {
      let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
      CFDictionarySetValue(dict, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                           Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
    }
    if displayLayer.status == .failed { displayLayer.flush() }
    displayLayer.enqueue(sample)
  }

  private func applyResizeMode() {
    switch resizeMode {
    case "cover": displayLayer.videoGravity = .resizeAspectFill
    case "stretch": displayLayer.videoGravity = .resize
    default: displayLayer.videoGravity = .resizeAspect
    }
  }
}
