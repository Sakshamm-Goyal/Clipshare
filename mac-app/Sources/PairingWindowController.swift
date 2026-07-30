import Cocoa
import CoreImage

class PairingWindowController: NSWindowController {
    weak var delegate: PairingWindowDelegate?

    private var qrImageView: NSImageView!
    private var statusLabel: NSTextField!
    private var cancelButton: NSButton!
    private var progressIndicator: NSProgressIndicator!
    private var cryptoBox: CryptoBox!

    // Pairing state
    private var pairingToken: String?
    private var deviceID: String?
    private var pairingWebSocket: URLSessionWebSocketTask?
    private var urlSession: URLSession!

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 520),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Pair New Device"
        window.center()

        super.init(window: window)

        urlSession = URLSession(configuration: .default)
        setupUI()
        startPairing()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupUI() {
        guard let contentView = window?.contentView else { return }

        // Title
        let titleLabel = NSTextField(labelWithString: "Scan QR Code with Android App")
        titleLabel.font = NSFont.systemFont(ofSize: 16, weight: .semibold)
        titleLabel.frame = NSRect(x: 50, y: 460, width: 300, height: 30)
        titleLabel.alignment = .center
        contentView.addSubview(titleLabel)

        // QR Code
        qrImageView = NSImageView(frame: NSRect(x: 50, y: 150, width: 300, height: 300))
        qrImageView.imageScaling = .scaleProportionallyUpOrDown
        contentView.addSubview(qrImageView)

        // Progress indicator
        progressIndicator = NSProgressIndicator(frame: NSRect(x: 175, y: 280, width: 50, height: 50))
        progressIndicator.style = .spinning
        progressIndicator.isHidden = true
        contentView.addSubview(progressIndicator)

        // Status
        statusLabel = NSTextField(labelWithString: "Initializing...")
        statusLabel.font = NSFont.systemFont(ofSize: 12)
        statusLabel.frame = NSRect(x: 50, y: 110, width: 300, height: 30)
        statusLabel.alignment = .center
        statusLabel.textColor = .secondaryLabelColor
        contentView.addSubview(statusLabel)

        // Cancel button
        cancelButton = NSButton(title: "Cancel", target: self, action: #selector(cancelPairing))
        cancelButton.frame = NSRect(x: 150, y: 20, width: 100, height: 32)
        contentView.addSubview(cancelButton)
    }

    private func startPairing() {
        NSLog("=== startPairing() called ===")
        cryptoBox = CryptoBox()

        // Generate device ID
        let shortID = UUID().uuidString.prefix(12)
        deviceID = "mac-\(shortID)"

        guard let publicKeyBase64 = cryptoBox.getPublicKeyBase64() else {
            updateStatus("Failed to generate keys", isError: true)
            return
        }

        // Save device ID
        UserDefaults.standard.set(deviceID, forKey: "deviceID")

        // Get server URL from settings
        let serverURL = UserDefaults.standard.string(forKey: "serverURL") ?? "http://localhost:8080"
        let deviceName = Host.current().localizedName ?? "Mac"

        updateStatus("Connecting to server...")

        // Call backend to start pairing
        guard let url = URL(string: "\(serverURL)/v1/pair/start") else {
            updateStatus("Invalid server URL", isError: true)
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 10

        let body: [String: String] = [
            "device_id": deviceID!,
            "device_name": deviceName,
            "public_key": publicKeyBase64,
            "platform": "macos"
        ]

        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        NSLog("→ Sending pairing request to: %@", url.absoluteString)

        let task = URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard let self = self else {
                NSLog("✗ Self is nil in completion handler")
                return
            }

            if let error = error {
                NSLog("✗ Pairing request failed: %@", error.localizedDescription)
                NSLog("✗ Error details: %@", (error as NSError).debugDescription)
                DispatchQueue.main.async {
                    self.updateStatus("Connection failed: \(error.localizedDescription)", isError: true)
                }
                return
            }
            NSLog("✓ Got response from server")

            guard let httpResponse = response as? HTTPURLResponse else {
                DispatchQueue.main.async {
                    self.updateStatus("Invalid response from server", isError: true)
                }
                return
            }

            guard httpResponse.statusCode == 200, let data = data else {
                DispatchQueue.main.async {
                    self.updateStatus("Server error: \(httpResponse.statusCode)", isError: true)
                }
                return
            }

            do {
                let pairingResponse = try JSONDecoder().decode(PairingResponse.self, from: data)
                self.pairingToken = pairingResponse.token

                DispatchQueue.main.async {
                    self.showQRCode(pairingResponse)
                    self.connectToPairingWebSocket(pairingResponse)
                }

            } catch {
                NSLog("✗ Failed to parse response: %@", error.localizedDescription)
                DispatchQueue.main.async {
                    self.updateStatus("Failed to parse response", isError: true)
                }
            }
        }
        NSLog("→ Starting task...")
        task.resume()
        NSLog("→ Task resumed")
    }

    private func showQRCode(_ response: PairingResponse) {
        // Create QR code data
        let qrData: [String: String] = [
            "server": response.serverURL,
            "token": response.token,
            "device_id": response.deviceID,
            "device_pub": response.devicePub
        ]

        guard let qrJSON = try? JSONSerialization.data(withJSONObject: qrData),
              let qrString = String(data: qrJSON, encoding: .utf8) else {
            updateStatus("Failed to generate QR code", isError: true)
            return
        }

        // Base64 encode for QR code
        let base64QR = qrString.data(using: .utf8)!.base64EncodedString()

        displayQRCode(base64QR)
        updateStatus("Scan this QR code with the Android app")
    }

    private func displayQRCode(_ content: String) {
        guard let qrFilter = CIFilter(name: "CIQRCodeGenerator") else { return }

        qrFilter.setValue(content.data(using: .utf8), forKey: "inputMessage")
        qrFilter.setValue("H", forKey: "inputCorrectionLevel")

        guard let qrImage = qrFilter.outputImage else { return }

        // Scale up
        let transform = CGAffineTransform(scaleX: 10, y: 10)
        let scaledQR = qrImage.transformed(by: transform)

        let rep = NSCIImageRep(ciImage: scaledQR)
        let nsImage = NSImage(size: rep.size)
        nsImage.addRepresentation(rep)

        qrImageView.image = nsImage
    }

    private func connectToPairingWebSocket(_ response: PairingResponse) {
        NSLog("=== connectToPairingWebSocket called ===")
        NSLog("→ Server URL from response: %@", response.serverURL)

        // Use the server URL from the pairing response
        // The serverURL is in format "ws://host:port/pair", we need to add query params
        var wsURL = response.serverURL

        // Try localhost first if the Mac is on the same machine as the server
        // Otherwise use the server URL directly
        let serverURLFromPrefs = UserDefaults.standard.string(forKey: "serverURL") ?? "http://localhost:8080"

        // Build WebSocket URL based on server URL
        if serverURLFromPrefs.contains("localhost") || serverURLFromPrefs.contains("127.0.0.1") {
            // Local server - use localhost for Mac connection
            if serverURLFromPrefs.hasPrefix("http://") {
                let hostPort = String(serverURLFromPrefs.dropFirst(7))
                wsURL = "ws://\(hostPort)/pair"
            } else if serverURLFromPrefs.hasPrefix("https://") {
                let hostPort = String(serverURLFromPrefs.dropFirst(8))
                wsURL = "wss://\(hostPort)/pair"
            } else {
                wsURL = "ws://\(serverURLFromPrefs)/pair"
            }
        }
        // Otherwise use the URL from response (for when backend is remote)

        wsURL += "?token=\(response.token)&role=originator"

        NSLog("→ Final WebSocket URL: %@", wsURL)

        guard let url = URL(string: wsURL) else {
            NSLog("✗ Invalid WebSocket URL")
            updateStatus("Invalid WebSocket URL", isError: true)
            return
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 600 // 10 minutes for pairing

        pairingWebSocket = urlSession.webSocketTask(with: request)
        NSLog("→ WebSocket task created, resuming...")
        pairingWebSocket?.resume()

        // Start listening for messages
        listenForPairingMessages()

        updateStatus("Waiting for Android device to scan...")
    }

    private func listenForPairingMessages() {
        NSLog("→ Listening for pairing messages...")
        pairingWebSocket?.receive { [weak self] result in
            guard let self = self else {
                NSLog("✗ Self is nil in WebSocket receive")
                return
            }

            switch result {
            case .success(let message):
                NSLog("✓ Received WebSocket message")
                switch message {
                case .string(let text):
                    self.handlePairingMessage(text)
                case .data(let data):
                    NSLog("→ Message data: %d bytes", data.count)
                    if let text = String(data: data, encoding: .utf8) {
                        self.handlePairingMessage(text)
                    }
                @unknown default:
                    NSLog("→ Unknown message type")
                    break
                }

            case .failure(let error):
                NSLog("✗ WebSocket receive error: %@", error.localizedDescription)
                DispatchQueue.main.async {
                    self.updateStatus("Connection lost: \(error.localizedDescription)", isError: true)
                }
            }
        }
    }

    private func handlePairingMessage(_ text: String) {
        NSLog("=== handlePairingMessage called ===")

        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            NSLog("✗ Failed to parse JSON")
            DispatchQueue.main.async {
                self.updateStatus("Invalid message received", isError: true)
            }
            return
        }

        NSLog("→ Parsed JSON keys: %@", json.keys.joined(separator: ", "))

        // Check for error
        if let error = json["error"] as? String {
            NSLog("✗ Error in response: %@", error)
            DispatchQueue.main.async {
                self.updateStatus("Pairing failed: \(error)", isError: true)
            }
            return
        }

        // Check for success
        if let status = json["status"] as? String, status == "success" {
            guard let originalToken = json["original_token"] as? String,
                  let peerDeviceID = json["peer_device"] as? String else {
                NSLog("✗ Missing required fields: original_token or peer_device")
                DispatchQueue.main.async {
                    self.updateStatus("Invalid pairing response", isError: true)
                }
                return
            }

            // Get peer's public key - backend sends it as "peer_pub"
            guard let peerPubKey = json["peer_pub"] as? String else {
                NSLog("✗ Missing peer_pub field")
                DispatchQueue.main.async {
                    self.updateStatus("Invalid pairing response: missing peer key", isError: true)
                }
                return
            }
        // Set the peer's public key for encryption
            do {
                try self.cryptoBox.setPeerPublicKeyBase64(peerPubKey)
                NSLog("✓ Peer public key set successfully")
            } catch {
                NSLog("✗ Failed to set peer key: %@", error.localizedDescription)
                DispatchQueue.main.async {
                    self.updateStatus("Failed to set peer key: \(error.localizedDescription)", isError: true)
                }
                return
            }

            DispatchQueue.main.async {
                self.completePairing(deviceToken: originalToken, peerDeviceID: peerDeviceID)
            }
        } else {
            // Continue listening
            listenForPairingMessages()
        }
    }

    private func completePairing(deviceToken: String, peerDeviceID: String) {
        // Save credentials
        KeychainHelper.saveDeviceToken(deviceToken)
        UserDefaults.standard.set(peerDeviceID, forKey: "peerDeviceID")

        updateStatus("Pairing successful!", isError: false)

        // Show success briefly, then close
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            self.pairingWebSocket?.cancel(with: .normalClosure, reason: nil)
            self.delegate?.pairingDidComplete(deviceToken: deviceToken, peerDeviceID: peerDeviceID)
            self.close()
        }
    }

    private func updateStatus(_ text: String, isError: Bool = false) {
        statusLabel.stringValue = isError ? "✗ \(text)" : text
        statusLabel.textColor = isError ? .systemRed : .secondaryLabelColor
    }

    @objc private func cancelPairing() {
        pairingWebSocket?.cancel(with: .normalClosure, reason: nil)
        delegate?.pairingDidCancel()
        close()
    }

    deinit {
        pairingWebSocket?.cancel(with: .normalClosure, reason: nil)
    }
}

struct PairingResponse: Codable {
    let token: String
    let serverURL: String
    let expiresAt: String
    let deviceID: String
    let devicePub: String

    enum CodingKeys: String, CodingKey {
        case token
        case serverURL = "server_url"
        case expiresAt = "expires_at"
        case deviceID = "device_id"
        case devicePub = "device_pub"
    }
}

class SettingsWindowController: NSWindowController {
    private var serverURLField: NSTextField!
    private var autoSyncCheckbox: NSButton!
    private var saveButton: NSButton!
    private var unpairButton: NSButton!

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 450, height: 350),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Settings"
        window.center()

        super.init(window: window)

        setupUI()
        loadSettings()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupUI() {
        guard let contentView = window?.contentView else { return }

        // Server URL
        let serverLabel = NSTextField(labelWithString: "Server URL:")
        serverLabel.frame = NSRect(x: 30, y: 280, width: 100, height: 20)
        contentView.addSubview(serverLabel)

        serverURLField = NSTextField(frame: NSRect(x: 130, y: 278, width: 280, height: 24))
        serverURLField.placeholderString = "http://localhost:8080"
        contentView.addSubview(serverURLField)

        // Auto-sync clipboard
        autoSyncCheckbox = NSButton(checkboxWithTitle: "Auto-sync clipboard (overwrite without hotkey)", target: nil, action: nil)
        autoSyncCheckbox.frame = NSRect(x: 30, y: 230, width: 380, height: 20)
        contentView.addSubview(autoSyncCheckbox)

        // Divider
        let divider = NSBox(frame: NSRect(x: 30, y: 180, width: 390, height: 1))
        divider.boxType = .separator
        contentView.addSubview(divider)

        // Device Info Section
        let deviceLabel = NSTextField(labelWithString: "Device Management")
        deviceLabel.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        deviceLabel.frame = NSRect(x: 30, y: 145, width: 200, height: 20)
        contentView.addSubview(deviceLabel)

        let deviceIDLabel = NSTextField(labelWithString: "Device ID:")
        deviceIDLabel.frame = NSRect(x: 30, y: 115, width: 80, height: 20)
        contentView.addSubview(deviceIDLabel)

        let deviceID = UserDefaults.standard.string(forKey: "deviceID") ?? "Not set"
        let deviceIDValue = NSTextField(labelWithString: deviceID)
        deviceIDValue.frame = NSRect(x: 110, y: 115, width: 300, height: 20)
        deviceIDValue.textColor = .secondaryLabelColor
        contentView.addSubview(deviceIDValue)

        let peerLabel = NSTextField(labelWithString: "Paired with:")
        peerLabel.frame = NSRect(x: 30, y: 90, width: 80, height: 20)
        contentView.addSubview(peerLabel)

        let peerID = UserDefaults.standard.string(forKey: "peerDeviceID") ?? "Not paired"
        let peerIDValue = NSTextField(labelWithString: peerID)
        peerIDValue.frame = NSRect(x: 110, y: 90, width: 300, height: 20)
        peerIDValue.textColor = .secondaryLabelColor
        contentView.addSubview(peerIDValue)

        // Unpair button
        unpairButton = NSButton(title: "Unpair Device", target: self, action: #selector(unpairDevice))
        unpairButton.frame = NSRect(x: 30, y: 50, width: 120, height: 32)
        unpairButton.bezelStyle = .rounded
        unpairButton.isEnabled = KeychainHelper.getDeviceToken() != nil
        contentView.addSubview(unpairButton)

        // Save button
        saveButton = NSButton(title: "Save Settings", target: self, action: #selector(saveSettings))
        saveButton.frame = NSRect(x: 300, y: 50, width: 120, height: 32)
        saveButton.bezelStyle = .rounded
        saveButton.keyEquivalent = "\r"
        contentView.addSubview(saveButton)
    }

    private func loadSettings() {
        serverURLField.stringValue = UserDefaults.standard.string(forKey: "serverURL") ?? "http://localhost:8080"
        let autoOverwrite = (UserDefaults.standard.object(forKey: "autoOverwriteClipboard") as? Bool) ?? true
        autoSyncCheckbox.state = autoOverwrite ? .on : .off
    }

    @objc private func saveSettings() {
        let serverURL = serverURLField.stringValue.isEmpty ? "http://localhost:8080" : serverURLField.stringValue
        UserDefaults.standard.set(serverURL, forKey: "serverURL")
        UserDefaults.standard.set(autoSyncCheckbox.state == .on, forKey: "autoOverwriteClipboard")

        close()
    }

    @objc private func unpairDevice() {
        let alert = NSAlert()
        alert.messageText = "Unpair Device"
        alert.informativeText = "Are you sure you want to unpair this device? You will need to scan the QR code again to reconnect."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Unpair")
        alert.addButton(withTitle: "Cancel")

        if alert.runModal() == .alertFirstButtonReturn {
            // Clear all pairing data
            KeychainHelper.deleteDeviceToken()
            KeychainHelper.deletePeerPublicKey()
            UserDefaults.standard.removeObject(forKey: "peerDeviceID")

            // Update UI
            unpairButton.isEnabled = false

            // Show confirmation
            let confirmAlert = NSAlert()
            confirmAlert.messageText = "Device Unpaired"
            confirmAlert.informativeText = "Please restart the app to pair with a new device."
            confirmAlert.alertStyle = .informational
            confirmAlert.runModal()

            close()
        }
    }
}
