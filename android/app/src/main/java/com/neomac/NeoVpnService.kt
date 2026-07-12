package com.neomac

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.Intent
import android.net.VpnService
import android.os.Build
import android.os.ParcelFileDescriptor
import android.util.Base64
import android.util.Log
import java.io.FileInputStream
import java.io.FileOutputStream
import kotlin.concurrent.thread
import uniffi.neo_ffi.NeoPrivacy
import uniffi.neo_ffi.NeoTunnelStackSession
import uniffi.neo_ffi.tunnelStackConnect

/**
 * The Android VPN. Captures all traffic on a TUN and drives the neo Rust core
 * (a `NeoTunnelStackSession`): each intercepted flow gets its own multi-hop onion
 * circuit. The neo app's own traffic is excluded from the tunnel so the circuit
 * sockets don't loop back in.
 */
class NeoVpnService : VpnService() {
  private var tun: ParcelFileDescriptor? = null
  private var session: NeoTunnelStackSession? = null
  @Volatile private var running = false

  companion object {
    const val ACTION_CONNECT = "com.neomac.CONNECT"
    const val ACTION_DISCONNECT = "com.neomac.DISCONNECT"
    const val EXTRA_IDENTITY = "identity"
    const val EXTRA_MIRRORS = "mirrors"
    const val EXTRA_WITNESSES = "witnesses"
    const val EXTRA_THRESHOLD = "threshold"
    const val EXTRA_PRIVACY = "privacy"
    const val ACTION_STATE = "com.neomac.VPN_STATE"
    const val EXTRA_STATE = "state"
    private const val TAG = "NeoVpn"
    private const val NOTIF_ID = 1
    private const val CHANNEL = "neo_vpn"
  }

  override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
    if (intent?.action == ACTION_DISCONNECT) {
      stopTunnel()
      return START_NOT_STICKY
    }
    if (Build.VERSION.SDK_INT >= 34) {
      startForeground(
          NOTIF_ID,
          notification("connecting…"),
          android.content.pm.ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE)
    } else {
      startForeground(NOTIF_ID, notification("connecting…"))
    }
    broadcast("connecting")

    val secretB64 = intent?.getStringExtra(EXTRA_IDENTITY)
    val mirrors = intent?.getStringArrayListExtra(EXTRA_MIRRORS)
    val witnesses = intent?.getStringArrayListExtra(EXTRA_WITNESSES)
    val threshold = intent?.getIntExtra(EXTRA_THRESHOLD, witnesses?.size ?: 1) ?: 1
    val privacyStr = intent?.getStringExtra(EXTRA_PRIVACY) ?: "balanced"
    if (secretB64 == null || mirrors.isNullOrEmpty() || witnesses.isNullOrEmpty()) {
      Log.e(TAG, "missing provider configuration")
      fail()
      return START_NOT_STICKY
    }
    val secret = Base64.decode(secretB64, Base64.NO_WRAP)
    val privacy =
        when (privacyStr) {
          "off", "low" -> NeoPrivacy.OFF
          "paranoid" -> NeoPrivacy.PARANOID
          else -> NeoPrivacy.BALANCED
        }

    // Discovery + handshake can block; do them off the main thread.
    thread(name = "neo-connect") {
      try {
        val s = tunnelStackConnect(secret, mirrors, witnesses, threshold.toUInt(), privacy, 0u)
        session = s
        establishAndPump()
        Log.i(TAG, "tunnel up: ${s.relayCount()} relays")
        update("connected · ${s.relayCount()} relays")
        broadcast("connected")
      } catch (e: Exception) {
        Log.e(TAG, "connect failed", e)
        fail()
      }
    }
    return START_STICKY
  }

  private fun establishAndPump() {
    val builder =
        Builder()
            .setSession("neo")
            .addAddress("10.9.0.2", 24)
            .addRoute("0.0.0.0", 0)
            .addDnsServer("1.1.1.1")
            .addDnsServer("9.9.9.9")
            .setMtu(1400)
    // Keep the neo app's own sockets (circuits, discovery) off the tunnel.
    try {
      builder.addDisallowedApplication(packageName)
    } catch (e: Exception) {
      Log.w(TAG, "could not exclude self from VPN: ${e.message}")
    }
    val fd = builder.establish() ?: throw IllegalStateException("VpnService.establish() returned null")
    tun = fd
    running = true

    val sess = session ?: throw IllegalStateException("no session")
    val input = FileInputStream(fd.fileDescriptor)
    val output = FileOutputStream(fd.fileDescriptor)

    // outbound: TUN → neo
    thread(name = "neo-tun-read") {
      val buffer = ByteArray(65_535)
      while (running) {
        val n = try { input.read(buffer) } catch (e: Exception) { break }
        if (n <= 0) continue
        try {
          sess.submitOutbound(listOf(buffer.copyOf(n)))
        } catch (e: Exception) {
          break
        }
      }
    }
    // inbound: neo → TUN
    thread(name = "neo-tun-write") {
      while (running) {
        val packets = try { sess.drainInbound(64u, 250u) } catch (e: Exception) { break }
        for (p in packets) {
          try {
            output.write(p)
          } catch (e: Exception) {
            running = false
            break
          }
        }
      }
    }
  }

  private fun stopTunnel() {
    running = false
    try { session?.shutdown() } catch (_: Exception) {}
    session = null
    try { tun?.close() } catch (_: Exception) {}
    tun = null
    broadcast("disconnected")
    stopForeground(STOP_FOREGROUND_REMOVE)
    stopSelf()
  }

  private fun fail() {
    broadcast("disconnected")
    stopTunnel()
  }

  override fun onRevoke() {
    stopTunnel()
    super.onRevoke()
  }

  override fun onDestroy() {
    running = false
    try { session?.shutdown() } catch (_: Exception) {}
    try { tun?.close() } catch (_: Exception) {}
    super.onDestroy()
  }

  private fun broadcast(state: String) {
    sendBroadcast(Intent(ACTION_STATE).putExtra(EXTRA_STATE, state).setPackage(packageName))
  }

  private fun notification(text: String): Notification {
    val mgr = getSystemService(NotificationManager::class.java)
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
      mgr.createNotificationChannel(
          NotificationChannel(CHANNEL, "Neo VPN", NotificationManager.IMPORTANCE_LOW))
      return Notification.Builder(this, CHANNEL)
          .setContentTitle("Junctus Neo")
          .setContentText(text)
          .setSmallIcon(android.R.drawable.ic_lock_lock)
          .setOngoing(true)
          .build()
    }
    @Suppress("DEPRECATION")
    return Notification.Builder(this)
        .setContentTitle("Junctus Neo")
        .setContentText(text)
        .setSmallIcon(android.R.drawable.ic_lock_lock)
        .setOngoing(true)
        .build()
  }

  private fun update(text: String) {
    getSystemService(NotificationManager::class.java).notify(NOTIF_ID, notification(text))
  }
}
