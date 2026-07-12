package com.neomac

import android.app.Activity
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.net.VpnService
import androidx.core.content.ContextCompat
import com.facebook.react.bridge.ActivityEventListener
import com.facebook.react.bridge.Arguments
import com.facebook.react.bridge.Promise
import com.facebook.react.bridge.ReactApplicationContext
import com.facebook.react.bridge.ReactContextBaseJavaModule
import com.facebook.react.bridge.ReactMethod
import com.facebook.react.bridge.ReadableMap
import com.facebook.react.modules.core.DeviceEventManagerModule

/**
 * Installs/controls the system VPN (the [NeoVpnService]). Mirrors the macOS
 * `NeoVPN` module: `connect` handles the one-time system consent then starts the
 * foreground service; state changes are emitted to JS as `neo-vpn-state`.
 */
class NeoVpnModule(private val reactCtx: ReactApplicationContext) :
    ReactContextBaseJavaModule(reactCtx), ActivityEventListener {

  private var pendingConfig: ReadableMap? = null
  private var connectPromise: Promise? = null
  @Volatile private var lastState = "disconnected"

  companion object {
    private const val VPN_REQUEST = 0x6e656f // "neo"
  }

  private val stateReceiver =
      object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
          val state = intent?.getStringExtra(NeoVpnService.EXTRA_STATE) ?: return
          lastState = state
          emit(state)
        }
      }

  init {
    reactCtx.addActivityEventListener(this)
    ContextCompat.registerReceiver(
        reactCtx,
        stateReceiver,
        IntentFilter(NeoVpnService.ACTION_STATE),
        ContextCompat.RECEIVER_NOT_EXPORTED)
  }

  override fun getName() = "NeoVPN"

  override fun onNewIntent(intent: Intent) {}

  override fun onActivityResult(
      activity: Activity,
      requestCode: Int,
      resultCode: Int,
      data: Intent?
  ) {
    if (requestCode != VPN_REQUEST) return
    val config = pendingConfig
    val promise = connectPromise
    pendingConfig = null
    connectPromise = null
    if (resultCode == Activity.RESULT_OK && config != null) {
      startService(config)
      promise?.resolve(started())
    } else {
      promise?.reject("E_CONSENT", "VPN permission was not granted")
    }
  }

  @ReactMethod
  fun connect(config: ReadableMap, promise: Promise) {
    val identity = config.getString("identityBase64")
    val mirrors = config.getArray("mirrors")
    val witnesses = config.getArray("witnesses")
    if (identity.isNullOrEmpty() || mirrors == null || mirrors.size() == 0 ||
        witnesses == null || witnesses.size() == 0) {
      promise.reject("E_CONFIG", "connect requires identityBase64, mirrors and witnesses")
      return
    }
    val consent = VpnService.prepare(reactCtx)
    if (consent != null) {
      // First time: show the system VPN consent dialog, resume in onActivityResult.
      val activity = reactCtx.currentActivity
      if (activity == null) {
        promise.reject("E_NO_ACTIVITY", "no foreground activity to request VPN consent")
        return
      }
      pendingConfig = config
      connectPromise = promise
      activity.startActivityForResult(consent, VPN_REQUEST)
    } else {
      startService(config)
      promise.resolve(started())
    }
  }

  @ReactMethod
  fun disconnect(promise: Promise) {
    val intent = Intent(reactCtx, NeoVpnService::class.java).apply {
      action = NeoVpnService.ACTION_DISCONNECT
    }
    reactCtx.startService(intent)
    val map = Arguments.createMap()
    map.putBoolean("stopped", true)
    promise.resolve(map)
  }

  @ReactMethod
  fun status(promise: Promise) {
    val map = Arguments.createMap()
    map.putString("status", lastState)
    map.putBoolean("installed", VpnService.prepare(reactCtx) == null)
    promise.resolve(map)
  }

  // NativeEventEmitter plumbing.
  @ReactMethod fun addListener(eventName: String) {}

  @ReactMethod fun removeListeners(count: Int) {}

  private fun startService(config: ReadableMap) {
    val intent =
        Intent(reactCtx, NeoVpnService::class.java).apply {
          action = NeoVpnService.ACTION_CONNECT
          putExtra(NeoVpnService.EXTRA_IDENTITY, config.getString("identityBase64"))
          putStringArrayListExtra(NeoVpnService.EXTRA_MIRRORS, stringList(config, "mirrors"))
          putStringArrayListExtra(NeoVpnService.EXTRA_WITNESSES, stringList(config, "witnesses"))
          if (config.hasKey("threshold")) {
            putExtra(NeoVpnService.EXTRA_THRESHOLD, config.getInt("threshold"))
          }
          putExtra(NeoVpnService.EXTRA_PRIVACY, config.getString("privacy") ?: "balanced")
        }
    ContextCompat.startForegroundService(reactCtx, intent)
  }

  private fun stringList(config: ReadableMap, key: String): ArrayList<String> {
    val out = ArrayList<String>()
    config.getArray(key)?.let { arr ->
      for (i in 0 until arr.size()) {
        arr.getString(i)?.let { out.add(it) }
      }
    }
    return out
  }

  private fun started() = Arguments.createMap().apply { putBoolean("started", true) }

  private fun emit(state: String) {
    if (!reactCtx.hasActiveReactInstance()) return
    reactCtx
        .getJSModule(DeviceEventManagerModule.RCTDeviceEventEmitter::class.java)
        .emit("neo-vpn-state", Arguments.createMap().apply { putString("status", state) })
  }
}
