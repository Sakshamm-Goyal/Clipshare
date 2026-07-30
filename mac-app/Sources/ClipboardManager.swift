import Cocoa
import Crypto
import UserNotifications

enum LocalClipboardContent {
    case text(String)
    case image(data: Data, mimeType: String)

    var fingerprint: String {
        var source = Data()
        switch self {
        case .text(let value):
            source.append("text/plain\u{0}".data(using: .utf8)!)
            source.append(value.data(using: .utf8)!)
        case .image(let data, let mimeType):
            source.append(mimeType.data(using: .utf8)!)
            source.append(0)
            source.append(data)
        }
        return SHA256.hash(data: source).map { String(format: "%02x", $0) }.joined()
    }
}

class ClipboardManager {
    private var stagedItem: PlainItem?
    private var lastChangeCount = 0
    private var lastFingerprint: String?
    private var monitorTimer: Timer?
    private var onChangeCallback: ((LocalClipboardContent) -> Void)?

    private var lastAppliedFingerprint: String?
    private var lastAppliedTime: Date?
    private let echoPrevention: TimeInterval = 2.0

    func stageItem(_ item: PlainItem) {
        stagedItem = item
        print("✓ Staged clipboard item: \(item.preview)")
    }

    @discardableResult
    func applyStaged() -> PlainItem? {
        guard let item = stagedItem, write(item) else { return nil }
        lastAppliedFingerprint = content(from: item)?.fingerprint
        lastAppliedTime = Date()
        lastChangeCount = NSPasteboard.general.changeCount
        stagedItem = nil
        return item
    }

    func getStagedPreview() -> String? { stagedItem?.preview }
    func clearStaged() { stagedItem = nil }

    func startMonitoring(onChange: @escaping (LocalClipboardContent) -> Void) {
        onChangeCallback = onChange
        lastChangeCount = NSPasteboard.general.changeCount
        lastFingerprint = readContent()?.fingerprint
        monitorTimer?.invalidate()
        monitorTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            self?.checkClipboardChange()
        }
        print("✓ Started clipboard monitoring for outgoing sync")
    }

    func stopMonitoring() {
        monitorTimer?.invalidate()
        monitorTimer = nil
        onChangeCallback = nil
    }

    func markAsReceived(_ item: PlainItem) {
        lastAppliedFingerprint = content(from: item)?.fingerprint
        lastAppliedTime = Date()
    }

    private func checkClipboardChange() {
        let pasteboard = NSPasteboard.general
        guard pasteboard.changeCount != lastChangeCount else { return }
        lastChangeCount = pasteboard.changeCount
        guard let content = readContent(), content.fingerprint != lastFingerprint else { return }

        if content.fingerprint == lastAppliedFingerprint,
           let appliedTime = lastAppliedTime,
           Date().timeIntervalSince(appliedTime) < echoPrevention {
            lastFingerprint = content.fingerprint
            return
        }

        let capturedFingerprint = content.fingerprint
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self = self,
                  let stable = self.readContent(),
                  stable.fingerprint == capturedFingerprint else { return }
            self.lastFingerprint = stable.fingerprint
            self.onChangeCallback?(stable)
        }
    }

    private func readContent() -> LocalClipboardContent? {
        let pasteboard = NSPasteboard.general
        if let png = pasteboard.data(forType: .png) {
            return .image(data: png, mimeType: "image/png")
        }
        let jpegType = NSPasteboard.PasteboardType("public.jpeg")
        if let jpeg = pasteboard.data(forType: jpegType) {
            return .image(data: jpeg, mimeType: "image/jpeg")
        }
        if let tiff = pasteboard.data(forType: .tiff),
           let bitmap = NSBitmapImageRep(data: tiff),
           let png = bitmap.representation(using: .png, properties: [:]) {
            return .image(data: png, mimeType: "image/png")
        }
        return pasteboard.string(forType: .string).flatMap { $0.isEmpty ? nil : .text($0) }
    }

    private func content(from item: PlainItem) -> LocalClipboardContent? {
        if item.payload.type == "text/plain", let text = item.payload.text {
            return .text(text)
        }
        if item.payload.type.hasPrefix("image/"),
           let base64 = item.payload.data,
           let data = Data(base64Encoded: base64) {
            return .image(data: data, mimeType: item.payload.type)
        }
        return nil
    }

    private func write(_ item: PlainItem) -> Bool {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        if item.payload.type == "text/plain", let text = item.payload.text {
            return pasteboard.setString(text, forType: .string)
        }
        guard item.payload.type.hasPrefix("image/"),
              let encoded = item.payload.data,
              let data = Data(base64Encoded: encoded) else { return false }

        let type: NSPasteboard.PasteboardType = item.payload.type == "image/jpeg"
            ? NSPasteboard.PasteboardType("public.jpeg")
            : .png
        return pasteboard.setData(data, forType: type)
    }
}

class NotificationHelper {
    private static var lastNotificationTime: Date?
    private static let rateLimitInterval: TimeInterval = 1.0

    // UserNotifications requires an application bundle. `swift run` launches
    // the executable directly from .build, where the framework throws an
    // Objective-C exception instead of returning an authorization error.
    private static var canUseUserNotifications: Bool {
        Bundle.main.bundleURL.pathExtension == "app" && Bundle.main.bundleIdentifier != nil
    }

    static func show(title: String, body: String) {
        if let lastTime = lastNotificationTime,
           Date().timeIntervalSince(lastTime) < rateLimitInterval { return }
        lastNotificationTime = Date()

        guard canUseUserNotifications else {
            print("Notification: \(title) — \(body)")
            return
        }

        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)) { error in
            if let error = error { print("Notification error: \(error)") }
        }
    }
}
