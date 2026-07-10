# neo-mac

The macOS app for [neo](../neo) — a react-native-macos shell over the shared Rust core.

```
React Native UI (App.tsx)
   │ NativeModules
   ▼
NeoNative pod (native/)          ── runs in the app process
   ├─ NeoCore    — identity, in-process via UniFFI Swift bindings → libneo_ffi.a
   ├─ NeoDaemon  — spawns the bundled `neo` CLI (snapshot / send), streams output
   └─ NeoVPN     — installs/controls the system VPN via NETunnelProviderManager
                        │
                        ▼  (separate process)
NeoTunnel.appex (macos/NeoTunnel/)   ── the NEPacketTunnelProvider
   PacketTunnelProvider.swift → NeoTunnelStackSession (libneo_ffi.a)
   captures ALL IP traffic (default route), intercepts each TCP flow, and routes
   it through a fresh multi-hop onion circuit to its destination.
```

Identity lives in `~/Library/Application Support/neo/identity.key` (inside the
sandbox container), written in the same raw format as `neo identity generate`,
so the app and the CLI share it.

## Routing all traffic through neo (the VPN)

"Connect — tunnel everything" installs a system VPN profile whose packet-tunnel
provider (`NeoTunnel.appex`) claims the default route, so macOS hands it every
connection. The provider drives a `NeoTunnelStackSession` (in `neo-ffi`): it
fetches a **witness-verified relay snapshot** from the discovery mirrors you
enter, then runs the full userspace stack — for **each** intercepted TCP flow it
opens a *fresh* onion circuit through `hops` randomly-picked relays to that flow's
own destination, where the exit splices the real connection. Every flow gets its
own multi-hop, sliced route; no relay on a path sees both you and your
destination.

How it fits together:

```
NeoVPN (app) ──install/start──▶ NeoTunnel.appex (NEPacketTunnelProvider)
                                     │ default route: all IPv4
                                     ▼
                            NeoTunnelStackSession (neo-ffi)
                                     │  submitOutbound / drainInbound
                                     ▼
             neo-netstack (smoltcp gateway)  →  intercepted TCP flows
                                     │  one per connection
                                     ▼
             neo_node::tunnel_stack → open_circuit(dst) through N relays → exit splice
```

**What you must provide:**

1. **An Apple Developer team.** `NEPacketTunnelProvider` requires the
   `com.apple.developer.networking.networkextension` entitlement, which only a
   paid Apple Developer account can provision. Set your team and enable the
   *Network Extensions* capability on both the `NeoMac-macOS` and `NeoTunnel`
   targets (see below), or the app won't launch signed.
2. **A reachable neo network** — discovery mirror(s) and the trusted witness
   key(s) to verify their snapshot, plus enough relays (one running `--exit`) to
   build a circuit. Enter the mirror URL(s), witness key(s), and hop count in the
   VPN card. Run one locally per the neo repo's README, or point at a deployment.

This is the full data path the earlier milestones built toward: the `neo-netstack`
`smoltcp` gateway (raw packets → TCP flows) and `neo_node::tunnel_stack` (a fresh
onion circuit per flow) in the core, discovered relays and per-flow circuit
selection in the `NeoTunnelStackSession` FFI. Each piece is unit-/integration-
tested (interception, a real 2-hop circuit to a target and back, and
snapshot fetch/verification).

### Enabling it

```sh
# 1. Set your team so the NE entitlement can be provisioned:
open macos/NeoMac.xcworkspace
#    NeoMac-macOS target → Signing & Capabilities → select your Team,
#    add "Network Extensions" capability. Repeat for the NeoTunnel target.
# 2. Build & run:
npm run macos
```

## Prerequisites

- **Full Xcode** (not just Command Line Tools) — `pod install` and the app
  build require it: `sudo xcode-select -s /Applications/Xcode.app`
- Rust with the `aarch64-apple-darwin` target (add `x86_64-apple-darwin` for
  universal builds)
- Node 20+, CocoaPods
- The `neo` repo checked out as a sibling directory (`../neo`)

## Build

```sh
npm install
npm run build:rust        # libneo_ffi.a + Swift bindings + neo CLI → native/
cd macos && pod install && cd ..
npm run macos             # build + launch (starts Metro)
```

`scripts/build-rust.sh` regenerates everything under `native/Generated`,
`native/Libs`, and `native/Bin` from the sibling neo repo — rerun it after
changing the Rust core.

## Try it against a local network

Run a seed + relays from the neo repo (see its README), then paste the seed's
mirror URL (e.g. `http://127.0.0.1:8899`) into the app's *discovery mirrors*
field, connect, fetch a snapshot, and send a message through a 2-hop circuit.

## Layout

```
App.tsx                        the UI (status, identity, VPN, snapshot, send, log)
src/native/NeoNative.ts        typed JS wrapper over NeoCore / NeoDaemon
src/native/NeoVPN.ts           typed JS wrapper over NeoVPN
native/                        NeoNative pod: Swift sources + bindings + artifacts
macos/NeoTunnel/               the NEPacketTunnelProvider extension (Swift)
rust/uniffi-bindgen/           helper binary that generates the Swift bindings
scripts/build-rust.sh          rebuilds all Rust artifacts
scripts/add-tunnel-target.rb   (re)adds the NeoTunnel extension target to the project
scripts/add-fonts.rb           (re)adds the bundled fonts to the app resources
macos/NeoMac-macOS/Fonts/      Instrument Serif / Newsreader / Fragment Mono (OFL)
macos/                         Xcode project + Podfile (react-native-macos)
```

The UI follows the [junctus.org](https://junctus.org) "terminal specification"
aesthetic — warm black, phosphor green + amber, serif display (Instrument Serif)
with Fragment Mono micro-labels. The fonts are bundled and registered via
`ATSApplicationFontsPath` (Info.plist); if `pod install` ever drops them, re-add
with `ruby scripts/add-fonts.rb`.

The `NeoTunnelSession` FFI (the packet pipe) lives in the neo repo at
`core/crates/neo-ffi/src/tunnel.rs`; `scripts/build-rust.sh` regenerates the
bindings that expose it. If `pod install` ever drops the extension target, re-add
it with `ruby scripts/add-tunnel-target.rb`.

## Known limits

- The bundled `neo` binary is copied into the app bundle as a pod *resource*;
  under a hardened-runtime / notarized build it must instead be embedded as a
  signed helper. Fine for development signing.
- `native/Libs`/`native/Bin` artifacts are arm64-only unless the x86_64 Rust
  target is installed when running `build:rust`.
- ios/ and android/ folders are unused scaffold leftovers from the RN template.
