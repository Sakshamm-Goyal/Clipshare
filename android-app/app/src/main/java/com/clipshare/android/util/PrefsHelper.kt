package com.clipshare.android.util

import android.content.Context
import android.content.SharedPreferences

object PrefsHelper {

    private const val PREFS_NAME = "clipshare"

    private const val KEY_DEVICE_ID = "device_id"
    private const val KEY_DEVICE_TOKEN = "device_token"
    private const val KEY_PEER_DEVICE_ID = "peer_device_id"
    private const val KEY_SERVER_URL = "server_url"
    private const val KEY_IS_PAIRED = "is_paired"
    private const val KEY_SYNC_ENABLED = "sync_enabled"
    private const val KEY_AUTO_OVERWRITE = "auto_overwrite"

    private fun getPrefs(context: Context): SharedPreferences {
        return context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
    }

    fun getDeviceId(context: Context): String {
        val prefs = getPrefs(context)
        var deviceId = prefs.getString(KEY_DEVICE_ID, null)

        if (deviceId == null) {
            // Generate new device ID
            deviceId = "android-${java.util.UUID.randomUUID().toString().take(12)}"
            prefs.edit().putString(KEY_DEVICE_ID, deviceId).apply()
        }

        return deviceId
    }

    fun saveDeviceId(context: Context, deviceId: String) {
        getPrefs(context).edit().putString(KEY_DEVICE_ID, deviceId).apply()
    }

    fun saveDeviceToken(context: Context, token: String) {
        SecurePrefs.get(context).edit().putString(KEY_DEVICE_TOKEN, token).apply()
    }

    fun getDeviceToken(context: Context): String? {
        val securePrefs = SecurePrefs.get(context)
        securePrefs.getString(KEY_DEVICE_TOKEN, null)?.let { return it }

        // One-time migration from the original plaintext preference store.
        val legacyToken = getPrefs(context).getString(KEY_DEVICE_TOKEN, null) ?: return null
        securePrefs.edit().putString(KEY_DEVICE_TOKEN, legacyToken).apply()
        getPrefs(context).edit().remove(KEY_DEVICE_TOKEN).apply()
        return legacyToken
    }

    fun savePeerDeviceId(context: Context, peerDeviceId: String) {
        getPrefs(context).edit().putString(KEY_PEER_DEVICE_ID, peerDeviceId).apply()
    }

    fun getPeerDeviceId(context: Context): String? {
        return getPrefs(context).getString(KEY_PEER_DEVICE_ID, null)
    }

    fun saveServerUrl(context: Context, url: String) {
        getPrefs(context).edit().putString(KEY_SERVER_URL, url).apply()
    }

    fun getServerUrl(context: Context): String {
        return getPrefs(context).getString(KEY_SERVER_URL, "ws://10.0.2.2:8080/ws")
            ?: "ws://10.0.2.2:8080/ws"
    }

    fun setIsPaired(context: Context, isPaired: Boolean) {
        getPrefs(context).edit().putBoolean(KEY_IS_PAIRED, isPaired).apply()
    }

    fun isPaired(context: Context): Boolean {
        return getPrefs(context).getBoolean(KEY_IS_PAIRED, false)
    }

    /**
     * This records the user's explicit Start/Stop choice, rather than trying
     * to infer connection state from pairing. A paired device can be paused.
     */
    fun setSyncEnabled(context: Context, enabled: Boolean) {
        getPrefs(context).edit().putBoolean(KEY_SYNC_ENABLED, enabled).apply()
    }

    fun isSyncEnabled(context: Context): Boolean {
        return getPrefs(context).getBoolean(KEY_SYNC_ENABLED, false)
    }

    fun clearAll(context: Context) {
        getPrefs(context).edit().clear().apply()
        SecurePrefs.get(context).edit().remove(KEY_DEVICE_TOKEN).apply()
    }

    fun setAutoOverwrite(context: Context, enabled: Boolean) {
        getPrefs(context).edit().putBoolean(KEY_AUTO_OVERWRITE, enabled).apply()
    }

    fun isAutoOverwrite(context: Context): Boolean {
        return getPrefs(context).getBoolean(KEY_AUTO_OVERWRITE, true) // Default to true
    }
}
