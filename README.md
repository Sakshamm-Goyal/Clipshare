# Universal Clipboard - Cross-Device Sync

End-to-end encrypted clipboard synchronization between Android and macOS devices.

## Features

- **Bi-directional Sync**: Copy on any device, paste on any other
- **E2E Encrypted**: XChaCha20-Poly1305 encryption, server never sees plaintext
- **Sub-400ms Latency**: Fast WebSocket relay for real-time experience
- **QR Code Pairing**: One-time secure device pairing
- **Offline Queue**: Items sync automatically when devices reconnect
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
go run cmd/server/main.go
```

### macOS App (Swift)
```bash
cd mac-app
open ClipboardMac.xcodeproj
```

### Android App (Kotlin)
```bash
cd android-app
./gradlew assembleDebug
```

## Security

- Device-level E2E encryption with ed25519 keypairs
- Android Keystore (StrongBox) / macOS Keychain integration
- Authenticated key exchange during pairing
- Session key rotation every 256 messages
- Zero-knowledge server design

See [docs/security.md](docs/security.md) for details.

## License

MIT License - See LICENSE file
