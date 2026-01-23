# Deployment Guide

## Prerequisites

- **Backend:** Go 1.22+, PostgreSQL 15+, Redis 7+
- **macOS App:** macOS 13+ (Ventura), Xcode 15+
- **Android App:** Android 8+ (API 26), Android Studio Hedgehog+

## Backend Deployment

### 1. Database Setup

**PostgreSQL:**
```bash
# Create database
createdb clipshare

# Migrations run automatically on startup
# See: backend/internal/store/postgres.go
```

**Redis:**
```bash
# Install Redis
brew install redis  # macOS
apt-get install redis  # Ubuntu

# Start Redis
redis-server
```

### 2. Environment Configuration

Create `.env` file:
```bash
# Database
DATABASE_URL=postgres://user:pass@localhost:5432/clipshare?sslmode=disable

# Redis
REDIS_URL=localhost:6379

# JWT Secret (CHANGE IN PRODUCTION!)
JWT_SECRET=your-secure-random-256-bit-secret

# Server
PORT=8080
```

### 3. Build & Run

```bash
cd backend

# Install dependencies
go mod download

# Run migrations (automatic on startup)
# Build
go build -o clipshare-server cmd/server/main.go

# Run
./clipshare-server -addr :8080
```

### 4. Production Deployment

**Using systemd:**
```ini
# /etc/systemd/system/clipshare.service
[Unit]
Description=Clipboard Sync Server
After=network.target postgresql.service redis.service

[Service]
Type=simple
User=clipshare
WorkingDirectory=/opt/clipshare
Environment="DATABASE_URL=postgres://..."
Environment="REDIS_URL=localhost:6379"
Environment="JWT_SECRET=..."
ExecStart=/opt/clipshare/clipshare-server -addr :8080
Restart=always

[Install]
WantedBy=multi-user.target
```

**Using Docker:**
```dockerfile
FROM golang:1.22-alpine AS builder
WORKDIR /app
COPY go.* ./
RUN go mod download
COPY . .
RUN go build -o server cmd/server/main.go

FROM alpine:latest
RUN apk --no-cache add ca-certificates
COPY --from=builder /app/server /server
EXPOSE 8080
CMD ["/server", "-addr", ":8080"]
```

**Reverse Proxy (Caddy):**
```caddyfile
wss.example.com {
    reverse_proxy localhost:8080
    tls you@example.com
}
```

### 5. Security Hardening

- [ ] Use strong JWT secret (256-bit random)
- [ ] Enable PostgreSQL SSL (`sslmode=require`)
- [ ] Firewall rules (only allow 443 inbound)
- [ ] Rate limiting (Caddy or NGINX)
- [ ] Regular backups (PostgreSQL + Redis)
- [ ] Monitor logs for suspicious activity

---

## macOS App Deployment

### 1. Build

```bash
cd mac-app

# Resolve dependencies
swift build

# Create release build
swift build -c release
```

### 2. Code Signing

**Requirements:**
- Apple Developer account ($99/year)
- Developer ID Application certificate

**Steps:**
```bash
# Sign app
codesign --deep --force --verify --verbose \
  --sign "Developer ID Application: Your Name (TEAM_ID)" \
  --options runtime \
  --entitlements ClipboardMac.entitlements \
  ClipboardMac.app

# Verify signature
codesign --verify --verbose=4 ClipboardMac.app
```

**Entitlements (ClipboardMac.entitlements):**
```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "...">
<plist version="1.0">
<dict>
    <key>com.apple.security.network.client</key>
    <true/>
    <key>com.apple.security.cs.allow-unsigned-executable-memory</key>
    <false/>
</dict>
</plist>
```

### 3. Notarization

```bash
# Create DMG
hdiutil create -volname "Clipboard Sync" -srcfolder ClipboardMac.app -ov -format UDZO ClipboardSync.dmg

# Notarize
xcrun notarytool submit ClipboardSync.dmg \
  --apple-id you@example.com \
  --team-id TEAM_ID \
  --password "app-specific-password" \
  --wait

# Staple ticket
xcrun stapler staple ClipboardSync.dmg
```

### 4. Distribution

**Option A: Direct Download**
- Host DMG on your website
- Provide SHA256 checksum

**Option B: Homebrew Cask**
```ruby
# clipshare.rb
cask "clipshare" do
  version "0.1.0"
  sha256 "..."
  url "https://github.com/yourorg/clipshare/releases/download/v#{version}/ClipboardSync.dmg"
  name "Clipboard Sync"
  homepage "https://clipshare.example.com"
  app "ClipboardMac.app"
end
```

---

## Android App Deployment

### 1. Build Release APK

**Configure signing (app/build.gradle):**
```gradle
android {
    signingConfigs {
        release {
            storeFile file("../keystore.jks")
            storePassword System.getenv("KEYSTORE_PASSWORD")
            keyAlias "clipshare"
            keyPassword System.getenv("KEY_PASSWORD")
        }
    }
    buildTypes {
        release {
            signingConfig signingConfigs.release
            minifyEnabled true
            proguardFiles getDefaultProguardFile('proguard-android-optimize.txt'), 'proguard-rules.pro'
        }
    }
}
```

**Build:**
```bash
cd android-app

# Generate keystore (first time only)
keytool -genkey -v -keystore keystore.jks -keyalg RSA -keysize 2048 -validity 10000 -alias clipshare

# Build release APK
./gradlew assembleRelease

# Output: app/build/outputs/apk/release/app-release.apk
```

### 2. ProGuard Configuration

**app/proguard-rules.pro:**
```proguard
# Keep Gson models
-keep class com.clipshare.android.service.PlainItem { *; }
-keep class com.clipshare.android.crypto.CryptoBox$Envelope { *; }

# Keep Room entities
-keep class com.clipshare.android.data.** { *; }

# Tink crypto
-keep class com.google.crypto.tink.** { *; }

# OkHttp
-dontwarn okhttp3.**
-keep class okhttp3.** { *; }
```

### 3. Google Play Store

**Steps:**
1. Create developer account ($25 one-time)
2. Create app listing
3. Upload APK/AAB to Internal Testing track
4. Request review for production

**Play Store Metadata:**
- App name: "Clipboard Sync"
- Category: Productivity / Tools
- Privacy policy URL (required)
- Screenshots (phone + tablet)

**Privacy Policy Requirements:**
- Disclose data collection (none for E2E)
- Explain clipboard access usage
- Link to open-source repo

### 4. F-Droid (Alternative)

```yaml
# metadata/com.clipshare.android.yml
Categories:
  - Internet
License: MIT
WebSite: https://github.com/yourorg/clipshare
SourceCode: https://github.com/yourorg/clipshare
IssueTracker: https://github.com/yourorg/clipshare/issues

Summary: End-to-end encrypted clipboard sync
Description: |
  Securely sync clipboard between Android and macOS devices using
  end-to-end encryption. Server never sees plaintext.
```

---

## Monitoring & Maintenance

### Metrics to Track

**Backend:**
- Active WebSocket connections
- Messages routed per minute
- Queue depth (offline messages)
- JWT validation failures
- Database connection pool usage

**Clients:**
- Crash reports (Sentry, Crashlytics)
- Sync latency (p50, p95, p99)
- Failed pairing attempts
- Reconnection frequency

### Health Checks

**Endpoint:** `/healthz`
```bash
curl https://wss.example.com/healthz
# Expected: HTTP 200 OK
```

**Prometheus Metrics:** `/metrics`
```
# HELP clipshare_connections_active Current WebSocket connections
# TYPE clipshare_connections_active gauge
clipshare_connections_active 42

# HELP clipshare_messages_routed_total Messages routed
# TYPE clipshare_messages_routed_total counter
clipshare_messages_routed_total 12345
```

### Backup Strategy

**PostgreSQL:**
```bash
# Daily backup
pg_dump clipshare | gzip > backup-$(date +%Y%m%d).sql.gz

# Restore
gunzip < backup-20250102.sql.gz | psql clipshare
```

**Redis:** (Optional, since it's just a cache)
```bash
redis-cli SAVE
cp /var/lib/redis/dump.rdb /backup/
```

---

## Troubleshooting

### Backend Won't Start
- Check PostgreSQL connection: `psql $DATABASE_URL`
- Check Redis connection: `redis-cli ping`
- Verify JWT_SECRET is set
- Check port availability: `lsof -i :8080`

### macOS App Can't Connect
- Verify server URL in Preferences
- Check firewall allows outbound port 443
- Test WebSocket: `wscat -c wss://your-server.com/ws`

### Android Service Keeps Dying
- Disable battery optimization
- Check logs: `adb logcat | grep ClipboardSync`
- Verify foreground service permission

### Messages Not Syncing
- Check both devices are online (green status)
- Verify device tokens valid (check server logs)
- Test encryption: send "test" and check database has encrypted blob

---

**Last Updated:** 2025-01-02
**Version:** 0.1.0
