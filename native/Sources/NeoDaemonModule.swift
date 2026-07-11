import Foundation
import React

/// Manages the `neo` daemon binary: a long-lived client process
/// (`neo run`) plus one-shot commands (`snapshot`, `send`, …).
///
/// Events:
///  - `neo-log`   { stream: "stdout"|"stderr", line }
///  - `neo-state` { running, exitCode? }
@objc(NeoDaemon)
class NeoDaemon: RCTEventEmitter {
  private let queue = DispatchQueue(label: "neo.daemon")
  private var process: Process?
  private var hasListeners = false
  private var stdoutRemainder = Data()
  private var stderrRemainder = Data()

  override static func requiresMainQueueSetup() -> Bool { false }
  override func supportedEvents() -> [String]! { ["neo-log", "neo-state"] }
  override func startObserving() { hasListeners = true }
  override func stopObserving() { hasListeners = false }

  private func emit(_ name: String, _ body: [String: Any]) {
    if hasListeners { sendEvent(withName: name, body: body) }
  }

  /// The daemon binary, in preference order: an explicit path from JS, the
  /// NEO_BIN environment variable, the copy bundled in the app's Resources,
  /// then common install locations.
  private func resolveBinary(_ explicit: String?) -> String? {
    var candidates: [String] = []
    if let explicit, !explicit.isEmpty { candidates.append(explicit) }
    if let env = ProcessInfo.processInfo.environment["NEO_BIN"] { candidates.append(env) }
    if let bundled = Bundle.main.url(forResource: "neo", withExtension: nil) {
      candidates.append(bundled.path)
    }
    candidates.append("/opt/homebrew/bin/neo")
    candidates.append("/usr/local/bin/neo")
    candidates.append(NSHomeDirectory() + "/Code/neo/target/release/neo")
    return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
  }

  /// The primary physical IPv4 interface (e.g. `en0`), skipping loopback and
  /// virtual/tunnel interfaces (utun/ppp/awdl/…). Used to scope a relay's own
  /// sockets so they bypass the neo tunnel's default route. Detected *before* the
  /// tunnel comes up, so the physical interface still owns the default route.
  private func primaryPhysicalInterface() -> String? {
    var addrsPtr: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&addrsPtr) == 0 else { return nil }
    defer { freeifaddrs(addrsPtr) }

    let excluded = ["utun", "ppp", "ipsec", "awdl", "llw", "bridge", "gif", "stf", "tap", "tun"]
    var candidates: [String] = []
    var ptr = addrsPtr
    while let cur = ptr {
      let flags = Int32(cur.pointee.ifa_flags)
      let name = String(cString: cur.pointee.ifa_name)
      if let sa = cur.pointee.ifa_addr,
        sa.pointee.sa_family == UInt8(AF_INET),
        flags & IFF_UP != 0,
        flags & IFF_RUNNING != 0,
        flags & IFF_LOOPBACK == 0,
        !excluded.contains(where: { name.hasPrefix($0) }),
        !candidates.contains(name)
      {
        candidates.append(name)
      }
      ptr = cur.pointee.ifa_next
    }
    // Prefer en0, then any other ethernet/wifi (en*), then any candidate.
    return candidates.first(where: { $0 == "en0" })
      ?? candidates.first(where: { $0.hasPrefix("en") })
      ?? candidates.first
  }

  private func makeProcess(binPath: String, args: [String], env: [String: String]) -> Process {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: binPath)
    p.arguments = args
    p.currentDirectoryURL = NeoCore.dataDir
    var environment = ProcessInfo.processInfo.environment
    env.forEach { environment[$0] = $1 }
    p.environment = environment
    return p
  }

  /// Kill leftover `neo` processes from a previous app run (orphaned when the app
  /// is force-quit or crashes — macOS reparents children to launchd rather than
  /// killing them). Matched by our binary path so it only touches our own daemon,
  /// then a short wait so the OS releases the listener port before we re-bind.
  private func reapOrphans(binPath: String) {
    let pkill = Process()
    pkill.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
    pkill.arguments = ["-f", binPath]  // -f: match against the full argv
    do {
      try pkill.run()
      pkill.waitUntilExit()
    } catch {
      return  // pkill unavailable; start() will surface any bind error itself
    }
    // pkill exits 0 only when it signalled at least one match — wait only then.
    if pkill.terminationStatus == 0 { usleep(300_000) }
  }

  private func drainLines(_ handle: FileHandle, remainder: inout Data, stream: String) {
    remainder.append(handle.availableData)
    while let nl = remainder.firstIndex(of: 0x0A) {
      let lineData = remainder.prefix(upTo: nl)
      remainder.removeSubrange(...nl)
      if let line = String(data: lineData, encoding: .utf8), !line.isEmpty {
        emit("neo-log", ["stream": stream, "line": line])
      }
    }
  }

  /// Start the long-lived client: `neo run` (zero-config discovery).
  /// config: { binPath?, mirrors?: string[], witnesses?: string[],
  ///           identityPath?, extraArgs?: string[], env?: {..} }
  @objc(start:resolver:rejecter:)
  func start(_ config: NSDictionary,
             resolver resolve: @escaping RCTPromiseResolveBlock,
             rejecter reject: @escaping RCTPromiseRejectBlock) {
    queue.async {
      if let existing = self.process, existing.isRunning {
        reject("E_RUNNING", "the neo daemon is already running (pid \(existing.processIdentifier))", nil)
        return
      }
      guard let binPath = self.resolveBinary(config["binPath"] as? String) else {
        reject("E_NO_BINARY", "no neo binary found — build one with scripts/build-rust.sh or set NEO_BIN", nil)
        return
      }

      // Reap an orphaned neo process from a previous run before (re)starting.
      // A force-quit or crash leaves the relay child alive holding its listener
      // port, so a fresh start fails with "Address already in use". We only reach
      // here when our own tracked process isn't running (checked above), so any
      // surviving neo process is an orphan and safe to kill.
      self.reapOrphans(binPath: binPath)

      do {
        try FileManager.default.createDirectory(at: NeoCore.dataDir, withIntermediateDirectories: true)
      } catch {
        reject("E_DATADIR", "could not create data dir: \(error.localizedDescription)", error)
        return
      }

      var args = ["run"]
      let identityPath = (config["identityPath"] as? String) ?? NeoCore.identityURL.path
      args += ["--identity", identityPath]
      (config["mirrors"] as? [String])?.forEach { args += ["--mirror", $0] }
      (config["witnesses"] as? [String])?.forEach { args += ["--witness", $0] }
      (config["extraArgs"] as? [String])?.forEach { args.append($0) }

      // Scope the node's sockets to the physical interface so they aren't pulled
      // into a default-route VPN (e.g. our own tunnel running alongside a relay).
      if (config["scopeInterface"] as? Bool) == true {
        if let iface = self.primaryPhysicalInterface() {
          args += ["--net-interface", iface]
        } else {
          self.emit("neo-log", [
            "stream": "stderr",
            "line": "could not detect a physical interface; relay sockets not scoped",
          ])
        }
      }

      let env = (config["env"] as? [String: String]) ?? [:]
      let p = self.makeProcess(binPath: binPath, args: args, env: env)

      let out = Pipe(), err = Pipe()
      p.standardOutput = out
      p.standardError = err
      self.stdoutRemainder = Data()
      self.stderrRemainder = Data()
      out.fileHandleForReading.readabilityHandler = { [weak self] h in
        self?.queue.async { self.map { $0.drainLines(h, remainder: &$0.stdoutRemainder, stream: "stdout") } }
      }
      err.fileHandleForReading.readabilityHandler = { [weak self] h in
        self?.queue.async { self.map { $0.drainLines(h, remainder: &$0.stderrRemainder, stream: "stderr") } }
      }
      p.terminationHandler = { [weak self] proc in
        out.fileHandleForReading.readabilityHandler = nil
        err.fileHandleForReading.readabilityHandler = nil
        self?.queue.async {
          self?.process = nil
          self?.emit("neo-state", ["running": false, "exitCode": Int(proc.terminationStatus)])
        }
      }

      do {
        try p.run()
      } catch {
        reject("E_SPAWN", "failed to start \(binPath): \(error.localizedDescription)", error)
        return
      }
      self.process = p
      self.emit("neo-state", ["running": true])
      resolve(["pid": Int(p.processIdentifier), "binPath": binPath, "args": args])
    }
  }

  @objc(stop:rejecter:)
  func stop(_ resolve: @escaping RCTPromiseResolveBlock,
            rejecter reject: @escaping RCTPromiseRejectBlock) {
    queue.async {
      guard let p = self.process, p.isRunning else {
        resolve(["stopped": false])
        return
      }
      p.terminate()
      // terminationHandler clears self.process and emits neo-state.
      resolve(["stopped": true])
    }
  }

  @objc(status:rejecter:)
  func status(_ resolve: @escaping RCTPromiseResolveBlock,
              rejecter reject: @escaping RCTPromiseRejectBlock) {
    queue.async {
      let p = self.process
      resolve([
        "running": p?.isRunning ?? false,
        "pid": p.map { Int($0.processIdentifier) } as Any,
        "binPath": self.resolveBinary(nil) as Any,
        "dataDir": NeoCore.dataDir.path,
      ])
    }
  }

  /// Run a one-shot CLI command (e.g. ["snapshot"] or
  /// ["send", "--message", "hi", "--hops", "2"]) and capture its output.
  /// Resolves to { code, stdout, stderr } once the process exits or the
  /// timeout elapses (the process is then killed and code is null).
  @objc(exec:config:resolver:rejecter:)
  func exec(_ args: [String],
            config: NSDictionary,
            resolver resolve: @escaping RCTPromiseResolveBlock,
            rejecter reject: @escaping RCTPromiseRejectBlock) {
    // Deliberately not on self.queue: a slow one-shot command must not stall
    // the long-lived daemon's log streaming or stop().
    DispatchQueue.global(qos: .userInitiated).async {
      guard let binPath = self.resolveBinary(config["binPath"] as? String) else {
        reject("E_NO_BINARY", "no neo binary found — build one with scripts/build-rust.sh or set NEO_BIN", nil)
        return
      }
      try? FileManager.default.createDirectory(at: NeoCore.dataDir, withIntermediateDirectories: true)

      let env = (config["env"] as? [String: String]) ?? [:]
      let p = self.makeProcess(binPath: binPath, args: args, env: env)
      let out = Pipe(), err = Pipe()
      p.standardOutput = out
      p.standardError = err

      do {
        try p.run()
      } catch {
        reject("E_SPAWN", "failed to start \(binPath): \(error.localizedDescription)", error)
        return
      }

      let timeoutMs = (config["timeoutMs"] as? Double) ?? 30_000
      let done = DispatchSemaphore(value: 0)
      DispatchQueue.global(qos: .utility).async {
        p.waitUntilExit()
        done.signal()
      }
      let timedOut = done.wait(timeout: .now() + .milliseconds(Int(timeoutMs))) == .timedOut
      if timedOut { p.terminate() }

      let stdout = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
      let stderr = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
      resolve([
        "code": timedOut ? NSNull() as Any : Int(p.terminationStatus) as Any,
        "stdout": stdout,
        "stderr": stderr,
        "timedOut": timedOut,
      ])
    }
  }

  override func invalidate() {
    queue.async {
      if let p = self.process, p.isRunning { p.terminate() }
      self.process = nil
    }
    super.invalidate()
  }
}
