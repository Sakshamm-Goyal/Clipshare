package com.clipshare.android.ui

/**
 * Keeps the persisted "sync enabled" preference aligned with the actual Android
 * foreground-service lifecycle when the user returns to ClipShare.
 */
object SyncStartupPolicy {
    fun shouldEnsureService(
        isPaired: Boolean,
        isSyncEnabled: Boolean,
        isServiceRunning: Boolean
    ): Boolean = isPaired && isSyncEnabled && !isServiceRunning
}
