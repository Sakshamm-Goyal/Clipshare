package com.clipshare.android.service

import com.google.gson.Gson
import kotlinx.coroutines.*
import okhttp3.*
import okhttp3.Request
import java.util.concurrent.TimeUnit
import kotlin.math.min
import kotlin.math.pow

class WebSocketClient(
    private val serverUrl: String,
    private val deviceToken: String,
    private val onMessage: (String) -> Unit,
    private val onConnected: () -> Unit,
    private val onDisconnected: () -> Unit
) {
    private val client = OkHttpClient.Builder()
        .readTimeout(0, TimeUnit.MILLISECONDS) // No timeout for WebSocket
        .build()

    private var webSocket: WebSocket? = null
    @Volatile private var isConnected = false
    @Volatile private var shouldReconnect = true

    private var reconnectAttempts = 0
    private val scope = CoroutineScope(Dispatchers.IO + SupervisorJob())
    private var reconnectJob: Job? = null

    private val gson = Gson()

    fun connect() {
        shouldReconnect = true
        android.util.Log.d("ClipShare", "Connecting to clipboard relay")

        val request = Request.Builder()
            .url(serverUrl)
            .addHeader("Sec-WebSocket-Protocol", "Bearer.$deviceToken")
            .build()

        webSocket = client.newWebSocket(request, object : WebSocketListener() {
            override fun onOpen(webSocket: WebSocket, response: Response) {
                android.util.Log.d("ClipShare", "✓ WebSocket CONNECTED!")
                isConnected = true
                reconnectAttempts = 0
                onConnected()
            }

            override fun onMessage(webSocket: WebSocket, text: String) {
                onMessage(text)
            }

            override fun onClosing(webSocket: WebSocket, code: Int, reason: String) {
                android.util.Log.d("ClipShare", "WebSocket closing: $code - $reason")
                webSocket.close(1000, null)
            }

            override fun onClosed(webSocket: WebSocket, code: Int, reason: String) {
                android.util.Log.d("ClipShare", "WebSocket closed: $code - $reason")
                handleDisconnection()
            }

            override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) {
                android.util.Log.w("ClipShare", "WebSocket failed (HTTP ${response?.code ?: "n/a"}): ${t.message}")
                if (response?.code == 401 || response?.code == 403) {
                    // An expired or revoked token cannot recover through retry.
                    shouldReconnect = false
                }
                handleDisconnection()
            }
        })
    }

    fun disconnect() {
        shouldReconnect = false
        reconnectJob?.cancel()
        webSocket?.close(1000, "User disconnect")
        webSocket = null
        isConnected = false
    }

    fun send(message: Map<String, Any>, callback: (Boolean) -> Unit) {
        if (!isConnected) {
            callback(false)
            return
        }

        val json = gson.toJson(message)
        val success = webSocket?.send(json) ?: false
        callback(success)
    }

    fun isConnected(): Boolean = isConnected

    private fun handleDisconnection() {
        isConnected = false
        onDisconnected()

        if (shouldReconnect) {
            attemptReconnect()
        }
    }

    private fun attemptReconnect() {
        // Exponential backoff with jitter
        val baseDelay = 2.0.pow(reconnectAttempts.coerceAtMost(5).toDouble()).toLong()
        val maxDelay = 30000L // 30 seconds
        val jitter = (Math.random() * 1000).toLong()
        val delay = min(baseDelay * 1000 + jitter, maxDelay)

        reconnectAttempts++

        reconnectJob?.cancel()
        reconnectJob = scope.launch {
            delay(delay)
            if (shouldReconnect) {
                connect()
            }
        }
    }
}
