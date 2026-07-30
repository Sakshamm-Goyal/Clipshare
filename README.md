# Universal Clipboard - Cross-Device Sync

End-to-end encrypted clipboard synchronization between Android and macOS devices.

## Features

- **Bi-directional Sync**: macOS → Android syncs automatically; Android → macOS uses the in-app **Send Current Clipboard** action after copying outside ClipShare
- **E2E Encrypted**: Curve25519 ECDH + HKDF + IETF ChaCha20-Poly1305; the relay never sees clipboard plaintext
- **Sub-400ms Latency**: Fast WebSocket relay for real-time experience
- **QR Code Pairing**: One-time secure device pairing
- **Offline Queue**: Items sync automatically when devices reconnect
- **Image Clipboard**: PNG and JPEG clipboard images sync in both directions (up to 5 MiB)
- **Durable Delivery**: Encrypted routes remain queued until the receiving device ACKs them
- **Battery Optimized**: Efficient Android foreground service
- **Privacy First**: No tracking, no analytics, open source

## Architecture

```
┌─────────────┐                    ┌─────────────┐
│   Android   │◄──────────────────►│    macOS    │
│   (Kotlin)  │   E2E Encrypted    │   (Swift)   │
└──────┬──────┘                    └──────┬──────┘
       │                                  │
       │         WebSocket Relay          │
       └────────►┌──────────┐◄────────────┘
                 │  Go API  │
                 │ (Server) │
                 └──────────┘
```

## Project Structure

```
universal-clipboard/
├─ backend/              # Go WebSocket relay + pairing API
├─ android-app/          # Kotlin Android app
├─ mac-app/              # Swift macOS menubar app
├─ proto/                # Shared message schemas
├─ docs/                 # Documentation
└─ tools/                # Build & deployment scripts
```

## Quick Start

### Backend (Go)
```bash
cd backend
JWT_SECRET='replace-with-a-unique-secret-of-at-least-32-characters' go run cmd/server/main.go
```

### macOS App (Swift)
```bash
cd mac-app
open Package.swift
```

### Android App (Kotlin)
```bash
cd android-app
./gradlew assembleDebug
```

## Android Clipboard Behavior

Android 10 and later prevents ordinary background apps from reading another
app's clipboard. This is an operating-system privacy rule, not a relay
limitation. Incoming Mac → Android updates remain automatic through the
foreground sync service. For Android → Mac, ClipShare provides policy-safe
one-tap entry points that preserve the user's existing keyboard:

- select text and choose **Send to Mac**;
- use **Share → ClipShare** for text, PNGs, and JPEGs;
- tap **Send clipboard** in the persistent notification, launcher shortcut,
  or optional Quick Settings tile.

Those one-tap actions briefly bring ClipShare to the foreground, read the
clipboard, encrypt it, and send it. The full app remains a fallback. A device
can stay paired while sync is paused.

For true automatic background Android → macOS capture, the user would need to
make ClipShare their default keyboard (IME), which is intentionally not enabled
by this app without an explicit product decision and onboarding flow.

## Security

- Device-level E2E encryption with Curve25519 key-agreement keypairs
- Android Keystore-backed encrypted storage / macOS Keychain integration
- Authenticated out-of-band QR pairing and per-route delivery ACKs
- Zero-knowledge server design

See [docs/security.md](docs/security.md) for details.

## License

MIT License - See LICENSE file
