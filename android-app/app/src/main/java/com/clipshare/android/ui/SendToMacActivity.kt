package com.clipshare.android.ui

import android.app.Activity
import android.content.Intent
import android.content.ClipboardManager
import android.content.Context
import android.net.Uri
import android.os.Bundle
import android.widget.Toast
import com.clipshare.android.service.ClipboardSyncService
import com.clipshare.android.util.PrefsHelper

/**
 * Explicit, user-triggered entry point for selection actions, Sharesheet
 * content, notifications, shortcuts, and Quick Settings. It is deliberately
 * a visible foreground activity so Android permits clipboard access.
 */
class SendToMacActivity : Activity() {
    private var sentCurrentClipboard = false
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        if (!PrefsHelper.isPaired(this) || !PrefsHelper.isSyncEnabled(this)) {
            Toast.makeText(this, "Start ClipShare sync first", Toast.LENGTH_SHORT).show()
            finish()
            return
        }

        when (intent.action) {
            Intent.ACTION_PROCESS_TEXT -> sendText(intent.getCharSequenceExtra(Intent.EXTRA_PROCESS_TEXT)?.toString())
            Intent.ACTION_SEND -> receiveShare(intent)
            // Clipboard access happens in onResume(), after this activity has
            // input focus. Reading in onCreate() is too early on Android 10+.
            ACTION_SEND_CURRENT_CLIPBOARD -> Unit
            else -> finish()
        }
    }

    override fun onResume() {
        super.onResume()
        // The current clipboard is read in onWindowFocusChanged(), not here.
        // `onResume()` can run before Android grants clipboard access.
    }

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        if (hasFocus && intent.action == ACTION_SEND_CURRENT_CLIPBOARD && !sentCurrentClipboard) {
            sendCurrentClipboard()
        }
    }

    private fun sendText(text: String?) {
        text?.takeIf { it.isNotBlank() }?.let { ClipboardSyncService.sendText(this, it) }
            ?: Toast.makeText(this, "No selected text to send", Toast.LENGTH_SHORT).show()
        finish()
    }

    private fun receiveShare(shareIntent: Intent) {
        shareIntent.getStringExtra(Intent.EXTRA_TEXT)?.let(::sendText) ?: run {
            @Suppress("DEPRECATION")
            val uri = shareIntent.getParcelableExtra(Intent.EXTRA_STREAM) as? Uri
            if (uri == null) {
                Toast.makeText(this, "Nothing shareable was received", Toast.LENGTH_SHORT).show()
                finish()
            } else {
                ClipboardSyncService.sendImage(this, uri, shareIntent.type)
                Toast.makeText(this, "Sending image to Mac", Toast.LENGTH_SHORT).show()
                finish()
            }
        }
    }

    private fun sendCurrentClipboard() {
        sentCurrentClipboard = true
        val clipboard = getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
        val clip = clipboard.primaryClip
        val item = clip?.takeIf { it.itemCount > 0 }?.getItemAt(0)
        when {
            item?.text?.isNotEmpty() == true -> {
                ClipboardSyncService.sendText(this, item.text.toString())
                Toast.makeText(this, "Sending clipboard to Mac", Toast.LENGTH_SHORT).show()
            }
            item?.uri != null -> {
                ClipboardSyncService.sendImage(this, item.uri, clip.description?.filterMimeTypes("image/*")?.firstOrNull())
                Toast.makeText(this, "Sending image to Mac", Toast.LENGTH_SHORT).show()
            }
            else -> Toast.makeText(this, "No readable clipboard item", Toast.LENGTH_SHORT).show()
        }
        window.decorView.postDelayed({ finish() }, 350)
    }

    companion object {
        const val ACTION_SEND_CURRENT_CLIPBOARD = "com.clipshare.android.action.SEND_CURRENT_CLIPBOARD"
    }
}
