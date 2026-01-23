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
- **Algorithm:** Ed25519 (signing keypair)
- **Storage:**
  - **Android:** Android Keystore (StrongBox if available)
  - **macOS:** macOS Keychain (with access control)
- **Generation:** On first launch, persisted securely

### Key Exchange (Pairing)
- **Protocol:** Authenticated ECDH (Curve25519)
- **Flow:**
  1. Mac generates ephemeral pairing token (10-minute TTL)
  2. QR contains: server URL, token, Mac's device ID & public key
  3. Android scans QR, connects to `/pair` WebSocket
  4. Both devices perform authenticated key exchange
  5. Derive **User Root Key (URK)** via HKDF-SHA256
  6. Server issues JWT device tokens (signed, 1-year expiry)

**URK Derivation:**
```
shared_secret = ECDH(mac_privkey, android_pubkey)
urk = HKDF-SHA256(
  ikm=shared_secret,
  salt="clipshare-urk-v1",
  info=concat(mac_device_id, android_device_id),
  length=32
)
```

### Session Keys
- **Derivation:** From URK using HKDF with context
- **Rotation:** Every 256 messages (or 24 hours, whichever comes first)
- **Algorithm:** HKDF-SHA256

**Session Key Derivation:**
```
session_key_N = HKDF-SHA256(
  ikm=urk,
  salt="clipshare-session-v1",
  info=concat(purpose="clipboard", epoch=N),
  length=32
)
```

### Message Encryption
- **AEAD Cipher:** XChaCha20-Poly1305
- **Nonce:** 192-bit random (generated per message)
- **Associated Data:** Optional (device IDs, message type)

**Envelope Structure:**
```json
{
  "v": 1,
  "from": "android-abc...",
  "to": "mac-0c1c...",
  "nonce": "24B-base64...",
  "ciphertext": "base64...",
  "ad": "optional-metadata"
}
```

**Encryption Flow:**
```
plaintext_json = JSON(clipboard_item)
nonce = random(24)
ciphertext = XChaCha20-Poly1305.encrypt(
  key=session_key,
  nonce=nonce,
  plaintext=plaintext_json,
  ad=concat(from_id, to_id)
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
**Impact:** Prevented
**Mitigation:**
- QR code display is out-of-band (physical proximity required)
- Authenticated key exchange (both devices verify signatures)
- Short-lived pairing tokens (10 minutes)

### 3. Replay Attacks
**Impact:** Prevented
**Mitigation:**
- Monotonic sequence numbers (`seq` field)
- Unique message IDs (`id` field as UUID v7)
- Clients reject old sequences

### 4. Device Revocation
**Flow:**
1. User un-pairs device via UI
2. App deletes local keys & JWT
3. Server invalidates JWT (optional)
4. Peer device stops routing to revoked device

## Key Storage Security

### Android
- **KeyStore:** Hardware-backed (StrongBox on Pixel 3+, TEE on others)
- **Access Control:** User authentication required (fingerprint/PIN)
- **Backup:** Keys NOT backed up to cloud

### macOS
- **Keychain:** Encrypted with user's login password
- **Access Control:** App-specific, requires keychain unlock
- **Sandboxing:** App is sandboxed, limited keychain access

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
