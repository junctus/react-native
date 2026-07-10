// neo — macOS Packet Tunnel Provider.
//
// Runs inside the NetworkExtension process. The OS routes ALL of the Mac's IP
// traffic here (default route); this provider hands each packet to the neo Rust
// core (a NeoTunnelSession that carries it to a peer exit node through neo's
// encrypted, timing-mixed tunnel) and writes the replies back.
//
// The generated UniFFI bindings (neo_ffi.swift) are compiled into this target,
// so `tunnelConnect`, `NeoTunnelSession`, and `NeoPrivacy` are in scope directly.

import NetworkExtension
import os.log

private let log = Logger(subsystem: "co.neo.mac.tunnel", category: "provider")

final class PacketTunnelProvider: NEPacketTunnelProvider {
  private var session: NeoTunnelStackSession?
  private let inboundQueue = DispatchQueue(label: "neo.tunnel.inbound")
  private var running = false

  override func startTunnel(
    options: [String: NSObject]?,
    completionHandler: @escaping (Error?) -> Void
  ) {
    guard
      let proto = protocolConfiguration as? NETunnelProviderProtocol,
      let conf = proto.providerConfiguration,
      let mirrors = conf["mirrors"] as? [String], !mirrors.isEmpty,
      let witnesses = conf["witnesses"] as? [String], !witnesses.isEmpty,
      let secretB64 = conf["identity"] as? String,
      let secret = Data(base64Encoded: secretB64)
    else {
      log.error("missing/invalid provider configuration")
      completionHandler(NEVPNError(.configurationInvalid))
      return
    }
    let threshold = UInt32((conf["threshold"] as? Int) ?? witnesses.count)
    let hops = UInt32((conf["hops"] as? Int) ?? 2)

    // Discover relays (a witness-verified snapshot) and start the multi-hop
    // stack before we claim the route, so a failure surfaces as a failed
    // connection. Each intercepted flow gets its own fresh onion circuit.
    do {
      let started = try tunnelStackConnect(
        secret: secret,
        mirrors: mirrors,
        witnesses: witnesses,
        threshold: threshold,
        hops: hops
      )
      session = started
      log.info("multi-hop tunnel up: \(started.relayCount()) relays, \(hops)-hop circuits")
    } catch {
      log.error("tunnelStackConnect failed: \(error.localizedDescription, privacy: .public)")
      completionHandler(error)
      return
    }

    // Capture everything: a default route sends all IPv4 traffic into the tunnel.
    let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "10.9.0.1")
    let ipv4 = NEIPv4Settings(addresses: ["10.9.0.2"], subnetMasks: ["255.255.255.0"])
    ipv4.includedRoutes = [NEIPv4Route.default()]
    settings.ipv4Settings = ipv4
    settings.mtu = 1400
    let dns = NEDNSSettings(servers: ["1.1.1.1", "9.9.9.9"])
    dns.matchDomains = [""]  // resolve all domains through the tunnel
    settings.dnsSettings = dns

    setTunnelNetworkSettings(settings) { [weak self] error in
      guard let self else { return }
      if let error {
        log.error("setTunnelNetworkSettings failed: \(error.localizedDescription, privacy: .public)")
        self.session?.close()
        self.session = nil
        completionHandler(error)
        return
      }
      self.running = true
      self.readOutbound()
      self.pumpInbound()
      completionHandler(nil)
    }
  }

  override func stopTunnel(
    with reason: NEProviderStopReason,
    completionHandler: @escaping () -> Void
  ) {
    log.info("stopTunnel: reason \(reason.rawValue)")
    running = false
    session?.close()
    session = nil
    completionHandler()
  }

  /// Outbound: OS TUN → neo. Recurses to keep reading as long as we're up.
  private func readOutbound() {
    packetFlow.readPackets { [weak self] packets, _ in
      guard let self, self.running, let session = self.session else { return }
      session.submitOutbound(packets: packets)
      self.readOutbound()
    }
  }

  /// Inbound: neo → OS TUN. `drainInbound` blocks up to the timeout in Rust, so
  /// this loop parks rather than spins when there's no return traffic.
  private func pumpInbound() {
    inboundQueue.async { [weak self] in
      while true {
        guard let self, self.running, let session = self.session else { return }
        let packets = session.drainInbound(maxPackets: 64, timeoutMs: 250)
        guard !packets.isEmpty else { continue }
        let protocols = [NSNumber](repeating: NSNumber(value: AF_INET), count: packets.count)
        self.packetFlow.writePackets(packets, withProtocols: protocols)
      }
    }
  }
}
