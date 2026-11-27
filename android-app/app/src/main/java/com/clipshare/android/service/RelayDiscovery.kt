package com.clipshare.android.service

import android.content.Context
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.os.Handler
import android.os.Looper
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Finds the Mac relay on the LAN via Bonjour (`dns-sd -R ClipShare _clipshare._tcp`),
 * so a changed Wi-Fi IP doesn't break sync. Calls [onFound] at most once with "ws://host:port/ws".
 */
object RelayDiscovery {
    private const val SERVICE_TYPE = "_clipshare._tcp."
    private const val TIMEOUT_MS = 10_000L

    fun find(context: Context, onFound: (String) -> Unit) {
        val nsd = context.getSystemService(Context.NSD_SERVICE) as NsdManager
        val done = AtomicBoolean(false)
        lateinit var listener: NsdManager.DiscoveryListener

        fun finish() {
            if (done.compareAndSet(false, true)) runCatching { nsd.stopServiceDiscovery(listener) }
        }

        listener = object : NsdManager.DiscoveryListener {
            override fun onServiceFound(info: NsdServiceInfo) {
                if (done.get() || !info.serviceType.startsWith("_clipshare._tcp")) return
                @Suppress("DEPRECATION")
                nsd.resolveService(info, object : NsdManager.ResolveListener {
                    override fun onResolveFailed(info: NsdServiceInfo, errorCode: Int) {}
                    override fun onServiceResolved(info: NsdServiceInfo) {
                        @Suppress("DEPRECATION")
                        val host = info.host?.hostAddress ?: return
                        if (host.contains(':')) return // ponytail: IPv4 only, matches relay QR URLs
                        if (!done.get()) {
                            finish()
                            onFound("ws://$host:${info.port}/ws")
                        }
                    }
                })
            }
            override fun onServiceLost(info: NsdServiceInfo) {}
            override fun onDiscoveryStarted(serviceType: String) {}
            override fun onDiscoveryStopped(serviceType: String) {}
            override fun onStartDiscoveryFailed(serviceType: String, errorCode: Int) { done.set(true) }
            override fun onStopDiscoveryFailed(serviceType: String, errorCode: Int) {}
        }

        runCatching { nsd.discoverServices(SERVICE_TYPE, NsdManager.PROTOCOL_DNS_SD, listener) }
            .onFailure { return }
        Handler(Looper.getMainLooper()).postDelayed(::finish, TIMEOUT_MS)
    }
}
