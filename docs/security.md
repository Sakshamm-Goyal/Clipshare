# Security Architecture

## Overview

Universal Clipboard implements **device-level end-to-end encryption** ensuring the server never sees plaintext clipboard content. All cryptographic operations use industry-standard primitives.

## Threat Model

**What we protect against:**
- Server compromise (E2E encryption)
- Network eavesdropping (TLS + E2E)
- Unauthorized device access (pairing authentication)

**Out of scope:**
- Device compromise (physical access)
- Malicious apps on paired devices
- Side-channel attacks

## Cryptographic Primitives

### Device Identity
- **Algorithm:** Curve25519 key-agreement keypair (X25519)
- **Storage:**
  - **Android:** encrypted preferences protected by an Android Keystore master key
  - **macOS:** macOS Keychain (with access control)
- **Generation:** On first launch, persisted securely

### Key Exchange (Pairing)
- **Protocol:** X25519 ECDH with the Mac public key carried in the out-of-band QR code
- **Flow:**
  1. Mac generates ephemeral pairing token (10-minute TTL)
  2. QR contains: server URL, token, Mac's device ID & public key
  3. Android scans QR, connects to `/pair` WebSocket
  4. Android verifies that the server response still contains the key it scanned
  5. Both devices derive the same session key through HKDF-SHA256
  6. Server issues JWT device tokens (signed, 1-year expiry)

### Session Keys
- **Derivation:** X25519 ECDH output through HKDF-SHA256
- **HKDF salt:** `ClipShare-Salt-2024`
- **HKDF info:** `ClipShare-E2E-v1`
- **Rotation:** not implemented in v1; re-pair to replace a session key

**Session Key Derivation:**
```
session_key = HKDF-SHA256(
  ikm=ECDH(mac_privkey, android_pubkey),
  salt="ClipShare-Salt-2024",
  info="ClipShare-E2E-v1",
  length=32
)
```

### Message Encryption
- **AEAD Cipher:** IETF ChaCha20-Poly1305
- **Nonce:** 96-bit random (generated per message)
- **Associated Data:** empty in v1; routing metadata is server-authenticated separately

**Envelope Structure:**
```json
{
  "v": 1,
  "from": "android-abc...",
  "to": "mac-0c1c...",
  "nonce": "12B-base64...",
  "ciphertext": "base64...",
  "ad": "optional-metadata"
}
```

**Encryption Flow:**
```
plaintext_json = JSON(clipboard_item)
nonce = random(12)
ciphertext = ChaCha20-Poly1305.encrypt(
  key=session_key,
  nonce=nonce,
  plaintext=plaintext_json,
  ad=""
)
```

## Server Design (Zero-Knowledge)

### What the Server Sees
- Device IDs (routing metadata)
- Message timestamps (for queue management)
- Encrypted envelopes (opaque base64 blobs)
- Connection patterns (online/offline status)

### What the Server NEVER Sees
- Clipboard content
- Encryption keys (URK, session keys)
- Plaintext message types
- User identities beyond device IDs

### Server Responsibilities
1. **Routing:** Forward encrypted envelopes between paired devices
2. **Queueing:** Store messages for offline devices (24h max, encrypted)
3. **Authentication:** Validate JWT device tokens
4. **Pairing:** Facilitate key exchange (but never see keys)

## Attack Scenarios

### 1. Server Compromise
**Impact:** None
**Reason:** Server only has encrypted envelopes, cannot decrypt

### 2. Man-in-the-Middle (Pairing)
**Impact:** The Android app rejects a pairing response that differs from the Mac key scanned in the QR code. A malicious relay can still deny service; signed mutual key confirmation is a future hardening item.
**Mitigation:**
- QR code display is out-of-band (physical proximity required)
- Android pins the Mac public key obtained from the QR code
- Short-lived pairing tokens (10 minutes)

### 3. Replay Attacks
**Impact:** Delivery is at-least-once, so clients must tolerate duplicate routes.
**Mitigation:**
- Redis de-duplicates a queued route ID until that route is ACKed
- Clients verify the outer route ID matches encrypted `PlainItem.id`

### 4. Device Revocation
**Flow:**
1. User un-pairs device via UI
2. App deletes local peer credentials and keys
3. Re-pairing establishes a new session; server-side revocation is not yet exposed as an API

## Key Storage Security

### Android
- **KeyStore:** an Android Keystore AES master key protects encrypted preferences
- **Stored secrets:** device keypair, peer key, and device JWT
- **Backup:** backup rules exclude the encrypted secret store and legacy key store

### macOS
- **Keychain:** Encrypted with user's login password
- **Access Control:** App-specific, requires keychain unlock
- **Stored secrets:** device keypair, peer key, and device JWT

## Compliance Notes

- **GDPR:** No PII stored on server, E2E encrypted
- **HIPAA:** Encryption at rest + in transit (if deployed securely)
- **SOC 2:** Logging events without plaintext, secure key management

## Future Enhancements

### v2 Security Features
1. **Perfect Forward Secrecy:** Double-ratchet algorithm (Signal Protocol)
2. **Post-Quantum:** Hybrid X25519 + Kyber KEM
3. **Multi-Device:** Group key agreement (TreeKEM)
4. **Audit Log:** Signed append-only log for pairing events

---

**Last Updated:** 2025-01-02
**Version:** 0.1.0
