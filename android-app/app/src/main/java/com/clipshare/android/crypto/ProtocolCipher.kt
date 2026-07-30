package com.clipshare.android.crypto

import com.google.crypto.tink.subtle.ChaCha20Poly1305

/**
 * Wire-format adapter for the IETF ChaCha20-Poly1305 implementation used by
 * Tink and Swift Crypto. Tink returns nonce || ciphertext || tag, whereas the
 * shared envelope sends the nonce as its own field and ciphertext || tag in a
 * second field.
 */
object ProtocolCipher {
    const val NONCE_BYTES = 12
    private val EMPTY_AAD = ByteArray(0)

    data class EncryptedPayload(
        val nonce: ByteArray,
        val ciphertextAndTag: ByteArray
    )

    fun encrypt(key: ByteArray, plaintext: ByteArray): EncryptedPayload {
        require(key.size == 32) { "ChaCha20-Poly1305 requires a 32-byte key" }
        val combined = ChaCha20Poly1305(key).encrypt(plaintext, EMPTY_AAD)
        check(combined.size >= NONCE_BYTES + 16) { "Invalid ChaCha20-Poly1305 output" }

        return EncryptedPayload(
            nonce = combined.copyOfRange(0, NONCE_BYTES),
            ciphertextAndTag = combined.copyOfRange(NONCE_BYTES, combined.size)
        )
    }

    fun decrypt(key: ByteArray, nonce: ByteArray, ciphertextAndTag: ByteArray): ByteArray {
        require(key.size == 32) { "ChaCha20-Poly1305 requires a 32-byte key" }
        require(nonce.size == NONCE_BYTES) { "Envelope nonce must be 12 bytes" }
        require(ciphertextAndTag.size >= 16) { "Ciphertext is missing its authentication tag" }

        val combined = ByteArray(NONCE_BYTES + ciphertextAndTag.size)
        nonce.copyInto(combined, destinationOffset = 0)
        ciphertextAndTag.copyInto(combined, destinationOffset = NONCE_BYTES)
        return ChaCha20Poly1305(key).decrypt(combined, EMPTY_AAD)
    }
}
