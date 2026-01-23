package com.clipshare.android.service

import android.content.ClipData
import android.content.ClipboardManager
import android.os.Handler
import android.os.Looper
import kotlinx.coroutines.*

class ClipboardObserver(private val onChange: (String) -> Unit) {

    private var clipboardManager: ClipboardManager? = null
    private var lastClipText: String? = null
    private val handler = Handler(Looper.getMainLooper())
    private var isRunning = false

    private val debounceDelay = 250L // milliseconds
    private var debounceJob: Job? = null
    private val debounceScope = CoroutineScope(Dispatchers.Main + SupervisorJob())

    private val listener = ClipboardManager.OnPrimaryClipChangedListener {
        handleClipboardChange()
    }

    fun start(manager: ClipboardManager) {
        if (isRunning) return

        clipboardManager = manager
        isRunning = true

        // Add listener
        manager.addPrimaryClipChangedListener(listener)

        // Get initial clipboard content
        handleClipboardChange()
    }

    fun stop() {
        if (!isRunning) return

        isRunning = false
        clipboardManager?.removePrimaryClipChangedListener(listener)
        clipboardManager = null

        debounceJob?.cancel()
        debounceScope.cancel()
    }

    private fun handleClipboardChange() {
        val manager = clipboardManager ?: return

        if (!manager.hasPrimaryClip()) {
            return
        }

        val clip: ClipData = manager.primaryClip ?: return

        if (clip.itemCount == 0) {
            return
        }

        val item = clip.getItemAt(0)
        val text = item.text?.toString() ?: return

        // Filter duplicates
        if (text == lastClipText) {
            return
        }

        // Debounce rapid changes
        debounceJob?.cancel()
        debounceJob = debounceScope.launch {
            delay(debounceDelay)

            // Check if text is still the same after debounce
            val currentText = clipboardManager?.primaryClip
                ?.getItemAt(0)?.text?.toString()

            if (currentText == text) {
                lastClipText = text
                onChange(text)
            }
        }
    }
}
