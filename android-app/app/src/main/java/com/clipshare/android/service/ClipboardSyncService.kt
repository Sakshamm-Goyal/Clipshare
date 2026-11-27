package com.clipshare.android.service

import android.app.Notification
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.app.ActivityManager
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.content.ContentValues
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.PowerManager
import android.widget.Toast
import androidx.core.app.NotificationCompat
import androidx.core.content.FileProvider
import com.clipshare.android.ClipboardApp
import com.clipshare.android.R
import com.clipshare.android.crypto.CryptoBox
import com.clipshare.android.data.AppDatabase
import com.clipshare.android.data.OutboxItem
import com.clipshare.android.ui.MainActivity
import com.clipshare.android.ui.SendToMacActivity
import com.clipshare.android.util.PrefsHelper
import com.google.gson.Gson
import kotlinx.coroutines.*
import java.util.*
import java.io.File

class ClipboardSyncService : Service() {

    private val serviceScope = CoroutineScope(Dispatchers.Default + SupervisorJob())
    private val mainHandler = Handler(Looper.getMainLooper())

    private lateinit var clipboardManager: ClipboardManager
    private lateinit var clipboardObserver: ClipboardObserver
    private lateinit var wsClient: WebSocketClient
    private lateinit var cryptoBox: CryptoBox
    private lateinit var database: AppDatabase
    private lateinit var wakeLock: PowerManager.WakeLock

    private val gson = Gson()
    private var lastClipboardFingerprint: String? = null
    private var sequenceNumber: Int = 0

    // For echo prevention
    private var lastReceivedFingerprint: String? = null
    private var lastReceivedTime: Long = 0
    private val echoPrevention = 2000L // 2 seconds

    override fun onCreate() {
        super.onCreate()

        // Initialize components
        clipboardManager = getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
        cryptoBox = CryptoBox(this)
        database = AppDatabase.getInstance(this)

        // Acquire partial wake lock to keep service alive
        val powerManager = getSystemService(Context.POWER_SERVICE) as PowerManager
        wakeLock = powerManager.newWakeLock(
            PowerManager.PARTIAL_WAKE_LOCK,
            "ClipboardSync::ServiceWakeLock"
        )

        // Setup clipboard observer
        clipboardObserver = ClipboardObserver { content ->
            handleClipboardChange(content)
        }

        // Setup WebSocket client
        val deviceToken = PrefsHelper.getDeviceToken(this)
        if (deviceToken != null) {
            wsClient = WebSocketClient(
                serverUrl = PrefsHelper.getServerUrl(this),
                deviceToken = deviceToken,
                onMessage = { message -> handleIncomingMessage(message) },
                onConnected = {
                    updateNotification(connected = true)
                    showToast("Clipboard sync connected")
                    serviceScope.launch { processOutbox() }
                },
                onDisconnected = { onRelayLost() }
            )
        }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        // Start foreground service
        val notification = createNotification(connected = false)
        startForeground(NOTIFICATION_ID, notification)

        // Acquire wake lock - use indefinite wake lock for background sync
        // The service will release it when stopped
        if (!wakeLock.isHeld) {
            @Suppress("DEPRECATION")
            wakeLock.acquire()
        }

        // Start observing clipboard
        clipboardObserver.start(clipboardManager, contentResolver)
        when (intent?.action) {
            ACTION_SYNC_CURRENT_CLIPBOARD -> clipboardObserver.refresh()
            ACTION_SEND_TEXT -> intent.getStringExtra(EXTRA_TEXT)
                ?.takeIf { it.isNotEmpty() }
                ?.let { handleClipboardChange(ClipboardContent.Text(it)) }
            ACTION_SEND_IMAGE -> readSharedImage(intent)?.let(::handleClipboardChange)
        }

        // Re-initialize WebSocket client with current credentials
        // This handles the case where pairing just completed
        initializeWebSocketClient()

        // Connect WebSocket
        if (::wsClient.isInitialized) {
            wsClient.connect()
        }

        // Process queued items
        serviceScope.launch {
            processOutbox()
        }

        return START_STICKY // Restart if killed
    }

    private fun initializeWebSocketClient() {
        val deviceToken = PrefsHelper.getDeviceToken(this)
        val serverUrl = PrefsHelper.getServerUrl(this)

        android.util.Log.d("ClipShare", "=== initializeWebSocketClient ===")
        android.util.Log.d("ClipShare", "Server URL: $serverUrl")
        android.util.Log.d("ClipShare", "Token available: ${deviceToken != null}")

        if (deviceToken == null) {
            android.util.Log.w("ClipShare", "No device token, skipping WebSocket init")
            return
        }

        // Disconnect existing client if any
        if (::wsClient.isInitialized) {
            wsClient.disconnect()
        }

        wsClient = WebSocketClient(
            serverUrl = serverUrl,
            deviceToken = deviceToken,
            onMessage = { message -> handleIncomingMessage(message) },
            onConnected = {
                updateNotification(connected = true)
                showToast("Clipboard sync connected")
                serviceScope.launch { processOutbox() }
            },
            onDisconnected = { onRelayLost() }
        )
    }

    override fun onBind(intent: Intent?): IBinder? = null

    private var lastDiscoveryMs = 0L

    /** Mac's Wi-Fi IP may have changed: look it up over Bonjour and reconnect there. */
    private fun onRelayLost() {
        updateNotification(connected = false)
        val now = System.currentTimeMillis()
        if (now - lastDiscoveryMs < 30_000) return
        lastDiscoveryMs = now
        RelayDiscovery.find(this) { url ->
            if (url == PrefsHelper.getServerUrl(this)) return@find
            android.util.Log.i("ClipShare", "Relay moved, reconnecting to $url")
            PrefsHelper.saveServerUrl(this, url)
            mainHandler.post {
                initializeWebSocketClient()
                if (::wsClient.isInitialized) wsClient.connect()
            }
        }
    }

    override fun onDestroy() {
        super.onDestroy()

        // Cleanup
        clipboardObserver.stop()

        if (::wsClient.isInitialized) {
            wsClient.disconnect()
        }

        if (wakeLock.isHeld) {
            wakeLock.release()
        }

        serviceScope.cancel()
    }

    // MARK: - Clipboard Handling (Outgoing)

    private fun handleClipboardChange(content: ClipboardContent) {
        // Check for echo (content we just received from peer)
        if (content.fingerprint == lastReceivedFingerprint &&
            System.currentTimeMillis() - lastReceivedTime < echoPrevention) {
            return
        }

        if (content.fingerprint == lastClipboardFingerprint) {
            return
        }
        lastClipboardFingerprint = content.fingerprint

        val maxBytes = if (content is ClipboardContent.Image) ClipboardObserver.MAX_IMAGE_BYTES else MAX_TEXT_BYTES
        if (content.size > maxBytes) {
            showToast("Clipboard item too large")
            return
        }

        // Check if we have a session key
        if (!cryptoBox.hasSessionKey()) {
            return // Not paired yet
        }

        // Create plain item
        val plainItem = createPlainItem(content)

        // Encrypt
        val envelope = try {
            cryptoBox.encrypt(plainItem)
        } catch (e: Exception) {
            showToast("Encryption failed")
            return
        }

        // Save to outbox
        val outboxItem = OutboxItem(
            id = plainItem.id,
            seq = plainItem.seq,
            envelopeJson = envelope,
            timestamp = System.currentTimeMillis(),
            delivered = false
        )

        serviceScope.launch {
            database.outboxDao().insert(outboxItem)
            sendItem(outboxItem)
        }
    }

    private fun createPlainItem(content: ClipboardContent): PlainItem {
        sequenceNumber++
        val deviceId = PrefsHelper.getDeviceId(this)

        return PlainItem(
            id = UUID.randomUUID().toString(),
            seq = sequenceNumber,
            tsMs = System.currentTimeMillis(),
            kind = "clipboard_item",
            payload = when (content) {
                is ClipboardContent.Text -> PlainItem.Payload(
                    type = "text/plain", size = content.size, text = content.value, data = null
                )
                is ClipboardContent.Image -> PlainItem.Payload(
                    type = content.mimeType,
                    size = content.size,
                    text = null,
                    data = android.util.Base64.encodeToString(content.bytes, android.util.Base64.NO_WRAP)
                )
            },
            meta = PlainItem.Meta(
                app = "ClipShare-Android@1.0.0",
                network = "wifi",
                lang = Locale.getDefault().language
            )
        )
    }

    // MARK: - WebSocket Message Handling (Incoming)

    private fun handleIncomingMessage(messageJson: String) {
        try {
            // Parse the route message
            val routeMessage = gson.fromJson(messageJson, RouteMessage::class.java)

            // Check if it's for us
            val myDeviceId = PrefsHelper.getDeviceId(this)
            if (routeMessage.to != myDeviceId) {
                return // Not for us
            }

            if (routeMessage.type == "ack") {
                val messageId = routeMessage.id ?: return
                serviceScope.launch {
                    database.outboxDao().markDelivered(messageId)
                    database.outboxDao().deleteOldDelivered(System.currentTimeMillis() - OUTBOX_RETENTION_MS)
                }
                return
            }

            if (routeMessage.type != "route") {
                return
            }
            val routeID = routeMessage.id ?: return
            val encryptedData = routeMessage.data ?: return

            // Decrypt the envelope
            val plainItem = try {
                cryptoBox.decrypt(encryptedData)
            } catch (e: Exception) {
                showToast("Failed to decrypt message")
                return
            }

            // The durable outer message ID must agree with the encrypted item.
            if (plainItem.id != routeID) {
                showToast("Discarded malformed clipboard item")
                return
            }
            if (plainItem.payload.type.startsWith("image/") &&
                !ClipboardObserver.isSupportedImage(plainItem.payload.type)) {
                showToast("Unsupported image type")
                return
            }

            // Mark as received to prevent echo.
            lastReceivedFingerprint = when {
                plainItem.payload.type == "text/plain" && plainItem.payload.text != null ->
                    ClipboardContent.Text(plainItem.payload.text).fingerprint
                plainItem.payload.type.startsWith("image/") && plainItem.payload.data != null ->
                    ClipboardContent.Image(
                        plainItem.payload.type,
                        android.util.Base64.decode(plainItem.payload.data, android.util.Base64.NO_WRAP)
                    ).fingerprint
                else -> return
            }
            lastReceivedTime = System.currentTimeMillis()
            val preview = clipboardPreview(plainItem)
            val isScreenshot = plainItem.kind == "screenshot"
            if (isScreenshot) saveToGallery(plainItem)

            // Check auto-overwrite preference
            val autoOverwrite = PrefsHelper.isAutoOverwrite(this)

            if (autoOverwrite) {
                mainHandler.post {
                    if (writeToClipboard(plainItem)) {
                        if (!isScreenshot) showToast("Clipboard synced: $preview")
                        sendAck(routeID, routeMessage.from)
                    } else {
                        showToast("Failed to apply clipboard item")
                    }
                }
            } else {
                // Stage the item and notify user
                mainHandler.post {
                    stagedItem = plainItem
                    showNotification(
                        "Clipboard Ready",
                        "From ${plainItem.meta?.app ?: "Mac"}: $preview"
                    )
                }
                sendAck(routeID, routeMessage.from)
            }

        } catch (e: Exception) {
            // Not a valid message format, ignore
        }
    }

    private var stagedItem: PlainItem? = null

    private fun writeToClipboard(item: PlainItem): Boolean {
        val payload = item.payload
        val applied = when {
            payload.type == "text/plain" && payload.text != null -> {
                clipboardManager.setPrimaryClip(ClipData.newPlainText("ClipShare", payload.text))
                true
            }
            payload.type.startsWith("image/") && payload.data != null -> {
                val bytes = android.util.Base64.decode(payload.data, android.util.Base64.NO_WRAP)
                if (bytes.size > ClipboardObserver.MAX_IMAGE_BYTES) return false
                val extension = when (payload.type) {
                    "image/jpeg" -> "jpg"
                    "image/webp" -> "webp"
                    else -> "png"
                }
                val directory = File(cacheDir, "clipboard-images").apply { mkdirs() }
                val imageFile = File(directory, "${item.id}.$extension")
                imageFile.outputStream().use { it.write(bytes) }
                val uri = FileProvider.getUriForFile(this, "$packageName.fileprovider", imageFile)
                clipboardManager.setPrimaryClip(ClipData.newUri(contentResolver, "ClipShare image", uri))
                true
            }
            else -> false
        }
        if (applied) lastClipboardFingerprint = lastReceivedFingerprint
        return applied
    }

    /** Mac ⌘⇧I screenshots land in Pictures/ClipShare (and the clipboard). */
    private fun saveToGallery(item: PlainItem) {
        // ponytail: Android 8–9 would need WRITE_EXTERNAL_STORAGE; there it's clipboard-only.
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) return
        val bytes = android.util.Base64.decode(item.payload.data ?: return, android.util.Base64.NO_WRAP)
        val ext = if (item.payload.type == "image/jpeg") "jpg" else "png"
        val values = ContentValues().apply {
            put(MediaStore.Images.Media.DISPLAY_NAME, "Mac-Screenshot-${item.tsMs}.$ext")
            put(MediaStore.Images.Media.MIME_TYPE, item.payload.type)
            put(MediaStore.Images.Media.RELATIVE_PATH, "${Environment.DIRECTORY_PICTURES}/ClipShare")
        }
        runCatching {
            val uri = contentResolver.insert(MediaStore.Images.Media.EXTERNAL_CONTENT_URI, values) ?: return
            contentResolver.openOutputStream(uri)?.use { it.write(bytes) }
        }.onFailure { android.util.Log.w("ClipShare", "Gallery save failed", it) }
    }

    private fun clipboardPreview(item: PlainItem): String = when {
        item.payload.type.startsWith("image/") -> "Image (${item.payload.size / 1024} KB)"
        else -> item.payload.text.orEmpty().take(50)
    }

    private fun sendAck(messageId: String, toDevice: String) {
        if (!::wsClient.isInitialized || !wsClient.isConnected()) {
            return
        }

        val deviceId = PrefsHelper.getDeviceId(this)
        val ackMessage = mapOf(
            "type" to "ack",
            "id" to messageId,
            "from" to deviceId,
            "to" to toDevice,
            "status" to "ok"
        )

        wsClient.send(ackMessage) { _ -> }
    }

    private fun readSharedImage(intent: Intent): ClipboardContent.Image? {
        @Suppress("DEPRECATION")
        val uri = intent.getParcelableExtra(Intent.EXTRA_STREAM) as? Uri ?: return null
        val mimeType = (intent.type ?: contentResolver.getType(uri))?.lowercase() ?: return null
        if (!ClipboardObserver.isSupportedImage(mimeType)) {
            showToast("Only PNG and JPEG images are supported")
            return null
        }
        val bytes = contentResolver.openInputStream(uri)?.use { input ->
            val output = java.io.ByteArrayOutputStream()
            val buffer = ByteArray(DEFAULT_BUFFER_SIZE)
            var total = 0
            while (true) {
                val read = input.read(buffer)
                if (read == -1) break
                total += read
                if (total > ClipboardObserver.MAX_IMAGE_BYTES) {
                    showToast("Image is too large (max 5 MiB)")
                    return@use null
                }
                output.write(buffer, 0, read)
            }
            output.toByteArray()
        } ?: return null
        return ClipboardContent.Image(mimeType, bytes)
    }

    // MARK: - Outbox Processing

    private suspend fun processOutbox() {
        val pendingItems = database.outboxDao().getPendingItems()
        for (item in pendingItems) {
            sendItem(item)
            delay(100) // Small delay between sends
        }
    }

    private fun sendItem(item: OutboxItem) {
        if (!::wsClient.isInitialized || !wsClient.isConnected()) {
            return
        }

        // Create route message
        val deviceId = PrefsHelper.getDeviceId(this)
        val peerDeviceId = PrefsHelper.getPeerDeviceId(this) ?: return

        val routeMessage = mapOf(
            "id" to item.id,
            "type" to "route",
            "from" to deviceId,
            "to" to peerDeviceId,
            "data" to item.envelopeJson,
            "qos" to "at-least-once"
        )

        // Queue status changes only after the recipient's ACK returns through
        // the relay. A successful socket write merely means the local client
        // accepted the frame, not that the other device received it.
        wsClient.send(routeMessage) { _ -> }
    }

    // MARK: - Notification

    private fun createNotification(connected: Boolean): Notification {
        val intent = Intent(this, MainActivity::class.java)
        val pendingIntent = PendingIntent.getActivity(
            this, 0, intent,
            PendingIntent.FLAG_IMMUTABLE
        )
        val sendClipboardIntent = Intent(this, SendToMacActivity::class.java).apply {
            action = SendToMacActivity.ACTION_SEND_CURRENT_CLIPBOARD
        }
        val sendClipboardPendingIntent = PendingIntent.getActivity(
            this, 1, sendClipboardIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        val status = if (connected) "Connected" else "Disconnected"
        val icon = if (connected) R.drawable.ic_check else R.drawable.ic_sync

        return NotificationCompat.Builder(this, ClipboardApp.CHANNEL_ID)
            .setContentTitle("Clipboard Sync")
            .setContentText(status)
            .setSmallIcon(icon)
            .setOngoing(true)
            .setContentIntent(pendingIntent)
            .addAction(R.drawable.ic_sync, "Send clipboard", sendClipboardPendingIntent)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .build()
    }

    private fun updateNotification(connected: Boolean) {
        val notification = createNotification(connected)
        val notificationManager = getSystemService(NotificationManager::class.java)
        notificationManager.notify(NOTIFICATION_ID, notification)
    }

    private fun showNotification(title: String, body: String) {
        val intent = Intent(this, MainActivity::class.java)
        val pendingIntent = PendingIntent.getActivity(
            this, 0, intent,
            PendingIntent.FLAG_IMMUTABLE
        )

        val notification = NotificationCompat.Builder(this, ClipboardApp.CHANNEL_ID)
            .setContentTitle(title)
            .setContentText(body)
            .setSmallIcon(R.drawable.ic_sync)
            .setContentIntent(pendingIntent)
            .setAutoCancel(true)
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .build()

        val notificationManager = getSystemService(NotificationManager::class.java)
        notificationManager.notify(NOTIFICATION_ID + 1, notification)
    }

    private fun showToast(message: String) {
        mainHandler.post {
            Toast.makeText(this@ClipboardSyncService, message, Toast.LENGTH_SHORT).show()
        }
    }

    companion object {
        private const val NOTIFICATION_ID = 1001
        private const val OUTBOX_RETENTION_MS = 24 * 60 * 60 * 1000L
        private const val MAX_TEXT_BYTES = 64 * 1024
        private const val ACTION_SYNC_CURRENT_CLIPBOARD =
            "com.clipshare.android.action.SYNC_CURRENT_CLIPBOARD"
        private const val ACTION_SEND_TEXT = "com.clipshare.android.action.SEND_TEXT"
        private const val ACTION_SEND_IMAGE = "com.clipshare.android.action.SEND_IMAGE"
        private const val EXTRA_TEXT = "com.clipshare.android.extra.TEXT"

        @Suppress("DEPRECATION")
        fun isRunning(context: Context): Boolean {
            val activityManager =
                context.getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
            return activityManager.getRunningServices(Int.MAX_VALUE).any {
                it.service.className == ClipboardSyncService::class.java.name
            }
        }

        fun start(context: Context) {
            PrefsHelper.setSyncEnabled(context, true)
            val intent = Intent(context, ClipboardSyncService::class.java)
            context.startForegroundService(intent)
        }

        fun stop(context: Context) {
            PrefsHelper.setSyncEnabled(context, false)
            val intent = Intent(context, ClipboardSyncService::class.java)
            context.stopService(intent)
        }

        fun syncCurrentClipboard(context: Context) {
            if (!PrefsHelper.isSyncEnabled(context)) return
            val intent = Intent(context, ClipboardSyncService::class.java).apply {
                action = ACTION_SYNC_CURRENT_CLIPBOARD
            }
            context.startForegroundService(intent)
        }

        fun sendText(context: Context, text: String) {
            if (!PrefsHelper.isSyncEnabled(context)) return
            context.startForegroundService(Intent(context, ClipboardSyncService::class.java).apply {
                action = ACTION_SEND_TEXT
                putExtra(EXTRA_TEXT, text)
            })
        }

        fun sendImage(context: Context, uri: Uri, mimeType: String?) {
            if (!PrefsHelper.isSyncEnabled(context)) return
            context.startForegroundService(Intent(context, ClipboardSyncService::class.java).apply {
                action = ACTION_SEND_IMAGE
                type = mimeType
                putExtra(Intent.EXTRA_STREAM, uri)
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            })
        }
    }
}

// Data classes

data class PlainItem(
    val id: String,
    val seq: Int,
    val tsMs: Long,
    val kind: String,
    val payload: Payload,
    val meta: Meta?
) {
    data class Payload(
        val type: String,
        val size: Int,
        val text: String?,
        val data: String?
    )

    data class Meta(
        val app: String?,
        val network: String?,
        val lang: String?
    )
}

data class RouteMessage(
    val id: String?,
    val type: String,
    val from: String,
    val to: String,
    val data: String?,
    val qos: String?,
    val status: String?
)
