import Cocoa

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusBar: StatusBarController?
    var wsClient: WebSocketClient?
    var clipboardManager: ClipboardManager?
    var cryptoBox: CryptoBox?
    var hotkeyManager: HotkeyManager?
    var outboxStore: OutboxStore?
    private var stagedRouteAwaitingAck: Message?
    var pairingWindowController: PairingWindowController?
    private let usr1Source = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
    var settingsWindowController: SettingsWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Initialize components
        self.cryptoBox = CryptoBox()
        self.clipboardManager = ClipboardManager()
        self.hotkeyManager = HotkeyManager()
        self.wsClient = WebSocketClient()
        self.outboxStore = OutboxStore()

        // Initialize status bar - critical for menu bar visibility
        // Must be created synchronously on the main thread
        self.statusBar = StatusBarController()

        // Setup dependencies
        statusBar?.delegate = self
        wsClient?.delegate = self
        hotkeyManager?.delegate = self
        wsClient?.onAuthRejected = { [weak self] in self?.showPairingWindow() }

        // Check if device is paired
        if let deviceToken = KeychainHelper.getDeviceToken() {
            connectToServer(token: deviceToken)
        } else {
            // Show pairing window
            showPairingWindow()
        }

        // ⌥⌘V paste staged item, ⌘⇧I silent screenshot → Android
        hotkeyManager?.registerHotkeys()
        // `kill -USR1 <pid>` = same as ⌘⇧I (scripting / testing without a keypress).
        signal(SIGUSR1, SIG_IGN)
        usr1Source.setEventHandler { [weak self] in self?.hotkeyDidTriggerScreenshot() }
        usr1Source.resume()

        // Set menu bar status
        statusBar?.setStatus(.disconnected)

        print("✓ Status bar initialized")
    }

    func applicationWillTerminate(_ notification: Notification) {
        clipboardManager?.stopMonitoring()
        wsClient?.disconnect()
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        return true
    }

    // MARK: - Connection Management

    func connectToServer(token: String) {
        // Get base server URL and convert to WebSocket URL
        var serverURL = UserDefaults.standard.string(forKey: "serverURL") ?? "http://127.0.0.1:8080"

        // Convert http(s):// to ws(s)://
        if serverURL.hasPrefix("http://") {
            serverURL = "ws://" + serverURL.dropFirst(7)
        } else if serverURL.hasPrefix("https://") {
            serverURL = "wss://" + serverURL.dropFirst(8)
        }

        // Ensure /ws path is added
        if !serverURL.hasSuffix("/ws") {
            serverURL = serverURL + "/ws"
        }

        wsClient?.connect(url: serverURL, token: token)
        statusBar?.setStatus(.connecting)
    }

    func disconnectFromServer() {
        clipboardManager?.stopMonitoring()
        wsClient?.disconnect()
        statusBar?.setStatus(.disconnected)
    }

    func showPairingWindow() {
        if let window = pairingWindowController?.window, window.isVisible {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        pairingWindowController = PairingWindowController()
        pairingWindowController?.delegate = self
        pairingWindowController?.showWindow(nil)
        pairingWindowController?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Bi-directional Clipboard Sync

    func startClipboardSync() {
        // Start monitoring local clipboard for outgoing sync
        clipboardManager?.startMonitoring { [weak self] content in
            self?.sendClipboardToPeer(content)
        }
    }

    func sendClipboardToPeer(_ content: LocalClipboardContent, kind: String = "clipboard_item") {
        guard let cryptoBox = cryptoBox else {
            return
        }

        // Verify we have session key
        guard cryptoBox.hasSessionKey() else {
            print("✗ Cannot send: no session key (device not paired)")
            return
        }

        let plainItem: PlainItem
        switch content {
        case .text(let text):
            guard text.utf8.count <= 64 * 1024 else {
                print("✗ Text clipboard exceeds the 64 KiB limit")
                return
            }
            plainItem = cryptoBox.createPlainItem(text: text)
        case .image(let data, let mimeType):
            guard data.count <= 5 * 1024 * 1024 else {
                print("✗ Image clipboard exceeds the 5 MiB limit")
                return
            }
            plainItem = cryptoBox.createPlainItem(imageData: data, mimeType: mimeType, kind: kind)
        }

        do {
            // Encrypt to envelope JSON
            let envelopeJSON = try cryptoBox.encryptToJSON(plainItem)

            // Create route message
            let peerDeviceID = UserDefaults.standard.string(forKey: "peerDeviceID") ?? "unknown"
            guard peerDeviceID != "unknown" else { return }
            let message = Message(
                id: plainItem.id,
                type: "route",
                from: getDeviceID(),
                to: peerDeviceID,
                data: envelopeJSON,
                qos: "at-least-once",
                status: nil
            )

            // Persist before the socket write. The relay de-duplicates by ID,
            // so reconnect retries are safe and no local clipboard change is lost.
            outboxStore?.enqueue(message)
            if wsClient?.isConnected == true {
                wsClient?.sendMessage(message)
            }

            print("→ Sent clipboard to \(peerDeviceID)")

        } catch {
            print("✗ Failed to encrypt clipboard: \(error.localizedDescription)")
        }
    }
}

// MARK: - StatusBarControllerDelegate

extension AppDelegate: StatusBarControllerDelegate {
    func statusBarDidRequestPairing() {
        showPairingWindow()
    }

    func statusBarDidRequestDisconnect() {
        disconnectFromServer()
    }

    func statusBarDidRequestQuit() {
        NSApplication.shared.terminate(nil)
    }

    func statusBarDidRequestSettings() {
        settingsWindowController = SettingsWindowController()
        settingsWindowController?.showWindow(nil)
        settingsWindowController?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

// MARK: - WebSocketClientDelegate

extension AppDelegate: WebSocketClientDelegate {
    func webSocketDidConnect() {
        statusBar?.setStatus(.connected)
        print("✓ Connected to server")

        // Start bi-directional clipboard sync
        startClipboardSync()
        for route in outboxStore?.pendingRoutes() ?? [] {
            wsClient?.sendMessage(route)
        }
    }

    func webSocketDidDisconnect(error: Error?) {
        statusBar?.setStatus(.disconnected)
        clipboardManager?.stopMonitoring()

        if let error = error {
            print("✗ Disconnected: \(error.localizedDescription)")
        } else {
            print("✗ Disconnected from server")
        }
    }

    func webSocketDidReceiveMessage(_ message: Message) {
        if message.type == "ack", let id = message.id {
            outboxStore?.acknowledge(id)
            return
        }
        handleIncomingClipboard(message)
    }

    func handleIncomingClipboard(_ message: Message) {
        guard message.type == "route",
              let routeID = message.id,
              let encryptedData = message.data,
              let cryptoBox = cryptoBox else { return }

        // Decrypt envelope
        guard let plainItem = try? cryptoBox.decrypt(encryptedData) else {
            print("✗ Failed to decrypt message")
            return
        }

        guard plainItem.id == routeID else {
            print("✗ Rejected route with mismatched encrypted message ID")
            return
        }

        // Mark as received to prevent echo
        clipboardManager?.markAsReceived(plainItem)

        // Stage clipboard item
        clipboardManager?.stageItem(plainItem)

        // New installs sync immediately. Users can opt into staging in
        // Settings; staged items are ACKed only after the paste action.
        let autoOverwrite = (UserDefaults.standard.object(forKey: "autoOverwriteClipboard") as? Bool) ?? true

        if autoOverwrite {
            guard clipboardManager?.applyStaged() != nil else {
                print("✗ Failed to apply received clipboard item")
                return
            }
            NotificationHelper.show(
                title: "Clipboard Synced",
                body: "From \(plainItem.sourceName ?? "Android"): \(plainItem.preview)"
            )
            sendAcknowledgement(for: message)
        } else {
            stagedRouteAwaitingAck = message
            NotificationHelper.show(
                title: "Clipboard Ready",
                body: "From \(plainItem.sourceName ?? "Android"): Press Option+Command+V to paste"
            )
        }
    }

    private func sendAcknowledgement(for route: Message) {
        guard let routeID = route.id else { return }
        let ack = AckMessage(id: routeID, from: getDeviceID(), to: route.from, status: "ok")
        wsClient?.sendAck(ack)
    }

    func getDeviceID() -> String {
        if let deviceID = UserDefaults.standard.string(forKey: "deviceID") {
            return deviceID
        }
        let newID = "mac-\(UUID().uuidString.prefix(12))"
        UserDefaults.standard.set(newID, forKey: "deviceID")
        return newID
    }
}

// MARK: - HotkeyManagerDelegate

extension AppDelegate: HotkeyManagerDelegate {
    func hotkeyDidTriggerPaste() {
        guard let clipboardManager = clipboardManager else { return }

        if clipboardManager.applyStaged() != nil {
            if let route = stagedRouteAwaitingAck {
                sendAcknowledgement(for: route)
                stagedRouteAwaitingAck = nil
            }
            // Check if we have Accessibility permission
            if AccessibilityHelper.hasPermission() {
                // Write to pasteboard and simulate Cmd+V
                // Small delay to ensure paste buffer is ready
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    AccessibilityHelper.simulateCmdV()
                }
            } else {
                NotificationHelper.show(
                    title: "Clipboard Updated",
                    body: "Press Command+V to paste manually"
                )
            }
        } else {
            // No staged item
            NotificationHelper.show(
                title: "No Clipboard",
                body: "No synced clipboard item available"
            )
        }
    }
}

extension AppDelegate {
    func hotkeyDidTriggerScreenshot() {
        // Deliberately silent: no sound, no thumbnail, no notification, Mac clipboard untouched.
        ScreenshotSender.capture { [weak self] data, mimeType in
            self?.sendClipboardToPeer(.image(data: data, mimeType: mimeType), kind: "screenshot")
        }
    }
}

// MARK: - PairingWindowDelegate

extension AppDelegate: PairingWindowDelegate {
    func pairingDidComplete(deviceToken: String, peerDeviceID: String) {
        KeychainHelper.saveDeviceToken(deviceToken)
        UserDefaults.standard.set(peerDeviceID, forKey: "peerDeviceID")
        // Queued routes were encrypted for the previous peer and can never be ACKed.
        outboxStore?.removeAll()

        // Reload crypto keys to pick up the peer public key saved during pairing
        cryptoBox?.loadKeys()

        connectToServer(token: deviceToken)
    }

    func pairingDidCancel() {
        // User cancelled pairing
        print("Pairing cancelled by user")
    }
}

// MARK: - Protocol Definitions

protocol StatusBarControllerDelegate: AnyObject {
    func statusBarDidRequestPairing()
    func statusBarDidRequestDisconnect()
    func statusBarDidRequestQuit()
    func statusBarDidRequestSettings()
}

protocol WebSocketClientDelegate: AnyObject {
    func webSocketDidConnect()
    func webSocketDidDisconnect(error: Error?)
    func webSocketDidReceiveMessage(_ message: Message)
}

protocol HotkeyManagerDelegate: AnyObject {
    func hotkeyDidTriggerPaste()
    func hotkeyDidTriggerScreenshot()
}

protocol PairingWindowDelegate: AnyObject {
    func pairingDidComplete(deviceToken: String, peerDeviceID: String)
    func pairingDidCancel()
}
