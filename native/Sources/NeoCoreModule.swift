import Foundation
import React

/// Identity operations, in-process through the Rust core (neo-ffi via UniFFI).
///
/// The identity file written here is byte-compatible with the CLI's
/// `neo identity generate` output (raw `NodeIdentity::to_bytes()`), so the
/// daemon started by `NeoDaemon` can consume it with `--identity`.
@objc(NeoCore)
class NeoCore: NSObject {
  @objc static func requiresMainQueueSetup() -> Bool { false }

  static var dataDir: URL {
    let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    return base.appendingPathComponent("neo", isDirectory: true)
  }

  static var identityURL: URL { dataDir.appendingPathComponent("identity.key") }

  @objc func constantsToExport() -> [AnyHashable: Any]! {
    return [
      "dataDir": NeoCore.dataDir.path,
      "identityPath": NeoCore.identityURL.path,
    ]
  }

  /// Load the identity at the default path, generating one on first launch.
  /// Resolves to `{ nodeId, path, created }`.
  @objc(ensureIdentity:rejecter:)
  func ensureIdentity(_ resolve: @escaping RCTPromiseResolveBlock,
                      rejecter reject: @escaping RCTPromiseRejectBlock) {
    DispatchQueue.global(qos: .userInitiated).async {
      do {
        let fm = FileManager.default
        try fm.createDirectory(at: NeoCore.dataDir, withIntermediateDirectories: true)
        let url = NeoCore.identityURL

        var created = false
        var secret: Data
        if fm.fileExists(atPath: url.path) {
          secret = try Data(contentsOf: url)
        } else {
          secret = generateIdentity()
          guard !secret.isEmpty else {
            reject("E_RNG", "the OS RNG was unavailable while generating an identity", nil)
            return
          }
          try secret.write(to: url, options: .atomic)
          try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
          created = true
        }

        guard let nodeId = identityNodeId(secret: secret) else {
          reject("E_IDENTITY", "\(url.path) does not contain a valid neo identity", nil)
          return
        }
        resolve(["nodeId": nodeId, "path": url.path, "created": created])
      } catch {
        reject("E_IDENTITY", "identity setup failed: \(error.localizedDescription)", error)
      }
    }
  }

  /// The identity secret, base64-encoded, for handing to the VPN tunnel config.
  /// Kept separate from `ensureIdentity` so the raw secret is only moved when a
  /// caller explicitly needs it (e.g. to start the tunnel).
  @objc(identitySecretBase64:rejecter:)
  func identitySecretBase64(_ resolve: @escaping RCTPromiseResolveBlock,
                            rejecter reject: @escaping RCTPromiseRejectBlock) {
    DispatchQueue.global(qos: .userInitiated).async {
      let url = NeoCore.identityURL
      guard let secret = try? Data(contentsOf: url) else {
        reject("E_IDENTITY", "no identity at \(url.path) — call ensureIdentity first", nil)
        return
      }
      resolve(secret.base64EncodedString())
    }
  }
}
