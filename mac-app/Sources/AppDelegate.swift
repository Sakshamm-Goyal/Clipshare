import Cocoa

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusBar: StatusBarController?
    var wsClient: WebSocketClient?
    var clipboardManager: ClipboardManager?
    var cryptoBox: CryptoBox?
    var hotkeyManager: HotkeyManager?
    var pairingWindowController: PairingWindowController?
    var settingsWindowController: SettingsWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Initialize components
        self.cryptoBox = CryptoBox()
        self.clipboardManager = ClipboardManager()
        self.hotkeyManager = HotkeyManager()
        self.wsClient = WebSocketClient()

        // Initialize status bar - critical for menu bar visibility
        // Must be created synchronously on the main thread
        self.statusBar = StatusBarController()

        // Setup dependencies
        statusBar?.delegate = self
        wsClient?.delegate = self
        hotkeyManager?.delegate = self

        // Check if device is paired
        if let deviceToken = KeychainHelper.getDeviceToken() {
            connectToServer(token: deviceToken)
        } else {
            // Show pairing window
            showPairingWindow()
        }

        // Register hotkey (Option+Command+V)
        hotkeyManager?.registerPasteHotkey()

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
        var serverURL = UserDefaults.standard.string(forKey: "serverURL") ?? "http://localhost:8080"

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
        pairingWindowController = PairingWindowController()
        pairingWindowController?.delegate = self
        pairingWindowController?.showWindow(nil)
        pairingWindowController?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Bi-directional Clipboard Sync

    func startClipboardSync() {
        // Start monitoring local clipboard for outgoing sync
        clipboardManager?.startMonitoring { [weak self] text in
            self?.sendClipboardToPeer(text)
        }
    }

    func sendClipboardToPeer(_ text: String) {
        guard let cryptoBox = cryptoBox,
              let wsClient = wsClient,
              wsClient.isConnected else {
            print("✗ Cannot send: not connected")
            return
        }

        // Verify we have session key
        guard cryptoBox.hasSessionKey() else {
            print("✗ Cannot send: no session key (device not paired)")
            return
        }

        // Create plain item
        let plainItem = cryptoBox.createPlainItem(text: text)

        do {
            // Encrypt to envelope JSON
            let envelopeJSON = try cryptoBox.encryptToJSON(plainItem)

            // Create route message
            let peerDeviceID = UserDefaults.standard.string(forKey: "peerDeviceID") ?? "unknown"
            let message: [String: Any] = [
                "type": "route",
                "from": getDeviceID(),
                "to": peerDeviceID,
                "data": envelopeJSON,
                "qos": "at-least-once"
            ]

            // Send via WebSocket
            wsClient.sendMessage(message)

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
        handleIncomingClipboard(message)
    }

    func handleIncomingClipboard(_ message: Message) {
        guard let cryptoBox = cryptoBox else { return }

        // Decrypt envelope
        guard let plainItem = try? cryptoBox.decrypt(message.data) else {
            print("✗ Failed to decrypt message")
            return
        }

        // Mark as received to prevent echo
        clipboardManager?.markAsReceived(plainItem.payload.text)

        // Stage clipboard item
        clipboardManager?.stageItem(plainItem)

        // Check auto-overwrite setting
        let autoOverwrite = UserDefaults.standard.bool(forKey: "autoOverwriteClipboard")

        if autoOverwrite {
            clipboardManager?.applyStaged()
            NotificationHelper.show(
                title: "Clipboard Synced",
                body: "From \(plainItem.sourceName ?? "Android"): \(plainItem.preview)"
            )
        } else {
            NotificationHelper.show(
                title: "Clipboard Ready",
                body: "From \(plainItem.sourceName ?? "Android"): Press Option+Command+V to paste"
            )
        }

        // Send ACK
        let ack = AckMessage(id: plainItem.id, from: getDeviceID(), status: "ok")
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

        if let staged = clipboardManager.applyStaged() {
            // Check if we have Accessibility permission
            if AccessibilityHelper.hasPermission() {
                // Write to pasteboard and simulate Cmd+V
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(staged.payload.text, forType: .string)

                // Small delay to ensure paste buffer is ready
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    AccessibilityHelper.simulateCmdV()
                }
            } else {
                // Just write to clipboard and show instructions
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(staged.payload.text, forType: .string)

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

// MARK: - PairingWindowDelegate

extension AppDelegate: PairingWindowDelegate {
    func pairingDidComplete(deviceToken: String, peerDeviceID: String) {
        KeychainHelper.saveDeviceToken(deviceToken)
        UserDefaults.standard.set(peerDeviceID, forKey: "peerDeviceID")

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
}

protocol PairingWindowDelegate: AnyObject {
    func pairingDidComplete(deviceToken: String, peerDeviceID: String)
    func pairingDidCancel()
}
