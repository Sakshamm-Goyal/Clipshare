package com.clipshare.android.ui

import android.os.Bundle
import android.os.Build
import android.widget.TextView
import android.widget.Toast
import androidx.appcompat.app.AppCompatActivity
import androidx.camera.core.*
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.camera.view.PreviewView
import androidx.core.content.ContextCompat
import com.clipshare.android.R
import com.clipshare.android.crypto.CryptoBox
import com.clipshare.android.service.ClipboardSyncService
import com.clipshare.android.util.PrefsHelper
import com.google.mlkit.vision.barcode.BarcodeScanning
import com.google.mlkit.vision.barcode.common.Barcode
import com.google.mlkit.vision.common.InputImage
import okhttp3.*
import org.json.JSONObject
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

class PairingActivity : AppCompatActivity() {

    private lateinit var previewView: PreviewView
    private lateinit var instructionText: TextView
    private lateinit var cameraExecutor: ExecutorService
    private lateinit var cryptoBox: CryptoBox

    private var isProcessingQR = false
    private var webSocket: WebSocket? = null

    private val okHttpClient = OkHttpClient.Builder()
        .readTimeout(30, TimeUnit.SECONDS)
        .build()

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_pairing)

        previewView = findViewById(R.id.preview_view)
        instructionText = findViewById(R.id.instruction_text)

        cameraExecutor = Executors.newSingleThreadExecutor()
        cryptoBox = CryptoBox(this)

        instructionText.text = "Scan QR code from Mac app"

        startCamera()
    }

    private fun startCamera() {
        val cameraProviderFuture = ProcessCameraProvider.getInstance(this)

        cameraProviderFuture.addListener({
            val cameraProvider = cameraProviderFuture.get()

            val preview = Preview.Builder().build().also {
                it.setSurfaceProvider(previewView.surfaceProvider)
            }

            val imageAnalyzer = ImageAnalysis.Builder()
                .setBackpressureStrategy(ImageAnalysis.STRATEGY_KEEP_ONLY_LATEST)
                .build()
                .also {
                    it.setAnalyzer(cameraExecutor) { imageProxy ->
                        processImageProxy(imageProxy)
                    }
                }

            val cameraSelector = CameraSelector.DEFAULT_BACK_CAMERA

            try {
                cameraProvider.unbindAll()
                cameraProvider.bindToLifecycle(
                    this, cameraSelector, preview, imageAnalyzer
                )
            } catch (e: Exception) {
                Toast.makeText(this, "Failed to start camera: ${e.message}", Toast.LENGTH_LONG).show()
            }

        }, ContextCompat.getMainExecutor(this))
    }

    @androidx.camera.core.ExperimentalGetImage
    private fun processImageProxy(imageProxy: ImageProxy) {
        if (isProcessingQR) {
            imageProxy.close()
            return
        }

        val mediaImage = imageProxy.image
        if (mediaImage != null) {
            val image = InputImage.fromMediaImage(mediaImage, imageProxy.imageInfo.rotationDegrees)

            val scanner = BarcodeScanning.getClient()
            scanner.process(image)
                .addOnSuccessListener { barcodes ->
                    for (barcode in barcodes) {
                        if (barcode.format == Barcode.FORMAT_QR_CODE) {
                            barcode.rawValue?.let { qrData ->
                                handleQRData(qrData)
                            }
                        }
                    }
                }
                .addOnCompleteListener {
                    imageProxy.close()
                }
        } else {
            imageProxy.close()
        }
    }

    private fun handleQRData(qrData: String) {
        if (isProcessingQR) return
        isProcessingQR = true

        android.util.Log.d("ClipShare", "=== QR Code Scanned ===")

        runOnUiThread {
            instructionText.text = "QR code detected, connecting..."
        }

        try {
            // Decode base64 JSON
            val jsonString = String(android.util.Base64.decode(qrData, android.util.Base64.DEFAULT))
            val json = JSONObject(jsonString)

            val serverUrl = json.getString("server")
            val token = json.getString("token")
            val macDeviceId = json.getString("device_id")
            val macDevicePub = json.getString("device_pub")

            android.util.Log.d("ClipShare", "Server URL: $serverUrl")

            // Set Mac's public key for encryption
            cryptoBox.setPeerPublicKey(macDevicePub)

            // Connect to pairing WebSocket with role=peer
            connectToPairingWebSocket(serverUrl, token, macDeviceId, macDevicePub)

        } catch (e: Exception) {
            runOnUiThread {
                instructionText.text = "✗ Invalid QR code. Please try again."
                Toast.makeText(this, "Failed to parse QR: ${e.message}", Toast.LENGTH_LONG).show()
            }
            isProcessingQR = false
        }
    }

    // Store original server URL for later use (volatile for thread safety)
    @Volatile
    private var originalServerUrl: String = ""

    private fun connectToPairingWebSocket(serverUrl: String, token: String, macDeviceId: String, macDevicePub: String) {
        android.util.Log.d("ClipShare", "=== connectToPairingWebSocket ===")
        android.util.Log.d("ClipShare", "Input serverUrl: $serverUrl")

        // Save original server URL (from QR code) for clipboard sync
        // Extract base URL without /pair path
        originalServerUrl = if (serverUrl.contains("/pair")) {
            serverUrl.substringBefore("/pair")
        } else {
            serverUrl.substringBefore("?")
        }
        android.util.Log.d("ClipShare", "Saved originalServerUrl (base): $originalServerUrl")

        // Convert server URL for WebSocket (ensure ws:// or wss://)
        var wsUrl = serverUrl
        if (!wsUrl.contains("?token=")) {
            wsUrl += "?token=$token&role=peer"
        } else {
            wsUrl += "&role=peer"
        }

        android.util.Log.d("ClipShare", "Final WebSocket URL: $wsUrl")

        runOnUiThread {
            instructionText.text = "Connecting to server..."
        }

        val request = Request.Builder()
            .url(wsUrl)
            .build()

        android.util.Log.d("ClipShare", "Creating WebSocket connection...")

        webSocket = okHttpClient.newWebSocket(request, object : WebSocketListener() {
            override fun onOpen(webSocket: WebSocket, response: Response) {
                android.util.Log.d("ClipShare", "✓ WebSocket connected!")
                // Send our device info
                val androidDeviceId = PrefsHelper.getDeviceId(this@PairingActivity)
                val publicKey = cryptoBox.getPublicKeyBase64() ?: ""
                val deviceName = Build.MODEL

                val peerInfo = JSONObject().apply {
                    put("device_id", androidDeviceId)
                    put("device_name", deviceName)
                    put("public_key", publicKey)
                    put("platform", "android")
                }

                webSocket.send(peerInfo.toString())

                runOnUiThread {
                    instructionText.text = "Completing pairing..."
                }
            }

            override fun onMessage(webSocket: WebSocket, text: String) {
                try {
                    val response = JSONObject(text)

                    if (response.optString("error").isNotEmpty()) {
                        runOnUiThread {
                            instructionText.text = "✗ Pairing failed: ${response.getString("error")}"
                            Toast.makeText(this@PairingActivity, "Pairing failed", Toast.LENGTH_LONG).show()
                        }
                        isProcessingQR = false
                        return
                    }

                    if (response.optString("status") == "success") {
                        val peerToken = response.getString("peer_token")
                        val originalDevice = response.getString("original_device")
                        val peerDevice = response.getString("peer_device")
                        val devicePub = response.optString("device_pub", macDevicePub)
                        if (devicePub != macDevicePub) {
                            throw SecurityException("Pairing response did not match the QR device key")
                        }

                        // The public key scanned from the QR code is the
                        // trust anchor. Never replace it with server data.
                        cryptoBox.setPeerPublicKey(macDevicePub)
                        cryptoBox.savePairingInfo(peerDevice, originalDevice)

                        // Construct the WebSocket URL for normal messaging
                        // originalServerUrl is already the base URL like "ws://192.168.13.194:8080"
                        val messageWsUrl = "$originalServerUrl/ws"

                        android.util.Log.d("ClipShare", "originalServerUrl: $originalServerUrl")
                        android.util.Log.d("ClipShare", "Final messageWsUrl to save: $messageWsUrl")

                        // Clear old preferences first, then save new pairing info
                        PrefsHelper.clearAll(this@PairingActivity)
                        // Keep the ID that the relay authenticated in the JWT.
                        // Generating a new local ID here would make incoming
                        // routes fail the recipient check after every pairing.
                        PrefsHelper.saveDeviceId(this@PairingActivity, peerDevice)
                        PrefsHelper.saveDeviceToken(this@PairingActivity, peerToken)
                        PrefsHelper.savePeerDeviceId(this@PairingActivity, originalDevice)
                        PrefsHelper.saveServerUrl(this@PairingActivity, messageWsUrl)
                        PrefsHelper.setIsPaired(this@PairingActivity, true)

                        // Verify what was saved
                        val savedUrl = PrefsHelper.getServerUrl(this@PairingActivity)
                        android.util.Log.d("ClipShare", "VERIFIED saved server URL: $savedUrl")

                        runOnUiThread {
                            Toast.makeText(this@PairingActivity, "✓ Paired! Starting sync...", Toast.LENGTH_LONG).show()
                            // Auto-start clipboard sync service
                            ClipboardSyncService.start(this@PairingActivity)
                            finish()
                        }
                    }
                } catch (e: Exception) {
                    runOnUiThread {
                        instructionText.text = "✗ Invalid response from server"
                    }
                    isProcessingQR = false
                }
            }

            override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) {
                android.util.Log.e("ClipShare", "✗ WebSocket FAILED: ${t.message}", t)
                runOnUiThread {
                    instructionText.text = "✗ Connection failed: ${t.message}"
                    Toast.makeText(this@PairingActivity, "Connection failed: ${t.message}", Toast.LENGTH_LONG).show()
                }
                isProcessingQR = false
            }

            override fun onClosed(webSocket: WebSocket, code: Int, reason: String) {
                android.util.Log.d("ClipShare", "WebSocket closed: code=$code, reason=$reason")
                // Normal closure after pairing complete is expected (code 1000)
                if (code != 1000) {
                    runOnUiThread {
                        instructionText.text = "Connection closed: $reason"
                    }
                    isProcessingQR = false
                }
            }
        })
    }

    override fun onDestroy() {
        super.onDestroy()
        cameraExecutor.shutdown()
        webSocket?.close(1000, "Activity destroyed")
    }
}
