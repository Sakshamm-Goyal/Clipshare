package com.clipshare.android.service

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import com.clipshare.android.util.PrefsHelper

/** Restarts sync after reboot or app update, if the user had it on. */
class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (PrefsHelper.isPaired(context) && PrefsHelper.isSyncEnabled(context)) {
            ClipboardSyncService.start(context)
        }
    }
}
