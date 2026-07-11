import AppKit
import Foundation
import NetworkExtension
import React
import SystemExtensions

/// The NeoTunnel packet-tunnel provider's bundle id — the system extension the
/// app installs, and the provider `NETunnelProviderManager` configures.
private let tunnelBundleId = "org.reactjs.native.NeoMac.NeoTunnel"

/// Installs and controls the neo system VPN (the NeoTunnel packet-tunnel
/// provider) via `NETunnelProviderManager`. Once connected, the OS routes ALL
/// of the Mac's traffic into the extension, which carries it to a peer exit node
/// through the neo Rust core.
///
/// Because the tunnel ships as a **system extension** (required for Developer ID
/// distribution outside the App Store), `connect` first activates that extension
/// via `OSSystemExtensionManager` — which may need one-time user approval in
/// System Settings — before configuring the VPN.
///
/// Events:
///  - `neo-vpn-state` { status }  where status is one of
///    invalid|disconnected|connecting|connected|reasserting|disconnecting
@objc(NeoVPN)
class NeoVPN: RCTEventEmitter {
  private var manager: NETunnelProviderManager?
  private var observer: NSObjectProtocol?
  private var hasListeners = false
  /// Held between an `OSSystemExtensionRequest` submission and its delegate
  /// callback, then invoked once with the activation outcome.
  private var activationCompletion: ((Result<Void, Error>) -> Void)?

  override static func requiresMainQueueSetup() -> Bool { false }
  override func supportedEvents() -> [String]! { ["neo-vpn-state"] }
  override func startObserving() { hasListeners = true }
  override func stopObserving() { hasListeners = false }

  private static func statusName(_ s: NEVPNStatus) -> String {
    switch s {
    case .invalid: return "invalid"
    case .disconnected: return "disconnected"
    case .connecting: return "connecting"
    case .connected: return "connected"
    case .reasserting: return "reasserting"
    case .disconnecting: return "disconnecting"
    @unknown default: return "unknown"
    }
  }

  private func emitState(_ status: NEVPNStatus) {
    if hasListeners {
      sendEvent(withName: "neo-vpn-state", body: ["status": NeoVPN.statusName(status)])
    }
  }

  /// Load our saved manager, or create one. There is a single neo VPN profile.
  private func loadManager(_ completion: @escaping (NETunnelProviderManager?, Error?) -> Void) {
    NETunnelProviderManager.loadAllFromPreferences { managers, error in
      if let error = error { completion(nil, error); return }
      let mgr = managers?.first ?? NETunnelProviderManager()
      completion(mgr, nil)
    }
  }

  private func observe(_ mgr: NETunnelProviderManager) {
    if let observer = observer { NotificationCenter.default.removeObserver(observer) }
    observer = NotificationCenter.default.addObserver(
      forName: .NEVPNStatusDidChange,
      object: mgr.connection,
      queue: .main
    ) { [weak self] _ in
      self?.emitState(mgr.connection.status)
    }
  }

  /// Install/refresh the VPN profile and start it.
  /// config: { identityBase64, mirrors: [String], witnesses: [String],
  ///           threshold?: Int, privacy?: "off"|"balanced"|"paranoid" }
  @objc(connect:resolver:rejecter:)
  func connect(
    _ config: NSDictionary,
    resolver resolve: @escaping RCTPromiseResolveBlock,
    rejecter reject: @escaping RCTPromiseRejectBlock
  ) {
    guard
      let identity = config["identityBase64"] as? String, !identity.isEmpty,
      let mirrors = config["mirrors"] as? [String], !mirrors.isEmpty,
      let witnesses = config["witnesses"] as? [String], !witnesses.isEmpty
    else {
      reject("E_CONFIG", "connect requires identityBase64, mirrors and witnesses", nil)
      return
    }
    let threshold = (config["threshold"] as? Int) ?? witnesses.count
    let privacy = (config["privacy"] as? String) ?? "balanced"

    // Ensure the packet-tunnel system extension is installed and approved, then
    // configure the VPN. First-time activation may need user approval in System
    // Settings; we surface that as a clear error and the user reconnects.
    activateSystemExtension { [weak self] result in
      guard let self else { return }
      switch result {
      case .failure(let error):
        if case NeoSystemExtensionError.needsApproval = error {
          reject(
            "E_SYSEXT_APPROVAL",
            "Approval needed: System Settings just opened at General \u{2192} Login "
              + "Items & Extensions. Under \u{201C}NeoMac Extensions\u{201D}, turn ON "
              + "the \u{201C}Network Extension\u{201D} toggle (unlock with your "
              + "password), click Done, then press Start Tunnel again.",
            nil)
        } else {
          reject("E_SYSEXT", "system extension activation failed: \(error.localizedDescription)", error)
        }
      case .success:
        self.configureAndStart(
          identity: identity, mirrors: mirrors, witnesses: witnesses,
          threshold: threshold, privacy: privacy, resolve: resolve, reject: reject)
      }
    }
  }

  /// Submit an activation request for the tunnel system extension. Completes
  /// with success once it's active, or `NeoSystemExtensionError.needsApproval`
  /// when the user must first approve it in System Settings.
  private func activateSystemExtension(_ completion: @escaping (Result<Void, Error>) -> Void) {
    let request = OSSystemExtensionRequest.activationRequest(
      forExtensionWithIdentifier: tunnelBundleId, queue: .main)
    request.delegate = self
    activationCompletion = completion
    OSSystemExtensionManager.shared.submitRequest(request)
  }

  /// Configure `NETunnelProviderManager` for the neo tunnel and start it.
  private func configureAndStart(
    identity: String, mirrors: [String], witnesses: [String],
    threshold: Int, privacy: String,
    resolve: @escaping RCTPromiseResolveBlock, reject: @escaping RCTPromiseRejectBlock
  ) {
    loadManager { [weak self] mgr, error in
      guard let self else { return }
      if let error = error { reject("E_LOAD", error.localizedDescription, error); return }
      guard let mgr = mgr else { reject("E_LOAD", "no VPN manager", nil); return }

      let proto = NETunnelProviderProtocol()
      // Must match the extension's bundle identifier.
      proto.providerBundleIdentifier = tunnelBundleId
      proto.serverAddress = mirrors.first ?? "neo"
      proto.providerConfiguration = [
        "identity": identity,
        "mirrors": mirrors,
        "witnesses": witnesses,
        "threshold": threshold,
        "privacy": privacy,
      ]

      mgr.localizedDescription = "neo"
      mgr.protocolConfiguration = proto
      mgr.isEnabled = true

      mgr.saveToPreferences { saveError in
        if let saveError = saveError {
          reject("E_SAVE", saveError.localizedDescription, saveError)
          return
        }
        // Reload so the saved config is applied before starting.
        mgr.loadFromPreferences { loadError in
          if let loadError = loadError {
            reject("E_RELOAD", loadError.localizedDescription, loadError)
            return
          }
          self.manager = mgr
          self.observe(mgr)
          do {
            try mgr.connection.startVPNTunnel()
            resolve(["started": true])
          } catch {
            reject("E_START", error.localizedDescription, error)
          }
        }
      }
    }
  }

  @objc(disconnect:rejecter:)
  func disconnect(
    _ resolve: @escaping RCTPromiseResolveBlock,
    rejecter reject: @escaping RCTPromiseRejectBlock
  ) {
    loadManager { mgr, error in
      if let error = error { reject("E_LOAD", error.localizedDescription, error); return }
      mgr?.connection.stopVPNTunnel()
      resolve(["stopped": true])
    }
  }

  @objc(status:rejecter:)
  func status(
    _ resolve: @escaping RCTPromiseResolveBlock,
    rejecter reject: @escaping RCTPromiseRejectBlock
  ) {
    loadManager { [weak self] mgr, error in
      if let error = error { reject("E_LOAD", error.localizedDescription, error); return }
      let status = mgr?.connection.status ?? .invalid
      if let mgr = mgr { self?.observe(mgr) }
      resolve(["status": NeoVPN.statusName(status), "installed": mgr?.protocolConfiguration != nil])
    }
  }

  override func invalidate() {
    if let observer = observer { NotificationCenter.default.removeObserver(observer) }
    super.invalidate()
  }
}

/// Activation outcome that isn't a hard failure: the extension is staged but the
/// user must approve it in System Settings before it can run.
enum NeoSystemExtensionError: Error { case needsApproval }

extension NeoVPN: OSSystemExtensionRequestDelegate {
  func request(
    _ request: OSSystemExtensionRequest,
    actionForReplacingExtension existing: OSSystemExtensionProperties,
    withExtension ext: OSSystemExtensionProperties
  ) -> OSSystemExtensionRequest.ReplacementAction {
    // Always install the version bundled in the app (handles upgrades).
    .replace
  }

  func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
    // Jump the user straight to the approval UI (System Settings › General ›
    // Login Items & Extensions) instead of making them navigate there by hand.
    DispatchQueue.main.async {
      if let url = URL(
        string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") {
        NSWorkspace.shared.open(url)
      }
    }
    let completion = activationCompletion
    activationCompletion = nil
    completion?(.failure(NeoSystemExtensionError.needsApproval))
  }

  func request(
    _ request: OSSystemExtensionRequest,
    didFinishWithResult result: OSSystemExtensionRequest.Result
  ) {
    let completion = activationCompletion
    activationCompletion = nil
    completion?(.success(()))
  }

  func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
    let completion = activationCompletion
    activationCompletion = nil
    completion?(.failure(error))
  }
}
