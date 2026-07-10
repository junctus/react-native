import AppKit
import Foundation
import React

/// A macOS menu-bar (status bar) item with Start/Stop Tunnel controls. The tunnel
/// logic lives in JS (identity, mirrors, witnesses, relay), so this only surfaces
/// the menu: clicks are emitted to JS as `neo-menu-action`, and JS pushes the VPN
/// status back via `setStatus` so the menu can reflect and gate the actions.
///
/// Events:
///  - `neo-menu-action` { action: "start" | "stop" }
@objc(NeoStatusBar)
class NeoStatusBar: RCTEventEmitter {
  private var statusItem: NSStatusItem?
  private var status = "disconnected"
  private var hasListeners = false

  override static func requiresMainQueueSetup() -> Bool { false }
  override func supportedEvents() -> [String]! { ["neo-menu-action"] }
  override func startObserving() { hasListeners = true }
  override func stopObserving() { hasListeners = false }

  /// Create the menu-bar item (idempotent). Call once from JS on launch.
  @objc(install:rejecter:)
  func install(
    _ resolve: @escaping RCTPromiseResolveBlock,
    rejecter reject: @escaping RCTPromiseRejectBlock
  ) {
    DispatchQueue.main.async {
      if self.statusItem == nil {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
          if let img = NSImage(
            systemSymbolName: "shield.lefthalf.filled",
            accessibilityDescription: "Junctus Neo"
          ) {
            img.isTemplate = true
            button.image = img
          } else {
            // Guaranteed-visible fallback if the SF Symbol is unavailable.
            button.title = "◍"
          }
        }
        self.statusItem = item
        self.rebuildMenu()
        NSLog("[NeoStatusBar] menu-bar item installed")
      }
      resolve(true)
    }
  }

  /// Update the menu-bar item to reflect the current VPN status (one of
  /// invalid|disconnected|connecting|connected|reasserting|disconnecting).
  @objc(setStatus:resolver:rejecter:)
  func setStatus(
    _ status: String,
    resolver resolve: @escaping RCTPromiseResolveBlock,
    rejecter reject: @escaping RCTPromiseRejectBlock
  ) {
    DispatchQueue.main.async {
      self.status = status
      self.rebuildMenu()
      // Tint the icon green while tunneled, plain otherwise.
      self.statusItem?.button?.contentTintColor =
        status == "connected" ? NSColor.systemGreen : nil
      resolve(true)
    }
  }

  private func isConnected() -> Bool { status == "connected" }
  private func isBusy() -> Bool {
    ["connecting", "disconnecting", "reasserting"].contains(status)
  }

  private func statusTitle() -> String {
    switch status {
    case "connected": return "● All traffic tunneled"
    case "connecting": return "○ Connecting…"
    case "disconnecting": return "○ Disconnecting…"
    case "reasserting": return "○ Reconnecting…"
    default: return "○ Not tunneled"
    }
  }

  private func rebuildMenu() {
    guard let item = statusItem else { return }
    let menu = NSMenu()

    let header = NSMenuItem(title: statusTitle(), action: nil, keyEquivalent: "")
    header.isEnabled = false
    menu.addItem(header)
    menu.addItem(.separator())

    let start = NSMenuItem(
      title: "Start Tunnel", action: #selector(startAction), keyEquivalent: "")
    start.target = self
    start.isEnabled = !isConnected() && !isBusy()
    menu.addItem(start)

    let stop = NSMenuItem(
      title: "Stop Tunnel", action: #selector(stopAction), keyEquivalent: "")
    stop.target = self
    stop.isEnabled = isConnected() || isBusy()
    menu.addItem(stop)

    menu.addItem(.separator())
    let show = NSMenuItem(
      title: "Show Junctus Neo", action: #selector(showAction), keyEquivalent: "")
    show.target = self
    menu.addItem(show)
    let quit = NSMenuItem(
      title: "Quit Junctus Neo", action: #selector(quitAction), keyEquivalent: "q")
    quit.target = self
    menu.addItem(quit)

    item.menu = menu
  }

  @objc private func startAction() { emitAction("start") }
  @objc private func stopAction() { emitAction("stop") }

  @objc private func showAction() {
    NSApp.activate(ignoringOtherApps: true)
    // Find the app's titled window whether or not it's currently visible (it's
    // kept alive across close), and bring it to the front. Fall back to the
    // reopen path if no window object exists at all.
    if let window = NSApp.windows.first(where: {
      !($0 is NSPanel) && $0.styleMask.contains(.titled)
    }) {
      window.makeKeyAndOrderFront(nil)
    } else {
      _ = NSApp.delegate?.applicationShouldHandleReopen?(NSApp, hasVisibleWindows: false)
    }
  }

  @objc private func quitAction() { NSApp.terminate(nil) }

  private func emitAction(_ action: String) {
    if hasListeners { sendEvent(withName: "neo-menu-action", body: ["action": action]) }
  }
}
