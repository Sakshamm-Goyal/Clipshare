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

    fun saveDeviceToken(context: Context, token: String) {
        getPrefs(context).edit().putString(KEY_DEVICE_TOKEN, token).apply()
    }

    fun getDeviceToken(context: Context): String? {
        return getPrefs(context).getString(KEY_DEVICE_TOKEN, null)
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
        return getPrefs(context).getString(KEY_SERVER_URL, "wss://localhost:8080/ws")
            ?: "wss://localhost:8080/ws"
    }

    fun setIsPaired(context: Context, isPaired: Boolean) {
        getPrefs(context).edit().putBoolean(KEY_IS_PAIRED, isPaired).apply()
    }

    fun isPaired(context: Context): Boolean {
        return getPrefs(context).getBoolean(KEY_IS_PAIRED, false)
    }

    fun clearAll(context: Context) {
        getPrefs(context).edit().clear().apply()
    }

    fun setAutoOverwrite(context: Context, enabled: Boolean) {
        getPrefs(context).edit().putBoolean(KEY_AUTO_OVERWRITE, enabled).apply()
    }

    fun isAutoOverwrite(context: Context): Boolean {
        return getPrefs(context).getBoolean(KEY_AUTO_OVERWRITE, true) // Default to true
    }
}
