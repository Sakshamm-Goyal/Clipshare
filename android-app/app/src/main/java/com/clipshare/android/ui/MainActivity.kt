package com.clipshare.android.ui

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.provider.Settings
import android.widget.Button
import android.widget.TextView
import android.view.View
import android.widget.Toast
import androidx.appcompat.app.AppCompatActivity
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import com.clipshare.android.R
import com.clipshare.android.service.ClipboardSyncService
import com.clipshare.android.util.PrefsHelper

class MainActivity : AppCompatActivity() {

    private lateinit var statusText: TextView
    private lateinit var startButton: Button
    private lateinit var stopButton: Button
    private lateinit var syncNowButton: Button
    private lateinit var pairButton: Button
    private lateinit var batteryButton: Button

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_main)

        // Initialize views
        statusText = findViewById(R.id.status_text)
        startButton = findViewById(R.id.start_button)
        stopButton = findViewById(R.id.stop_button)
        syncNowButton = findViewById(R.id.sync_now_button)
        pairButton = findViewById(R.id.pair_button)
        batteryButton = findViewById(R.id.battery_button)

        // Setup click listeners
        startButton.setOnClickListener { startSync() }
        stopButton.setOnClickListener { stopSync() }
        syncNowButton.setOnClickListener { syncCurrentClipboard() }
        pairButton.setOnClickListener { startPairing() }
        batteryButton.setOnClickListener { requestBatteryOptimization() }

        // Check pairing status
        updateUI()

        // Request notification permission (Android 13+)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            if (ContextCompat.checkSelfPermission(
                    this,
                    Manifest.permission.POST_NOTIFICATIONS
                ) != PackageManager.PERMISSION_GRANTED
            ) {
                ActivityCompat.requestPermissions(
                    this,
                    arrayOf(Manifest.permission.POST_NOTIFICATIONS),
                    REQUEST_NOTIFICATION_PERMISSION
                )
            }
        }
    }

    override fun onResume() {
        super.onResume()
        ensureEnabledSyncServiceIsRunning()
        updateUI()
    }

    private fun ensureEnabledSyncServiceIsRunning() {
        val isPaired = PrefsHelper.isPaired(this)
        val isSyncEnabled = PrefsHelper.isSyncEnabled(this)
        val isServiceRunning = ClipboardSyncService.isRunning(this)
        android.util.Log.d(
            "ClipShare",
            "Resume sync recovery paired=$isPaired enabled=$isSyncEnabled running=$isServiceRunning"
        )
        if (SyncStartupPolicy.shouldEnsureService(isPaired, isSyncEnabled, isServiceRunning)) {
            ClipboardSyncService.start(this)
        }
        if (isPaired && isSyncEnabled && !askedBatteryThisProcess) {
            askedBatteryThisProcess = true
            requestBatteryExemption()
        }
    }

    private fun updateUI() {
        val state = SyncUiState.from(
            isPaired = PrefsHelper.isPaired(this),
            isSyncEnabled = PrefsHelper.isSyncEnabled(this)
        )
        statusText.text = when (state.status) {
            SyncUiState.Status.NOT_PAIRED -> "● Pair a Mac to begin"
            SyncUiState.Status.PAUSED -> "● Mac paired — sync paused"
            SyncUiState.Status.RUNNING -> "● Mac connected"
        }
        startButton.visibility = if (state.status == SyncUiState.Status.PAUSED) View.VISIBLE else View.GONE
        syncNowButton.visibility = if (state.status == SyncUiState.Status.RUNNING) View.VISIBLE else View.GONE
        stopButton.visibility = if (state.stopEnabled) View.VISIBLE else View.GONE
        startButton.isEnabled = state.startEnabled
        stopButton.isEnabled = state.stopEnabled
        syncNowButton.isEnabled = state.sendEnabled
        pairButton.text = if (state.isRePair) "Manage pairing" else "Pair with Mac"
    }

    private companion object { var askedBatteryThisProcess = false }

    /** Without this, Doze/OEM battery savers kill the socket and Mac → Android stalls. */
    private fun requestBatteryExemption() {
        val pm = getSystemService(android.os.PowerManager::class.java)
        if (pm.isIgnoringBatteryOptimizations(packageName)) return
        runCatching {
            startActivity(Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS, Uri.parse("package:$packageName")))
        }
    }

    private fun startSync() {
        if (!PrefsHelper.isPaired(this)) {
            Toast.makeText(this, "Please pair device first", Toast.LENGTH_SHORT).show()
            return
        }

        ClipboardSyncService.start(this)
        requestBatteryExemption()
        Toast.makeText(this, "Clipboard sync started", Toast.LENGTH_SHORT).show()
        updateUI()
    }

    private fun stopSync() {
        ClipboardSyncService.stop(this)
        Toast.makeText(this, "Clipboard sync stopped", Toast.LENGTH_SHORT).show()
        updateUI()
    }

    private fun syncCurrentClipboard() {
        if (!PrefsHelper.isPaired(this) || !PrefsHelper.isSyncEnabled(this)) return
        ClipboardSyncService.syncCurrentClipboard(this)
        Toast.makeText(this, "Sending current clipboard", Toast.LENGTH_SHORT).show()
    }

    private fun startPairing() {
        // Check camera permission for QR scanner
        if (ContextCompat.checkSelfPermission(this, Manifest.permission.CAMERA)
            != PackageManager.PERMISSION_GRANTED
        ) {
            ActivityCompat.requestPermissions(
                this,
                arrayOf(Manifest.permission.CAMERA),
                REQUEST_CAMERA_PERMISSION
            )
        } else {
            launchPairingActivity()
        }
    }

    private fun launchPairingActivity() {
        val intent = Intent(this, PairingActivity::class.java)
        startActivity(intent)
    }

    private fun requestBatteryOptimization() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            val intent = Intent()
            intent.action = Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS
            intent.data = Uri.parse("package:$packageName")
            startActivity(intent)
        }
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)

        when (requestCode) {
            REQUEST_CAMERA_PERMISSION -> {
                if (grantResults.isNotEmpty() && grantResults[0] == PackageManager.PERMISSION_GRANTED) {
                    launchPairingActivity()
                } else {
                    Toast.makeText(this, "Camera permission required for QR scanning", Toast.LENGTH_LONG).show()
                }
            }
            REQUEST_NOTIFICATION_PERMISSION -> {
                // Handle notification permission result
            }
        }
    }

    companion object {
        private const val REQUEST_CAMERA_PERMISSION = 100
        private const val REQUEST_NOTIFICATION_PERMISSION = 101
    }
}
