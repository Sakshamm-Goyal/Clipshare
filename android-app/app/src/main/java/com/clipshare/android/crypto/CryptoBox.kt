package com.clipshare.android.crypto

import android.content.Context
import android.util.Base64
import com.clipshare.android.service.PlainItem
import com.google.crypto.tink.subtle.X25519
import com.google.crypto.tink.subtle.Hkdf
import com.google.crypto.tink.subtle.ChaCha20Poly1305
import com.google.gson.Gson
import java.security.SecureRandom

/**
 * CryptoBox handles E2E encryption using Curve25519 ECDH + HKDF + ChaCha20-Poly1305
 * Compatible with the macOS Swift implementation
 */
class CryptoBox(private val context: Context) {

    private val gson = Gson()
    private val prefs = context.getSharedPreferences("clipshare_crypto", Context.MODE_PRIVATE)

    // Our Curve25519 keypair
    private var privateKey: ByteArray? = null
    private var publicKey: ByteArray? = null

    // Peer's public key
    private var peerPublicKey: ByteArray? = null

    // Derived session key (32 bytes for ChaCha20)
    private var sessionKey: ByteArray? = null

    // HKDF parameters (must match macOS implementation)
    private val hkdfSalt = "ClipShare-Salt-2024".toByteArray(Charsets.UTF_8)
    private val hkdfInfo = "ClipShare-E2E-v1".toByteArray(Charsets.UTF_8)

    init {
        loadOrGenerateKeys()
    }

    /**
     * Load existing keys from storage or generate new ones
     */
    private fun loadOrGenerateKeys() {
        val storedPrivateKey = prefs.getString("device_private_key", null)
        val storedPublicKey = prefs.getString("device_public_key", null)

        if (storedPrivateKey != null && storedPublicKey != null) {
            privateKey = Base64.decode(storedPrivateKey, Base64.NO_WRAP)
            publicKey = Base64.decode(storedPublicKey, Base64.NO_WRAP)
        } else {
            generateNewKeyPair()
        }

        // Load peer public key if available
        val storedPeerKey = prefs.getString("peer_public_key", null)
        if (storedPeerKey != null) {
            peerPublicKey = Base64.decode(storedPeerKey, Base64.NO_WRAP)
            deriveSessionKey()
        }
    }

    /**
     * Generate a new Curve25519 keypair
     */
    fun generateNewKeyPair() {
        try {
            // Generate Curve25519 keypair using Tink
            privateKey = X25519.generatePrivateKey()
            publicKey = X25519.publicFromPrivate(privateKey!!)

            // Store keys
            prefs.edit()
                .putString("device_private_key", Base64.encodeToString(privateKey, Base64.NO_WRAP))
                .putString("device_public_key", Base64.encodeToString(publicKey, Base64.NO_WRAP))
                .apply()

        } catch (e: Exception) {
            throw RuntimeException("Failed to generate Curve25519 keypair: ${e.message}")
        }
    }

    /**
     * Get our public key as base64 for pairing
     */
    fun getPublicKeyBase64(): String? {
        return publicKey?.let { Base64.encodeToString(it, Base64.NO_WRAP) }
    }

    /**
     * Set the peer's public key (from QR code during pairing)
     */
    fun setPeerPublicKey(base64Key: String) {
        peerPublicKey = Base64.decode(base64Key, Base64.NO_WRAP)

        // Store peer key
        prefs.edit()
            .putString("peer_public_key", base64Key)
            .apply()

        // Derive session key
        deriveSessionKey()
    }

    /**
     * Derive session key using ECDH + HKDF-SHA256
     * This produces the same key as the macOS implementation
     */
    private fun deriveSessionKey() {
        val privKey = privateKey ?: throw IllegalStateException("Private key not available")
        val peerKey = peerPublicKey ?: throw IllegalStateException("Peer public key not set")

        try {
            // Perform X25519 ECDH key agreement
            val sharedSecret = X25519.computeSharedSecret(privKey, peerKey)

            // Derive session key using HKDF-SHA256 (matches Swift implementation)
            sessionKey = Hkdf.computeHkdf(
                "HMACSHA256",
                sharedSecret,
                hkdfSalt,
                hkdfInfo,
                32  // 256-bit key for ChaCha20-Poly1305
            )

        } catch (e: Exception) {
            throw RuntimeException("Failed to derive session key: ${e.message}")
        }
    }

    /**
     * Check if we have a valid session key
     */
    fun hasSessionKey(): Boolean = sessionKey != null

    /**
     * Clear peer key and session key (for unpairing)
     */
    fun clearPeerKey() {
        peerPublicKey = null
        sessionKey = null
        prefs.edit()
            .remove("peer_public_key")
            .apply()
    }

    /**
     * Encrypt a PlainItem to an Envelope JSON string
     * Uses ChaCha20-Poly1305 (compatible with macOS Swift implementation)
     */
    fun encrypt(plainItem: PlainItem): String {
        val key = sessionKey ?: throw IllegalStateException("Session key not available")

        // Serialize to JSON
        val plainJson = gson.toJson(plainItem)
        val plainBytes = plainJson.toByteArray(Charsets.UTF_8)

        // Generate random 12-byte nonce
        val nonce = ByteArray(12)
        SecureRandom().nextBytes(nonce)

        // Create ChaCha20-Poly1305 cipher with our session key
        val chacha = ChaCha20Poly1305.create(key)

        // Encrypt - ChaCha20Poly1305 expects nonce prepended to plaintext for encryption
        // But we need to handle nonce separately to match Swift format
        // The ciphertext from Tink includes the 16-byte auth tag at the end
        val ciphertextWithTag = chacha.encrypt(plainBytes, nonce)

        // Create envelope
        val deviceId = getDeviceId()
        val peerDeviceId = getPeerDeviceId()

        val envelope = Envelope(
            v = 1,
            from = deviceId,
            to = peerDeviceId,
            nonce = Base64.encodeToString(nonce, Base64.NO_WRAP),
            ciphertext = Base64.encodeToString(ciphertextWithTag, Base64.NO_WRAP),
            ad = null
        )

        return gson.toJson(envelope)
    }

    /**
     * Decrypt an Envelope JSON string to a PlainItem
     * Uses ChaCha20-Poly1305 (compatible with macOS Swift implementation)
     */
    fun decrypt(envelopeJson: String): PlainItem {
        val key = sessionKey ?: throw IllegalStateException("Session key not available")

        // Parse envelope
        val envelope = gson.fromJson(envelopeJson, Envelope::class.java)

        // Decode nonce and ciphertext
        val nonce = Base64.decode(envelope.nonce, Base64.NO_WRAP)
        val ciphertextWithTag = Base64.decode(envelope.ciphertext, Base64.NO_WRAP)

        // Create ChaCha20-Poly1305 cipher with our session key
        val chacha = ChaCha20Poly1305.create(key)

        // Decrypt - ciphertext includes the 16-byte auth tag
        val plainBytes = chacha.decrypt(ciphertextWithTag, nonce)

        // Parse plain item
        val plainJson = String(plainBytes, Charsets.UTF_8)
        return gson.fromJson(plainJson, PlainItem::class.java)
    }

    private fun getDeviceId(): String {
        return prefs.getString("device_id", "unknown") ?: "unknown"
    }

    private fun getPeerDeviceId(): String {
        return prefs.getString("peer_device_id", "unknown") ?: "unknown"
    }

    /**
     * Save device and peer IDs after pairing
     */
    fun savePairingInfo(deviceId: String, peerDeviceId: String) {
        prefs.edit()
            .putString("device_id", deviceId)
            .putString("peer_device_id", peerDeviceId)
            .apply()
    }

    data class Envelope(
        val v: Int,
        val from: String,
        val to: String,
        val nonce: String,
        val ciphertext: String,
        val ad: String?
    )
}
