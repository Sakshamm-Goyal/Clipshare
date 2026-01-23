# Message Protocol Specification

## Overview

All messages between devices use JSON over WebSocket, with an encrypted payload envelope for clipboard data.

## Version

Current protocol version: **v1**

---

## 1. WebSocket Connection

### Endpoint
```
wss://<server>/ws
```

### Authentication

**Method 1: Authorization Header**
```
Authorization: Bearer <jwt_device_token>
```

**Method 2: Sec-WebSocket-Protocol**
```
Sec-WebSocket-Protocol: Bearer.<jwt_device_token>
```

### Connection Lifecycle

```
Client → Server: Upgrade HTTP to WebSocket
Server → Client: 101 Switching Protocols
───────────────────────────────────────────
Client ↔ Server: WebSocket frames (JSON)
───────────────────────────────────────────
Client/Server: Close (1000 Normal)
```

**Ping/Pong:**
- Server sends WebSocket PING every 30s
- Client must respond with PONG within 60s
- Failure → connection closed

---

## 2. Message Types

### 2.1 Route Message (Device → Server → Device)

**Purpose:** Send encrypted clipboard item to peer device

**Structure:**
```json
{
  "type": "route",
  "from": "android-abc123",
  "to": "mac-0c1c45f2",
  "data": "eyJ2IjoxLCJmcm9tIjoiYW5kcm9pZC...",
  "qos": "at-least-once"
}
```

**Fields:**
- `type` (string): Always `"route"`
- `from` (string): Sender device ID (verified by server)
- `to` (string): Recipient device ID
- `data` (string): Base64-encoded encrypted envelope (JSON)
- `qos` (string, optional): QoS hint (`"at-least-once"`)

**Server Behavior:**
- If `to` device is online: forward immediately
- If `to` device is offline: queue in Redis (24h TTL)
- If sender not authorized for `to`: drop + log error

---

### 2.2 ACK Message (Device → Device)

**Purpose:** Acknowledge successful receipt of clipboard item

**Structure:**
```json
{
  "type": "ack",
  "id": "550e8400-e29b-41d4-a716-446655440000",
  "from": "mac-0c1c45f2",
  "seq_ack": 123,
  "status": "ok"
}
```

**Fields:**
- `type` (string): Always `"ack"`
- `id` (string): UUID of the clipboard item being acknowledged
- `from` (string): Sender device ID (the one acknowledging)
- `seq_ack` (int): Sequence number being acknowledged
- `status` (string): `"ok"` or `"error"`

**Sender Behavior:**
- On receiving ACK: mark item delivered in outbox, prune old items

---

### 2.3 NACK Message (Server → Device)

**Purpose:** Negative acknowledgment (error)

**Structure:**
```json
{
  "type": "nack",
  "id": "550e8400-e29b-41d4-a716-446655440000",
  "code": "TOO_LARGE",
  "msg": "Payload exceeds 64KB limit"
}
```

**Error Codes:**
- `TOO_LARGE`: Payload > 64KB
- `UNSUPPORTED_TYPE`: Non-text clipboard item
- `UNAUTHORIZED`: Sender not allowed to message recipient
- `RATE_LIMITED`: Too many messages in short time
- `DEVICE_OFFLINE`: Recipient offline, message queued

---

## 3. Encrypted Envelope

### Structure
```json
{
  "v": 1,
  "from": "android-abc123",
  "to": "mac-0c1c45f2",
  "nonce": "GBzKFP9X3rQ8w5vN2Jc7Zg==",
  "ciphertext": "k3jf02nf9j23f0j2f0j2f0...",
  "ad": null
}
```

**Fields:**
- `v` (int): Envelope version (currently 1)
- `from` (string): Sender device ID
- `to` (string): Recipient device ID
- `nonce` (string): Base64-encoded 24-byte XChaCha20 nonce
- `ciphertext` (string): Base64-encoded encrypted payload (includes Poly1305 tag)
- `ad` (string, optional): Associated data (not encrypted, authenticated)

**Encryption Algorithm:**
```
XChaCha20-Poly1305 AEAD

Key: 32-byte session key (derived from URK)
Nonce: 24-byte random (unique per message)
Plaintext: JSON-serialized PlainItem
Ciphertext: Encrypted plaintext + 16-byte auth tag
```

---

## 4. PlainItem (Decrypted Payload)

### Structure
```json
{
  "id": "550e8400-e29b-41d4-a716-446655440000",
  "seq": 123,
  "tsMs": 1704211200000,
  "kind": "clipboard_item",
  "payload": {
    "type": "text/plain",
    "size": 11,
    "text": "Hello World"
  },
  "meta": {
    "app": "android-app@0.1.0",
    "network": "wifi",
    "lang": "en"
  }
}
```

**Fields:**
- `id` (string): UUID v4/v7 (unique per item)
- `seq` (int): Monotonic sequence number (per sender)
- `tsMs` (int64): Unix timestamp in milliseconds
- `kind` (string): Message type (`"clipboard_item"`)
- `payload` (object): Content object
  - `type` (string): MIME type (`"text/plain"`, `"text/uri-list"`)
  - `size` (int): Byte size of text
  - `text` (string): Clipboard content
- `meta` (object, optional): Metadata
  - `app` (string): Sender app version
  - `network` (string): Network type (`"wifi"`, `"cellular"`)
  - `lang` (string): Language code (ISO 639-1)

**Constraints:**
- `payload.size` ≤ 65536 bytes (64 KB)
- `seq` must be monotonically increasing per sender
- `id` must be globally unique

---

## 5. Pairing Protocol

### Step 1: Start Pairing (Mac)

**Request:**
```http
POST /v1/pair/start
Content-Type: application/json

{
  "device_id": "mac-0c1c45f2",
  "device_name": "MacBook Pro",
  "public_key": "cHVibGljX2tleV9iYXNlNjQ=",
  "platform": "macos"
}
```

**Response:**
```json
{
  "token": "dGVzdC10b2tlbg==",
  "server_url": "wss://example.com/pair",
  "expires_at": "2025-01-02T12:10:00Z",
  "device_id": "mac-0c1c45f2",
  "device_pub": "cHVibGljX2tleV9iYXNlNjQ="
}
```

**Mac then:**
1. Generates QR code with this data
2. Displays QR on screen
3. Connects to `wss://example.com/pair?token=<token>`

---

### Step 2: Scan QR (Android)

**Android:**
1. Scans QR code
2. Decodes base64 JSON
3. Extracts: `server_url`, `token`, `device_id`, `device_pub`
4. Connects to `/pair` WebSocket

---

### Step 3: Key Exchange (over WebSocket)

**Android → Server → Mac:**
```json
{
  "device_id": "android-abc123",
  "device_name": "Pixel 8",
  "public_key": "YW5kcm9pZF9wdWJrZXk=",
  "platform": "android"
}
```

**Server:**
1. Validates token (not expired)
2. Performs ECDH shared secret derivation (or proxies)
3. Creates user + both devices in database
4. Issues JWT tokens for both devices

**Server → Both Devices:**
```json
{
  "status": "success",
  "original_token": "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9...",
  "peer_token": "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9...",
  "original_device": "mac-0c1c45f2",
  "peer_device": "android-abc123",
  "device_pub": "cHVibGljX2tleV9iYXNlNjQ="
}
```

**Both Devices:**
1. Save JWT token to secure storage
2. Save peer device ID
3. Derive URK from ECDH shared secret
4. Close pairing WebSocket
5. Connect to `/ws` with JWT

---

## 6. Sequence Diagrams

### Normal Clipboard Sync
```
Android                     Server                     Mac
  │                            │                        │
  │ Clipboard Change           │                        │
  │ ─┐                         │                        │
  │  │ Encrypt                 │                        │
  │ ◄┘                         │                        │
  │                            │                        │
  │ {type: "route", data: ...} │                        │
  ├───────────────────────────►│                        │
  │                            │                        │
  │                            │ {type: "route", ...}   │
  │                            ├───────────────────────►│
  │                            │                        │
  │                            │                        │◄┐
  │                            │                        │ │ Decrypt
  │                            │                        │─┘
  │                            │                        │
  │                            │                        │─┐
  │                            │                        │ │ Show Toast
  │                            │                        │◄┘
  │                            │                        │
  │                            │ {type: "ack", ...}     │
  │                            │◄───────────────────────┤
  │                            │                        │
  │ {type: "ack", ...}         │                        │
  │◄───────────────────────────┤                        │
  │                            │                        │
  │─┐                          │                        │
  │ │ Mark Delivered           │                        │
  │◄┘                          │                        │
```

### Offline Queue + Reconnect
```
Android                     Server                     Mac (offline)
  │                            │
  │ {type: "route", data: ...} │
  ├───────────────────────────►│
  │                            │
  │                            │ Device offline
  │                            │─┐
  │                            │ │ Queue in Redis
  │                            │◄┘
  │                            │
  │                            │
  │                            │    Mac reconnects
  │                            │◄───────────────────────
  │                            │
  │                            │ Deliver queued msgs
  │                            ├───────────────────────►
  │                            │
  │                            │ {type: "ack", ...}
  │                            │◄───────────────────────
  │                            │
  │ {type: "ack", ...}         │
  │◄───────────────────────────┤
```

---

## 7. Error Handling

### Client Disconnection
- **Reason:** Network loss, app killed, battery saver
- **Behavior:** Server removes from hub, marks offline
- **Reconnect:** Exponential backoff (0.5s, 1s, 2s, 4s, 8s, ..., max 30s)

### Invalid Token
- **Response:** HTTP 401 Unauthorized
- **Client Action:** Re-pair required

### Message Too Large
- **Response:** `{type: "nack", code: "TOO_LARGE", ...}`
- **Client Action:** Show error, do not retry

### Duplicate Message ID
- **Server:** Ignore (idempotent)
- **Client:** Not an error

### Out-of-Order Sequence
- **Client:** Accept (sequence used for UI sorting only)
- **No strict ordering enforcement** (eventual consistency)

---

## 8. Rate Limiting

### Server Limits
- **Messages per device:** 100/minute
- **Pairing attempts:** 5/hour per IP
- **WebSocket connections:** 5 concurrent per device ID

### Client Backoff
- On NACK with `RATE_LIMITED`: wait 60s before retry

---

## 9. Future Extensions (v2)

### Rich Media Support
```json
{
  "payload": {
    "type": "image/png",
    "size": 102400,
    "url": "https://cdn.example.com/clip/abc123.png",
    "thumb_data": "base64_thumbnail"
  }
}
```

### Multi-Device Sync
```json
{
  "from": "android-abc123",
  "to": ["mac-0c1c45f2", "mac-0a1b23c4"],  // Array of recipients
  ...
}
```

### Read Receipts
```json
{
  "type": "read_receipt",
  "id": "550e8400-e29b-41d4-a716-446655440000",
  "from": "mac-0c1c45f2",
  "read_at": 1704211205000
}
```

---

**Last Updated:** 2025-01-02
**Version:** v1
