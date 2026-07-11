import AppKit
import Foundation
import React

/// Window sizing from JS, so panes can collapse the window itself
/// (e.g. the log drawer opening/closing off the right edge).
@objc(NeoWindow)
class NeoWindow: NSObject {
  @objc static func requiresMainQueueSetup() -> Bool { false }

  /// Pin every layer to the window's backing scale and mark it for redraw, so
  /// text re-rasterizes at 2x rather than staying at a stale 1x.
  private func resyncBackingScale(_ window: NSWindow) {
    guard let content = window.contentView else { return }
    let scale = window.backingScaleFactor
    func walk(_ view: NSView) {
      view.layer?.contentsScale = scale
      view.needsDisplay = true
      view.subviews.forEach(walk)
    }
    walk(content)
  }

  /// A programmatic `setFrame` leaves the React (Fabric) surface rendered at 1x —
  /// blurry on Retina — until a *real* resize re-tiles it. Poking layer scale or
  /// the live-resize hooks isn't enough (that regressed build-to-build). So we
  /// replay an actual 1pt size change through AppKit across runloop turns — grow,
  /// then settle back — which is exactly what a user's drag does, and it sticks.
  /// The 1pt bounce is imperceptible, and the JS side's dead-band ignores it.
  private func resyncAfterResize(_ window: NSWindow) {
    resyncBackingScale(window)
    DispatchQueue.main.async { [weak self, weak window] in
      guard let self = self, let window = window else { return }
      let target = window.frame
      var bumped = target
      bumped.size.height += 1
      bumped.origin.y -= 1  // keep the title bar visually fixed
      window.setFrame(bumped, display: true)
      self.resyncBackingScale(window)
      DispatchQueue.main.async { [weak self, weak window] in
        guard let self = self, let window = window else { return }
        window.setFrame(target, display: true)
        self.resyncBackingScale(window)
      }
    }
  }

  /// Set the main window's title bar text. RN-macOS creates the window
  /// programmatically (not in the storyboard), so the title is set from JS.
  @objc(setTitle:resolver:rejecter:)
  func setTitle(
    _ title: String,
    resolver resolve: @escaping RCTPromiseResolveBlock,
    rejecter reject: @escaping RCTPromiseRejectBlock
  ) {
    DispatchQueue.main.async {
      guard
        let window = NSApp.mainWindow
          ?? NSApp.windows.first(where: { $0.isVisible && !($0 is NSPanel) })
      else {
        reject("E_WINDOW", "no visible window to title", nil)
        return
      }
      window.title = title
      resolve(title)
    }
  }

  /// Resize the window's content area to `height` points, anchored at the top
  /// edge so the window grows/shrinks downward (the title bar stays put). Width
  /// is unchanged; the result is clamped to the screen's visible frame.
  @objc(setContentHeight:animate:resolver:rejecter:)
  func setContentHeight(
    _ height: Double,
    animate: Bool,
    resolver resolve: @escaping RCTPromiseResolveBlock,
    rejecter reject: @escaping RCTPromiseRejectBlock
  ) {
    DispatchQueue.main.async {
      guard
        let window = NSApp.mainWindow
          ?? NSApp.windows.first(where: { $0.isVisible && !($0 is NSPanel) })
      else {
        reject("E_WINDOW", "no visible window to resize", nil)
        return
      }

      var content = window.contentRect(forFrameRect: window.frame)
      var frame = window.frameRect(forContentRect: content)
      // macOS origin is bottom-left; keep the top edge fixed by moving origin.y.
      let top = frame.origin.y + frame.height
      content.size.height = max(height.rounded(), 0)
      var newFrame = window.frameRect(forContentRect: content)
      newFrame.origin.x = frame.origin.x

      if let visible = window.screen?.visibleFrame {
        newFrame.size.height = min(newFrame.height, visible.height)
      }
      newFrame.origin.y = top - newFrame.height
      if let visible = window.screen?.visibleFrame, newFrame.origin.y < visible.minY {
        newFrame.origin.y = visible.minY
      }
      frame = newFrame
      // Pin the window to the pixel grid: a fractional origin renders the whole
      // content on half-pixel boundaries → blurry text until a manual resize.
      frame.origin.x = frame.origin.x.rounded()
      frame.origin.y = frame.origin.y.rounded()

      window.setFrame(frame, display: true, animate: animate)
      self.resyncAfterResize(window)
      resolve(Double(window.contentRect(forFrameRect: window.frame).height))
    }
  }

  /// Resize the window's content area to `width` points, anchored at the
  /// top-left corner so the window grows/shrinks to the right. Height is
  /// unchanged; the result is clamped to the screen's visible frame.
  @objc(setContentWidth:animate:resolver:rejecter:)
  func setContentWidth(
    _ width: Double,
    animate: Bool,
    resolver resolve: @escaping RCTPromiseResolveBlock,
    rejecter reject: @escaping RCTPromiseRejectBlock
  ) {
    DispatchQueue.main.async {
      guard
        let window = NSApp.mainWindow
          ?? NSApp.windows.first(where: { $0.isVisible && !($0 is NSPanel) })
      else {
        reject("E_WINDOW", "no visible window to resize", nil)
        return
      }

      var content = window.contentRect(forFrameRect: window.frame)
      content.size.width = max(width.rounded(), 0)
      var frame = window.frameRect(forContentRect: content)

      if let visible = window.screen?.visibleFrame {
        if frame.maxX > visible.maxX {
          frame.origin.x = max(visible.minX, visible.maxX - frame.width)
        }
        frame.size.width = min(frame.width, visible.width)
      }
      // Pin to the pixel grid (see setContentHeight) so text stays sharp.
      frame.origin.x = frame.origin.x.rounded()
      frame.origin.y = frame.origin.y.rounded()

      window.setFrame(frame, display: true, animate: animate)
      self.resyncAfterResize(window)
      resolve(Double(window.contentRect(forFrameRect: window.frame).width))
    }
  }
}
