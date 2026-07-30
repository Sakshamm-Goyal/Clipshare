package com.clipshare.android.service

import android.content.ClipData
import android.content.ClipboardManager
import android.content.ContentResolver
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.cancel
import java.io.ByteArrayOutputStream
import java.security.MessageDigest

sealed class ClipboardContent {
    abstract val size: Int
    abstract val fingerprint: String

    data class Text(val value: String) : ClipboardContent() {
        override val size: Int = value.toByteArray(Charsets.UTF_8).size
        override val fingerprint: String = fingerprint("text/plain", value.toByteArray(Charsets.UTF_8))
    }

    data class Image(val mimeType: String, val bytes: ByteArray) : ClipboardContent() {
        override val size: Int = bytes.size
        override val fingerprint: String = fingerprint(mimeType, bytes)
    }

    companion object {
        private fun fingerprint(type: String, bytes: ByteArray): String {
            val digest = MessageDigest.getInstance("SHA-256")
            digest.update(type.toByteArray(Charsets.UTF_8))
            digest.update(0)
            return digest.digest(bytes).joinToString("") { "%02x".format(it) }
        }
    }
}

class ClipboardObserver(private val onChange: (ClipboardContent) -> Unit) {
    private var clipboardManager: ClipboardManager? = null
    private var contentResolver: ContentResolver? = null
    private var lastFingerprint: String? = null
    private var isRunning = false

    private val debounceDelay = 250L
    private var debounceJob: Job? = null
    private val debounceScope = CoroutineScope(Dispatchers.Main + SupervisorJob())

    private val listener = ClipboardManager.OnPrimaryClipChangedListener { handleClipboardChange() }

    fun start(manager: ClipboardManager, resolver: ContentResolver) {
        if (isRunning) return
        clipboardManager = manager
        contentResolver = resolver
        isRunning = true
        manager.addPrimaryClipChangedListener(listener)
        handleClipboardChange()
    }

    fun stop() {
        if (!isRunning) return
        isRunning = false
        clipboardManager?.removePrimaryClipChangedListener(listener)
        clipboardManager = null
        contentResolver = null
        debounceJob?.cancel()
        debounceScope.cancel()
    }

    /**
     * Re-reads the clipboard while this app has input focus. Android 10+
     * deliberately hides clipboard data from ordinary background apps, so a
     * user-initiated refresh is the reliable path after copying in another app.
     */
    fun refresh() {
        if (isRunning) handleClipboardChange()
    }

    private fun handleClipboardChange() {
        val content = readClipboardContent() ?: return
        if (content.fingerprint == lastFingerprint) return

        debounceJob?.cancel()
        debounceJob = debounceScope.launch {
            delay(debounceDelay)
            val stableContent = readClipboardContent()
            if (stableContent?.fingerprint == content.fingerprint) {
                lastFingerprint = content.fingerprint
                onChange(content)
            }
        }
    }

    private fun readClipboardContent(): ClipboardContent? {
        val manager = clipboardManager ?: return null
        val resolver = contentResolver ?: return null
        if (!manager.hasPrimaryClip()) return null

        val clip: ClipData = manager.primaryClip ?: return null
        if (clip.itemCount == 0) return null
        val item = clip.getItemAt(0)
        val uri = item.uri
        val declaredMime = clip.description?.filterMimeTypes("image/*")?.firstOrNull()
        val mimeType = declaredMime ?: uri?.let(resolver::getType)

        if (uri != null && mimeType != null && isSupportedImage(mimeType)) {
            val bytes = resolver.openInputStream(uri)?.use(::readImageBytes) ?: return null
            return ClipboardContent.Image(mimeType.lowercase(), bytes)
        }

        return item.text?.toString()?.takeIf { it.isNotEmpty() }?.let(ClipboardContent::Text)
    }

    private fun readImageBytes(input: java.io.InputStream): ByteArray? {
        val output = ByteArrayOutputStream()
        val buffer = ByteArray(DEFAULT_BUFFER_SIZE)
        var total = 0
        while (true) {
            val read = input.read(buffer)
            if (read == -1) break
            total += read
            if (total > MAX_IMAGE_BYTES) return null
            output.write(buffer, 0, read)
        }
        return output.toByteArray()
    }

    companion object {
        const val MAX_IMAGE_BYTES = 5 * 1024 * 1024
        fun isSupportedImage(mimeType: String): Boolean = mimeType.lowercase() in setOf("image/png", "image/jpeg")
    }
}
