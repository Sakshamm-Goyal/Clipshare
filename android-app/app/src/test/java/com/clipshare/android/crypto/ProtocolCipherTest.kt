package com.clipshare.android.crypto

import com.google.crypto.tink.subtle.ChaCha20Poly1305
import com.clipshare.android.service.PlainItem
import com.google.gson.Gson
import org.junit.Assert.assertArrayEquals
import org.junit.Test

class ProtocolCipherTest {
    @Test
    fun preservesImagePayloadWithoutTreatingBinaryDataAsText() {
        val original = PlainItem(
            id = "image-id",
            seq = 1,
            tsMs = 1L,
            kind = "clipboard_item",
            payload = PlainItem.Payload(
                type = "image/png",
                size = 3,
                text = null,
                data = "AQID"
            ),
            meta = null
        )

        val roundTripped = Gson().fromJson(Gson().toJson(original), PlainItem::class.java)

        org.junit.Assert.assertEquals("image/png", roundTripped.payload.type)
        org.junit.Assert.assertEquals("AQID", roundTripped.payload.data)
        org.junit.Assert.assertEquals(null, roundTripped.payload.text)
    }

    @Test
    fun decryptsTheExternalNonceEnvelopeUsedByMacOS() {
        val key = ByteArray(32) { it.toByte() }
        val plaintext = "ClipShare cross-platform fixture".toByteArray()

        // Tink emits IETF ChaCha20-Poly1305 as nonce || ciphertext || tag.
        // macOS transports the nonce separately and only sends ciphertext || tag.
        val tinkOutput = ChaCha20Poly1305(key).encrypt(plaintext, ByteArray(0))
        val nonce = tinkOutput.copyOfRange(0, ProtocolCipher.NONCE_BYTES)
        val ciphertextAndTag = tinkOutput.copyOfRange(ProtocolCipher.NONCE_BYTES, tinkOutput.size)

        assertArrayEquals(plaintext, ProtocolCipher.decrypt(key, nonce, ciphertextAndTag))
    }

    @Test
    fun preservesTheCipherGeneratedNonceAsTheEnvelopeNonce() {
        val key = ByteArray(32) { (it + 32).toByte() }
        val plaintext = "A clipboard item must decrypt on the other platform".toByteArray()

        val encrypted = ProtocolCipher.encrypt(key, plaintext)

        org.junit.Assert.assertEquals(ProtocolCipher.NONCE_BYTES, encrypted.nonce.size)
        assertArrayEquals(plaintext, ProtocolCipher.decrypt(key, encrypted.nonce, encrypted.ciphertextAndTag))
    }
}
