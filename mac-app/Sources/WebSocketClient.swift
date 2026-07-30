import Foundation

struct Message: Codable {
    let id: String?
    let type: String
    let from: String
    let to: String
    let data: String?
    let qos: String?
    let status: String?
}

struct AckMessage: Codable {
    let type: String
    let id: String
    let from: String
    let to: String
    let status: String

    init(id: String, from: String, to: String, status: String) {
        self.type = "ack"
        self.id = id
        self.from = from
        self.to = to
        self.status = status
    }
}

class WebSocketClient: NSObject {
    weak var delegate: WebSocketClientDelegate?

    private var webSocketTask: URLSessionWebSocketTask?
    private var urlSession: URLSession!
    private(set) var isConnected = false
    private var shouldReconnect = true

    // Reconnection logic
    private var reconnectAttempts = 0
    private var reconnectWorkItem: DispatchWorkItem?

    override init() {
        super.init()
        urlSession = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
    }

    func connect(url: String, token: String) {
        guard let connectionURL = URL(string: url) else {
            print("✗ Invalid server URL")
            return
        }

        shouldReconnect = true
        reconnectWorkItem?.cancel()
        // Re-pairing can replace a valid token while the previous socket is
        // still alive. Tear it down before creating the replacement so one
        // app instance never receives the same route through two identities.
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
        isConnected = false

        // Add token as subprotocol (works better for WebSocket)
        var request = URLRequest(url: connectionURL)
        request.setValue("Bearer.\(token)", forHTTPHeaderField: "Sec-WebSocket-Protocol")

        let task = urlSession.webSocketTask(with: request)
        webSocketTask = task
        task.resume()

        receiveMessage(on: task)

        print("⟳ Connecting to \(url)...")
    }

    func disconnect() {
        shouldReconnect = false
        reconnectWorkItem?.cancel()
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
        isConnected = false
    }

    func sendMessage(_ message: Message) {
        guard isConnected else {
            print("✗ Not connected, cannot send message")
            return
        }

        do {
            let jsonData = try JSONEncoder().encode(message)
            let jsonString = String(data: jsonData, encoding: .utf8)!

            webSocketTask?.send(.string(jsonString)) { error in
                if let error = error {
                    print("✗ Failed to send message: \(error)")
                }
            }
        } catch {
            print("✗ Failed to encode message: \(error)")
        }
    }

    func sendAck(_ ack: AckMessage) {
        guard isConnected else { return }
        do {
            let jsonData = try JSONEncoder().encode(ack)
            let jsonString = String(data: jsonData, encoding: .utf8)!

            webSocketTask?.send(.string(jsonString)) { error in
                if let error = error {
                    print("✗ Failed to send ACK: \(error)")
                }
            }
        } catch {
            print("✗ Failed to encode ACK: \(error)")
        }
    }

    // Send generic dictionary message (for route messages)
    func sendMessage(_ message: [String: Any]) {
        guard isConnected else {
            print("✗ Not connected, cannot send message")
            return
        }

        do {
            let jsonData = try JSONSerialization.data(withJSONObject: message)
            guard let jsonString = String(data: jsonData, encoding: .utf8) else {
                print("✗ Failed to convert message to string")
                return
            }

            webSocketTask?.send(.string(jsonString)) { error in
                if let error = error {
                    print("✗ Failed to send message: \(error)")
                }
            }
        } catch {
            print("✗ Failed to serialize message: \(error)")
        }
    }

    private func receiveMessage(on task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            guard let self = self else { return }
            // Ignore callbacks from a socket superseded by reconnect/re-pair.
            guard self.webSocketTask === task else { return }

            switch result {
            case .success(let message):
                switch message {
                case .string(let text):
                    self.handleMessage(text)
                case .data(let data):
                    if let text = String(data: data, encoding: .utf8) {
                        self.handleMessage(text)
                    }
                @unknown default:
                    break
                }

                // Continue receiving
                self.receiveMessage(on: task)

            case .failure(let error):
                print("✗ WebSocket receive error: \(error)")
                self.handleDisconnection(error: error)
            }
        }
    }

    private func handleMessage(_ text: String) {
        do {
            let data = text.data(using: .utf8)!
            let message = try JSONDecoder().decode(Message.self, from: data)

            DispatchQueue.main.async {
                self.delegate?.webSocketDidReceiveMessage(message)
            }
        } catch {
            print("✗ Failed to decode message: \(error)")
        }
    }

    private func handleDisconnection(error: Error?) {
        isConnected = false

        DispatchQueue.main.async {
            self.delegate?.webSocketDidDisconnect(error: error)
        }

        guard shouldReconnect else { return }

        let delay = min(pow(2.0, Double(min(reconnectAttempts, 5))), 30.0)
        reconnectAttempts += 1
        print("⟳ Reconnecting in \(Int(delay))s (attempt \(reconnectAttempts))...")

        reconnectWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.attemptReconnection()
        }
        reconnectWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func attemptReconnection() {
        guard let token = KeychainHelper.getDeviceToken() else { return }

        // Get base server URL and convert to WebSocket URL
        var serverURL = UserDefaults.standard.string(forKey: "serverURL") ?? "http://localhost:8080"

        // Convert http(s):// to ws(s)://
        if serverURL.hasPrefix("http://") {
            serverURL = "ws://" + String(serverURL.dropFirst(7))
        } else if serverURL.hasPrefix("https://") {
            serverURL = "wss://" + String(serverURL.dropFirst(8))
        }

        // Ensure /ws path is added
        if !serverURL.hasSuffix("/ws") {
            serverURL = serverURL + "/ws"
        }

        connect(url: serverURL, token: token)
    }
}

// MARK: - URLSessionWebSocketDelegate

extension WebSocketClient: URLSessionWebSocketDelegate {
    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        guard self.webSocketTask === webSocketTask else { return }
        isConnected = true
        reconnectAttempts = 0

        DispatchQueue.main.async {
            self.delegate?.webSocketDidConnect()
        }
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        guard self.webSocketTask === webSocketTask else { return }
        var reasonString = "Unknown"
        if let reason = reason, let str = String(data: reason, encoding: .utf8) {
            reasonString = str
        }

        print("✗ WebSocket closed: \(closeCode.rawValue) - \(reasonString)")

        handleDisconnection(error: nil)
    }
}
