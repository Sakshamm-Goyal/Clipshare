# Architecture Overview

## System Design

Universal Clipboard uses a **hybrid architecture** combining WebSocket relay (MVP) with future peer-to-peer (P2P) capability.

```
┌─────────────────┐                  ┌─────────────────┐
│     Android     │                  │      macOS      │
│  (Kotlin App)   │                  │  (Swift App)    │
└────────┬────────┘                  └────────┬────────┘
         │                                    │
         │    E2E Encrypted WebSocket         │
         │                                    │
         └──────────►┌──────────┐◄───────────┘
                     │   Go     │
                     │  Server  │
                     │ (Relay)  │
                     └────┬─────┘
                          │
         ┌────────────────┴────────────────┐
         │                                 │
    ┌────▼────┐                      ┌────▼────┐
    │ Postgres│                      │  Redis  │
    │ (State) │                      │ (Queue) │
    └─────────┘                      └─────────┘
```

## Component Breakdown

### 1. Android App (Kotlin)

**Responsibilities:**
- Monitor clipboard changes via `ClipboardManager`
- Encrypt clipboard items using Tink's IETF ChaCha20-Poly1305 implementation
- Send encrypted envelopes to server via WebSocket
- Queue failed sends in Room database (WAL mode)
- Run as foreground service for reliability

**Key Components:**
- `ClipboardSyncService`: Foreground service managing lifecycle
- `ClipboardObserver`: Debounced clipboard change detection
- `WebSocketClient`: OkHttp WebSocket with reconnection logic
- `CryptoBox`: Tink-based encryption wrapper
- `AppDatabase`: Room database for outbox queue
- `PairingActivity`: ML Kit QR scanner for device pairing

**Data Flow:**
```
Clipboard Change → Debounce (250ms) → Encrypt → Outbox (Room) → WebSocket → Server
                                                  ↓
                                            ACK received → Mark delivered
```

### 2. macOS App (Swift)

**Responsibilities:**
- Monitor `NSPasteboard` for outgoing clipboard items
- Decrypt incoming messages and stage them
- Display menubar status (connected/disconnected)
- Handle hotkey (⌥⌘V) for pasting staged items
- Generate QR code for pairing

**Key Components:**
- `AppDelegate`: Main coordinator, manages lifecycle
- `StatusBarController`: NSStatusItem + menu
- `WebSocketClient`: URLSessionWebSocketTask with reconnection
- `CryptoBox`: Swift Crypto (ChaChaPoly) for E2E encryption
- `ClipboardManager`: Staged clipboard + NSPasteboard bridge
- `HotkeyManager`: Carbon hotkey registration (⌥⌘V)
- `KeychainHelper`: Secure storage for keys + tokens

**Data Flow:**
```
NSPasteboard Change → Encrypt → WebSocket → Server
                                                ↓
Incoming Message → Decrypt → Stage → Notify User → ⌥⌘V → Paste
```

### 3. Go Backend (Server)

**Responsibilities:**
- Route encrypted envelopes between paired devices
- Queue messages for offline devices (24h TTL)
- Facilitate device pairing (key exchange coordination)
- Issue JWT device tokens after successful pairing
- Maintain online/offline device status

**Key Components:**
- `ws.Hub`: Central WebSocket connection manager
- `ws.Client`: Per-device WebSocket handler
- `auth.Service`: JWT generation + validation
- `pairing.Service`: Pairing token management
- `store.Postgres`: Device registry, users, pairing tokens
- `store.Redis`: Online presence, message queue

**Message Flow:**
```
Device A → /ws → Hub → Route → Device B (if online)
                   │
                   └─► Redis Queue (if B offline) → Delivered on reconnect
```

**Endpoints:**
- `POST /v1/pair/start`: Mac starts pairing, gets token
- `GET /pair?token=<token>`: WebSocket for key exchange
- `GET /ws`: Authenticated device WebSocket (JWT in header)
- `GET /healthz`: Health check
- `GET /metrics`: Prometheus metrics (optional)

### 4. Encryption Layer

**Pairing Flow:**
```
Mac                          Android                    Server
 │                              │                          │
 │ POST /v1/pair/start          │                          │
 ├─────────────────────────────────────────────────────────►
 │◄─────────────────────────────────────────────────────────
 │ {token, QR data}             │                          │
 │                              │                          │
 │ Display QR                   │                          │
 │                              │ Scan QR                  │
 │                              │                          │
 │                              │ GET /pair?token=...      │
 │                              ├─────────────────────────►│
 │                              │◄─────────────────────────┤
 │                              │ WebSocket Connected      │
 │                              │                          │
 │ GET /pair (via token)        │                          │
 ├─────────────────────────────────────────────────────────►
 │◄─────────────────────────────────────────────────────────
 │ WebSocket Connected          │                          │
 │                              │                          │
 │◄────────────────────────────►│                          │
 │    Authenticated ECDH        │                          │
 │    (over WebSocket)          │                          │
 │                              │                          │
 │ Derive URK                   │ Derive URK               │
 │                              │                          │
 │                              │ POST peer info           │
 │                              ├─────────────────────────►│
 │                              │◄─────────────────────────┤
 │◄─────────────────────────────────────────────────────────
 │ {jwt_mac, jwt_android}       │ {jwt_mac, jwt_android}   │
 │                              │                          │
 │ Save JWT + URK               │ Save JWT + URK           │
 │                              │                          │
 │ Disconnect pairing WS        │ Disconnect pairing WS    │
 │                              │                          │
 │ Connect to /ws with JWT      │ Connect to /ws with JWT  │
 └──────────────────────────────┴──────────────────────────┘
```

**Message Encryption:**
```
Plaintext:
{
  "id": "uuid",
  "seq": 123,
  "tsMs": 1704211200000,
  "kind": "clipboard_item",
  "payload": {"type": "text/plain", "size": 11, "text": "Hello World"},
  "meta": {"app": "android-app@0.1.0", "network": "wifi", "lang": "en"}
}

↓ Encrypt with IETF ChaCha20-Poly1305

Envelope:
{
  "v": 1,
  "from": "android-abc123",
  "to": "mac-0c1c45f2",
  "nonce": "GBzKFP9X3rQ8w...",
  "ciphertext": "k3jf02nf...",
  "ad": null
}

↓ WebSocket Frame

{
  "type": "route",
  "from": "android-abc123",
  "to": "mac-0c1c45f2",
  "data": "base64(envelope_json)",
  "qos": "at-least-once"
}
```

## Scalability Considerations

### Current (MVP)
- Single Go server instance
- PostgreSQL (vertical scaling)
- Redis (single instance, cache only)
- **Capacity:** ~10,000 concurrent devices

### Future (v1)
- Horizontal scaling via sticky sessions (device_id → server mapping)
- PostgreSQL read replicas
- Redis Cluster for distributed queue
- **Capacity:** ~100,000+ concurrent devices

### Future (v2)
- WebRTC P2P for local network (LAN)
- TURN fallback for NAT traversal
- Server becomes signaling + STUN only
- **Capacity:** Unlimited (P2P)

## Latency Optimization

**Current Performance (Relay):**
- LAN: ~50-150ms
- Same City: ~100-250ms
- Cross-Country: ~200-400ms

**Breakdown:**
```
Clipboard Change → 250ms (debounce)
Encryption       → 1-2ms
WebSocket Send   → 10-30ms (network)
Server Route     → 5-10ms (processing)
WebSocket Recv   → 10-30ms (network)
Decryption       → 1-2ms
Display Toast    → 5-10ms
──────────────────────────────────
Total: ~280-340ms (typical)
```

**Future (P2P):**
- LAN: ~10-50ms (direct connection)
- WAN: ~100-200ms (TURN relay)

## Failure Modes

### 1. Server Down
- **Impact:** No real-time sync
- **Mitigation:** Clients queue locally, sync on reconnect
- **UX:** Yellow status indicator

### 2. Device Offline
- **Impact:** Delayed delivery
- **Mitigation:** Server queues messages (24h), delivers on reconnect
- **UX:** "Delivered when online" indicator

### 3. Network Partition
- **Impact:** Both devices think peer is offline
- **Mitigation:** Exponential backoff reconnect, eventual consistency
- **UX:** Auto-reconnect when network returns

### 4. Key Loss
- **Impact:** Cannot decrypt new messages
- **Mitigation:** Must re-pair devices
- **UX:** "Re-pair required" error + re-pairing flow

### 5. Concurrent Clipboard Changes
- **Impact:** Last-write-wins (no conflict resolution)
- **Mitigation:** Sequence numbers for ordering, source labels in UI
- **UX:** Show "From Android · 2s ago" in notifications

## Security Layers

**Layer 1: Transport (TLS)**
- WebSocket over TLS 1.3
- Certificate pinning (optional, future)

**Layer 2: Authentication (JWT)**
- Device tokens signed by server
- 1-year expiry, renewable

**Layer 3: Encryption (E2E)**
- IETF ChaCha20-Poly1305 AEAD (12-byte nonce)
- Unique nonce per message
- Keys derived from ECDH shared secret

**Layer 4: Access Control**
- Server validates sender/receiver in same user group
- Cannot send to arbitrary device IDs

## Trade-offs

### Relay vs P2P

| Aspect          | Relay (Current)      | P2P (Future)         |
|-----------------|----------------------|----------------------|
| Latency         | 200-400ms            | 10-200ms             |
| Reliability     | High (server always) | Medium (NAT issues)  |
| Privacy         | Good (E2E encrypted) | Excellent (no relay) |
| Deployment      | Simple (1 server)    | Complex (STUN/TURN)  |
| Cross-Network   | Always works         | Needs TURN fallback  |

### Staged vs Auto-Overwrite

| Approach        | Pros                          | Cons                            |
|-----------------|-------------------------------|---------------------------------|
| Staged (Default)| Non-invasive, user control    | Extra step (hotkey)             |
| Auto-Overwrite  | Seamless, no user action      | Can clobber current clipboard   |

**Decision:** Default to staged, allow opt-in auto-overwrite

---

**Last Updated:** 2025-01-02
**Version:** 0.1.0
