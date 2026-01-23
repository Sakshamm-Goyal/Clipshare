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
    private var isConnected = false
    private var shouldReconnect = true

    private var reconnectAttempts = 0
    private val maxReconnectAttempts = 10

    private val scope = CoroutineScope(Dispatchers.IO + SupervisorJob())
    private var reconnectJob: Job? = null

    private val gson = Gson()

    fun connect() {
        android.util.Log.d("ClipShare", "=== WebSocketClient.connect() ===")
        android.util.Log.d("ClipShare", "Server URL: $serverUrl")
        android.util.Log.d("ClipShare", "Token (first 30 chars): ${deviceToken.take(30)}...")

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
                android.util.Log.d("ClipShare", "← Received message: ${text.take(100)}...")
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
                android.util.Log.e("ClipShare", "✗ WebSocket FAILED: ${t.message}", t)
                android.util.Log.e("ClipShare", "Response code: ${response?.code}, message: ${response?.message}")
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

        if (shouldReconnect && reconnectAttempts < maxReconnectAttempts) {
            attemptReconnect()
        }
    }

    private fun attemptReconnect() {
        // Exponential backoff with jitter
        val baseDelay = 2.0.pow(reconnectAttempts.toDouble()).toLong()
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
