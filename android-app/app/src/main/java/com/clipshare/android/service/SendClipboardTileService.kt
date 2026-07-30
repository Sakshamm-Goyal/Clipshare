package com.clipshare.android.service

import android.app.PendingIntent
import android.content.Intent
import android.os.Build
import android.service.quicksettings.TileService
import com.clipshare.android.ui.SendToMacActivity

class SendClipboardTileService : TileService() {
    override fun onClick() {
        super.onClick()
        val intent = Intent(this, SendToMacActivity::class.java).apply {
            action = SendToMacActivity.ACTION_SEND_CURRENT_CLIPBOARD
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            startActivityAndCollapse(PendingIntent.getActivity(this, 0, intent, PendingIntent.FLAG_IMMUTABLE))
        } else {
            @Suppress("DEPRECATION")
            startActivityAndCollapse(intent)
        }
    }
}
