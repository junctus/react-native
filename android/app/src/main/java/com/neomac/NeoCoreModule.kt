package com.neomac

import android.util.Base64
import com.facebook.react.bridge.Arguments
import com.facebook.react.bridge.Promise
import com.facebook.react.bridge.ReactApplicationContext
import com.facebook.react.bridge.ReactContextBaseJavaModule
import com.facebook.react.bridge.ReactMethod
import java.io.File
import uniffi.neo_ffi.generateIdentity
import uniffi.neo_ffi.identityNodeId

/**
 * Identity operations, in-process through the Rust core (neo-ffi via UniFFI).
 * The key file is the same raw format the `neo` CLI and the macOS app use.
 */
class NeoCoreModule(reactContext: ReactApplicationContext) :
    ReactContextBaseJavaModule(reactContext) {

  override fun getName() = "NeoCore"

  private fun identityFile(): File = File(reactApplicationContext.filesDir, "neo/identity.key")

  @ReactMethod
  fun ensureIdentity(promise: Promise) {
    Thread {
      try {
        val file = identityFile()
        file.parentFile?.mkdirs()
        var created = false
        val secret: ByteArray =
            if (file.exists()) {
              file.readBytes()
            } else {
              val fresh = generateIdentity()
              if (fresh.isEmpty()) {
                promise.reject("E_RNG", "the OS RNG was unavailable while generating an identity")
                return@Thread
              }
              file.writeBytes(fresh)
              created = true
              fresh
            }
        val nodeId = identityNodeId(secret)
        if (nodeId == null) {
          promise.reject("E_IDENTITY", "${file.path} does not contain a valid neo identity")
          return@Thread
        }
        val map = Arguments.createMap()
        map.putString("nodeId", nodeId)
        map.putString("path", file.absolutePath)
        map.putBoolean("created", created)
        promise.resolve(map)
      } catch (e: Exception) {
        promise.reject("E_IDENTITY", "identity setup failed: ${e.message}", e)
      }
    }
        .start()
  }

  /** The identity secret, base64-encoded, for handing to the VPN tunnel config. */
  @ReactMethod
  fun identitySecretBase64(promise: Promise) {
    Thread {
      try {
        val file = identityFile()
        if (!file.exists()) {
          promise.reject("E_IDENTITY", "no identity at ${file.path} — call ensureIdentity first")
          return@Thread
        }
        promise.resolve(Base64.encodeToString(file.readBytes(), Base64.NO_WRAP))
      } catch (e: Exception) {
        promise.reject("E_IDENTITY", e.message, e)
      }
    }
        .start()
  }
}
