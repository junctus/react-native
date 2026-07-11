import Foundation
import NetworkExtension

// System-extension entry point. Unlike an app extension (which the OS launches
// via NSExtensionMain), a system extension is a normal executable: hand control
// to NetworkExtension, which instantiates PacketTunnelProvider when the tunnel
// starts, then park the main thread on the run loop.
autoreleasepool {
  NEProvider.startSystemExtensionMode()
}
dispatchMain()
