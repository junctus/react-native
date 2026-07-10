import AppKit
import Foundation
import React

/// Window sizing from JS, so panes can collapse the window itself
/// (e.g. the log drawer opening/closing off the right edge).
@objc(NeoWindow)
class NeoWindow: NSObject {
  @objc static func requiresMainQueueSetup() -> Bool { false }

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
      content.size.height = max(height, 0)
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

      window.setFrame(frame, display: true, animate: animate)
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
      content.size.width = max(width, 0)
      var frame = window.frameRect(forContentRect: content)

      if let visible = window.screen?.visibleFrame {
        if frame.maxX > visible.maxX {
          frame.origin.x = max(visible.minX, visible.maxX - frame.width)
        }
        frame.size.width = min(frame.width, visible.width)
      }

      window.setFrame(frame, display: true, animate: animate)
      resolve(Double(window.contentRect(forFrameRect: window.frame).width))
    }
  }
}
