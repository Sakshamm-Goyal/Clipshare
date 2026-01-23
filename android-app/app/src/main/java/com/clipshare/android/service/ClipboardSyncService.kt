package com.clipshare.android.service

import android.app.Notification
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.PowerManager
import android.widget.Toast
import androidx.core.app.NotificationCompat
import com.clipshare.android.ClipboardApp
import com.clipshare.android.R
import com.clipshare.android.crypto.CryptoBox
import com.clipshare.android.data.AppDatabase
import com.clipshare.android.data.OutboxItem
import com.clipshare.android.ui.MainActivity
import com.clipshare.android.util.PrefsHelper
import com.google.gson.Gson
import kotlinx.coroutines.*
import java.util.*

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
    private var lastClipboardHash: Int = 0
    private var sequenceNumber: Int = 0

    // For echo prevention
    private var lastReceivedContent: String? = null
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
        clipboardObserver = ClipboardObserver { clipText ->
            handleClipboardChange(clipText)
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
                },
                onDisconnected = {
                    updateNotification(connected = false)
                }
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
        clipboardObserver.start(clipboardManager)

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
            },
            onDisconnected = {
                updateNotification(connected = false)
            }
        )
    }

    override fun onBind(intent: Intent?): IBinder? = null

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

    private fun handleClipboardChange(clipText: String) {
        // Check for echo (content we just received from peer)
        if (clipText == lastReceivedContent &&
            System.currentTimeMillis() - lastReceivedTime < echoPrevention) {
            return
        }

        // Debounce rapid changes
        val currentHash = clipText.hashCode()
        if (currentHash == lastClipboardHash) {
            return
        }
        lastClipboardHash = currentHash

        // Check size limit (64KB)
        if (clipText.toByteArray().size > 64 * 1024) {
            showToast("Clipboard item too large (max 64KB)")
            return
        }

        // Check if we have a session key
        if (!cryptoBox.hasSessionKey()) {
            return // Not paired yet
        }

        // Create plain item
        val plainItem = createPlainItem(clipText)

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

    private fun createPlainItem(text: String): PlainItem {
        sequenceNumber++
        val deviceId = PrefsHelper.getDeviceId(this)

        return PlainItem(
            id = UUID.randomUUID().toString(),
            seq = sequenceNumber,
            tsMs = System.currentTimeMillis(),
            kind = "clipboard_item",
            payload = PlainItem.Payload(
                type = "text/plain",
                size = text.toByteArray().size,
                text = text
            ),
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

            // Decrypt the envelope
            val plainItem = try {
                cryptoBox.decrypt(routeMessage.data)
            } catch (e: Exception) {
                showToast("Failed to decrypt message")
                return
            }

            // Mark as received to prevent echo
            lastReceivedContent = plainItem.payload.text
            lastReceivedTime = System.currentTimeMillis()

            // Check auto-overwrite preference
            val autoOverwrite = PrefsHelper.isAutoOverwrite(this)

            if (autoOverwrite) {
                // Write directly to clipboard
                mainHandler.post {
                    writeToClipboard(plainItem.payload.text)
                    showToast("Clipboard synced: ${plainItem.payload.text.take(30)}...")
                }
            } else {
                // Stage the item and notify user
                mainHandler.post {
                    stagedItem = plainItem
                    showNotification(
                        "Clipboard Ready",
                        "From ${plainItem.meta?.app ?: "Mac"}: ${plainItem.payload.text.take(50)}..."
                    )
                }
            }

            // Send ACK
            sendAck(plainItem.id, routeMessage.from)

        } catch (e: Exception) {
            // Not a valid message format, ignore
        }
    }

    private var stagedItem: PlainItem? = null

    private fun writeToClipboard(text: String) {
        val clip = ClipData.newPlainText("ClipShare", text)
        clipboardManager.setPrimaryClip(clip)
        lastClipboardHash = text.hashCode()  // Prevent echo
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
            "type" to "route",
            "from" to deviceId,
            "to" to peerDeviceId,
            "data" to item.envelopeJson,
            "qos" to "at-least-once"
        )

        wsClient.send(routeMessage) { success ->
            if (success) {
                serviceScope.launch {
                    database.outboxDao().markDelivered(item.id)

                    // Prune old delivered items
                    val cutoff = System.currentTimeMillis() - (24 * 60 * 60 * 1000) // 24 hours
                    database.outboxDao().deleteOldDelivered(cutoff)
                }
            }
        }
    }

    // MARK: - Notification

    private fun createNotification(connected: Boolean): Notification {
        val intent = Intent(this, MainActivity::class.java)
        val pendingIntent = PendingIntent.getActivity(
            this, 0, intent,
            PendingIntent.FLAG_IMMUTABLE
        )

        val status = if (connected) "Connected" else "Disconnected"
        val icon = if (connected) R.drawable.ic_check else R.drawable.ic_sync

        return NotificationCompat.Builder(this, ClipboardApp.CHANNEL_ID)
            .setContentTitle("Clipboard Sync")
            .setContentText(status)
            .setSmallIcon(icon)
            .setOngoing(true)
            .setContentIntent(pendingIntent)
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

        fun start(context: Context) {
            val intent = Intent(context, ClipboardSyncService::class.java)
            context.startForegroundService(intent)
        }

        fun stop(context: Context) {
            val intent = Intent(context, ClipboardSyncService::class.java)
            context.stopService(intent)
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
        val text: String
    )

    data class Meta(
        val app: String?,
        val network: String?,
        val lang: String?
    )
}

data class RouteMessage(
    val type: String,
    val from: String,
    val to: String,
    val data: String,
    val qos: String?
)
