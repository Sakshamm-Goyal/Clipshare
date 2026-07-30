# Build Guide

Complete instructions for building all components from source.

## Prerequisites

### Backend (Go)
- Go 1.22 or later
- PostgreSQL 15+ (for development)
- Redis 7+ (for development)

### macOS App
- macOS 13+ (Ventura or later)
- Xcode 15+ or Swift 5.9+ command-line tools

### Android App
- Android Studio Hedgehog (2023.1.1) or later
- JDK 17
- Android SDK API 34
- Minimum device: Android 8.0 (API 26)

---

## Backend Setup

### 1. Install Dependencies

**macOS:**
```bash
brew install go postgresql@15 redis
brew services start postgresql
brew services start redis
```

**Ubuntu/Debian:**
```bash
sudo apt update
sudo apt install golang-1.22 postgresql-15 redis-server
sudo systemctl start postgresql redis-server
```

### 2. Setup Database

```bash
# Create database
createdb clipshare

# (Optional) Create dedicated user
psql postgres
CREATE USER clipshare WITH PASSWORD 'devpassword';
GRANT ALL PRIVILEGES ON DATABASE clipshare TO clipshare;
\q
```

### 3. Configuration

Create `.env` in `backend/` directory:
```bash
DATABASE_URL=postgres://clipshare:devpassword@localhost:5432/clipshare?sslmode=disable
REDIS_URL=localhost:6379
JWT_SECRET=dev-secret-change-in-production-min-32-bytes-long
```

### 4. Build & Run

```bash
cd backend

# Download dependencies
go mod download

# Run tests (optional)
go test ./...

# Build
go build -o clipshare-server cmd/server/main.go

# Run
./clipshare-server -addr :8080

# Or run directly without building
go run cmd/server/main.go -addr :8080
```

**Expected output:**
```
Starting server on :8080
Device connected: mac-abc123 (total: 1)
```

### 5. Verify

```bash
# Health check
curl http://localhost:8080/healthz
# Expected: ok

# Check WebSocket upgrade
curl -i -N -H "Connection: Upgrade" \
  -H "Upgrade: websocket" \
  -H "Sec-WebSocket-Version: 13" \
  -H "Sec-WebSocket-Key: test" \
  http://localhost:8080/ws
# Expected: 401 Unauthorized (needs JWT)
```

---

## macOS App Setup

### Option 1: Swift Package Manager (CLI)

```bash
cd mac-app

# Resolve dependencies
swift package resolve

# Build
swift build

# Run
swift run
```

### Option 2: Xcode

```bash
cd mac-app

# Open the Swift package directly in Xcode
open Package.swift
```

**In Xcode:**
1. Select scheme: `ClipboardMac`
2. Select target: `My Mac`
3. Click Run (⌘R)

### Configuration

**Server URL:**
Edit `Sources/AppDelegate.swift`:
```swift
let serverURL = UserDefaults.standard.string(forKey: "serverURL") ?? "ws://localhost:8080/ws"
```

For development with `localhost`, use `ws://` (not `wss://`).

### Troubleshooting

**Issue:** "Cannot find 'Crypto' in scope"
```bash
swift package clean
swift package update
swift build
```

**Issue:** Hotkey not working
- Grant Accessibility permission:
  - System Settings → Privacy & Security → Accessibility
  - Add ClipboardMac app

---

## Android App Setup

### 1. Install Android Studio

Download from https://developer.android.com/studio

### 2. Open Project

```bash
# Open Android Studio
# File → Open → Select android-app/
```

### 3. Sync Gradle

Android Studio will automatically:
- Download Gradle wrapper
- Sync dependencies
- Download required SDK components

If not automatic:
- File → Sync Project with Gradle Files

### 4. Configure Emulator or Device

**Option A: Emulator**
1. Tools → Device Manager
2. Create Virtual Device
3. Select: Pixel 8 (API 34, Android 14)
4. Download system image
5. Finish

**Option B: Physical Device**
1. Enable Developer Options on phone:
   - Settings → About Phone → Tap "Build Number" 7 times
2. Enable USB Debugging:
   - Settings → Developer Options → USB Debugging
3. Connect via USB
4. Accept authorization prompt on phone

### 5. Update Server URL

Edit `android-app/app/src/main/java/com/clipshare/android/util/PrefsHelper.kt`:
```kotlin
fun getServerUrl(context: Context): String {
    return getPrefs(context).getString(KEY_SERVER_URL, "ws://10.0.2.2:8080/ws")
        ?: "ws://10.0.2.2:8080/ws"
}
```

**Note:** `10.0.2.2` is the Android emulator's alias for host machine `localhost`.

For physical device on same network:
```kotlin
"ws://192.168.1.100:8080/ws"  // Replace with your Mac's local IP
```

The phone must be able to reach the Mac on the same Wi-Fi network. If QR
pairing reports an unexpected connection failure while `localhost` works on the
Mac, allow the relay process or its chosen port through macOS Firewall before
retrying. Do not expose a development relay directly to the public internet.

### 6. Build & Run

**From Android Studio:**
1. Select device/emulator from dropdown
2. Click Run (▶) or press ⇧F10

**From Command Line:**
```bash
cd android-app

# Debug build
./gradlew assembleDebug

# Install on connected device
./gradlew installDebug

# Run
adb shell am start -n com.clipshare.android/.ui.MainActivity
```

### 7. Grant Permissions

On first run, grant:
1. **Notification** permission (Android 13+)
2. **Camera** permission (for QR scanning)

Android 10+ limits background clipboard reads. Mac → Android is automatic
while the foreground service is running. To send a clipboard item copied in
another Android app back to the Mac, return to ClipShare and tap **Send Current
Clipboard**.

To disable battery optimization:
1. Tap "Battery Optimization" button
2. Select "All apps"
3. Find "Clipboard Sync"
4. Select "Don't optimize"

---

## Full Stack Development Workflow

### Terminal 1: Backend
```bash
cd backend
go run cmd/server/main.go -addr :8080
```

### Terminal 2: macOS App
```bash
cd mac-app
swift run
```

### Terminal 3: Android App
```bash
cd android-app
./gradlew installDebug && adb logcat | grep ClipboardSync
```

### Testing E2E Flow

1. **Start Backend** (Terminal 1)
2. **Launch macOS App** (Terminal 2)
   - Click "Pair Device" from menu bar
   - QR code appears
3. **Launch Android App** (Android Studio or Terminal 3)
   - Tap "Pair with Mac"
   - Grant camera permission
   - Point camera at QR code on Mac
4. **Verify Pairing**
   - Android shows "✓ Pairing successful!"
   - Mac menubar shows green status
5. **Test Sync**
   - On Android: Copy text "Hello from Android"
   - On Mac: Toast appears, press ⌥⌘V to paste
   - On Mac: Copy text "Hello from Mac"
   - On Android: Notification appears (bi-directional)

---

## Common Build Issues

### Backend

**Issue:** `panic: pq: database "clipshare" does not exist`
```bash
createdb clipshare
```

**Issue:** `dial tcp [::1]:6379: connect: connection refused`
```bash
redis-server
# Or: brew services start redis
```

### macOS

**Issue:** `dyld: Library not loaded: @rpath/libswiftCore.dylib`
```bash
xcode-select --install
```

**Issue:** `Code signing required`
- In Xcode: Signing & Capabilities → Team → Select your Apple ID

### Android

**Issue:** `Could not find com.google.crypto.tink:tink-android:1.12.0`
```bash
# Check internet connection
# In Android Studio: File → Invalidate Caches → Invalidate and Restart
```

**Issue:** `Execution failed for task ':app:processDebugManifest'`
```bash
# Update compileSdk and targetSdk in app/build.gradle
android {
    compileSdk 34
    defaultConfig {
        targetSdk 34
    }
}
```

**Issue:** QR scanner crashes
```bash
# Grant camera permission manually
adb shell pm grant com.clipshare.android android.permission.CAMERA
```

---

## IDE Recommendations

### Backend
- **VS Code:** with Go extension
- **GoLand:** JetBrains IDE (paid)
- **Vim/Neovim:** with gopls LSP

### macOS
- **Xcode:** Official IDE (free)
- **VS Code:** with Swift extension
- **AppCode:** JetBrains IDE (discontinued, use Xcode)

### Android
- **Android Studio:** Official IDE (required)

---

## Continuous Integration

### GitHub Actions Example

```yaml
name: Build All

on: [push, pull_request]

jobs:
  backend:
    runs-on: ubuntu-latest
    services:
      postgres:
        image: postgres:15
        env:
          POSTGRES_DB: clipshare
          POSTGRES_PASSWORD: postgres
      redis:
        image: redis:7
    steps:
      - uses: actions/checkout@v3
      - uses: actions/setup-go@v4
        with:
          go-version: '1.22'
      - run: cd backend && go test ./...
      - run: cd backend && go build cmd/server/main.go

  macos:
    runs-on: macos-13
    steps:
      - uses: actions/checkout@v3
      - run: cd mac-app && swift build

  android:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v3
      - uses: actions/setup-java@v3
        with:
          java-version: '17'
          distribution: 'temurin'
      - run: cd android-app && ./gradlew assembleDebug
```

---

**Last Updated:** 2025-01-02
**Version:** 0.1.0
