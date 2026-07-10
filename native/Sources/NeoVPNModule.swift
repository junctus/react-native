import Foundation
import NetworkExtension
import React

/// Installs and controls the neo system VPN (the NeoTunnel packet-tunnel
/// provider) via `NETunnelProviderManager`. Once connected, the OS routes ALL
/// of the Mac's traffic into the extension, which carries it to a peer exit node
/// through the neo Rust core.
///
/// Events:
///  - `neo-vpn-state` { status }  where status is one of
///    invalid|disconnected|connecting|connected|reasserting|disconnecting
@objc(NeoVPN)
class NeoVPN: RCTEventEmitter {
  private var manager: NETunnelProviderManager?
  private var observer: NSObjectProtocol?
  private var hasListeners = false

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
  ///           threshold?: Int, hops?: Int }
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
    let hops = (config["hops"] as? Int) ?? 2

    loadManager { [weak self] mgr, error in
      guard let self else { return }
      if let error = error { reject("E_LOAD", error.localizedDescription, error); return }
      guard let mgr = mgr else { reject("E_LOAD", "no VPN manager", nil); return }

      let proto = NETunnelProviderProtocol()
      // Must match the extension's bundle identifier.
      proto.providerBundleIdentifier = "org.reactjs.native.NeoMac.NeoTunnel"
      proto.serverAddress = mirrors.first ?? "neo"
      proto.providerConfiguration = [
        "identity": identity,
        "mirrors": mirrors,
        "witnesses": witnesses,
        "threshold": threshold,
        "hops": hops,
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
