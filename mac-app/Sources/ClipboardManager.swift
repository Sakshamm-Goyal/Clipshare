import Cocoa

class ClipboardManager {
    private var stagedItem: PlainItem?
    private var lastToastTime: Date?
    private let toastRateLimit: TimeInterval = 1.5

    // For outgoing clipboard monitoring
    private var lastChangeCount: Int = 0
    private var lastContent: String?
    private var monitorTimer: Timer?
    private var onChangeCallback: ((String) -> Void)?

    // Track content we just applied to avoid echo
    private var lastAppliedContent: String?
    private var lastAppliedTime: Date?
    private let echoPrevention: TimeInterval = 2.0

    func stageItem(_ item: PlainItem) {
        stagedItem = item
        print("✓ Staged clipboard item: \(item.preview)")
    }

    @discardableResult
    func applyStaged() -> PlainItem? {
        guard let item = stagedItem else {
            return nil
        }

        // Write to macOS clipboard
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(item.payload.text, forType: .string)

        // Track this content to prevent echo
        lastAppliedContent = item.payload.text
        lastAppliedTime = Date()
        lastChangeCount = pasteboard.changeCount

        print("✓ Applied staged item to clipboard")

        // Clear staged
        stagedItem = nil

        return item
    }

    func getStagedPreview() -> String? {
        return stagedItem?.preview
    }

    func clearStaged() {
        stagedItem = nil
    }

    // MARK: - Outgoing Clipboard Monitoring

    func startMonitoring(onChange: @escaping (String) -> Void) {
        self.onChangeCallback = onChange
        self.lastChangeCount = NSPasteboard.general.changeCount
        self.lastContent = NSPasteboard.general.string(forType: .string)

        // Start monitoring timer
        monitorTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.checkClipboardChange()
        }

        print("✓ Started clipboard monitoring for outgoing sync")
    }

    func stopMonitoring() {
        monitorTimer?.invalidate()
        monitorTimer = nil
        onChangeCallback = nil
        print("✓ Stopped clipboard monitoring")
    }

    private func checkClipboardChange() {
        let pasteboard = NSPasteboard.general
        let currentChangeCount = pasteboard.changeCount

        // Check if clipboard changed
        guard currentChangeCount != lastChangeCount else {
            return
        }

        lastChangeCount = currentChangeCount

        // Get current content
        guard let currentContent = pasteboard.string(forType: .string),
              !currentContent.isEmpty else {
            return
        }

        // Skip if content is same as last
        guard currentContent != lastContent else {
            return
        }

        // Check for echo (content we just applied from remote)
        if let appliedContent = lastAppliedContent,
           let appliedTime = lastAppliedTime,
           currentContent == appliedContent,
           Date().timeIntervalSince(appliedTime) < echoPrevention {
            print("↩ Ignoring echo from remote sync")
            return
        }

        lastContent = currentContent

        // Debounce: wait and verify content is stable
        let contentAtCapture = currentContent
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self = self else { return }

            // Verify content hasn't changed during debounce
            if let finalContent = NSPasteboard.general.string(forType: .string),
               finalContent == contentAtCapture {
                print("→ Sending clipboard to peer: \(finalContent.prefix(50))...")
                self.onChangeCallback?(finalContent)
            }
        }
    }

    // Mark content as just received (to prevent echo)
    func markAsReceived(_ content: String) {
        lastAppliedContent = content
        lastAppliedTime = Date()
    }
}

// MARK: - Notification Helper

class NotificationHelper {
    private static var lastNotificationTime: Date?
    private static let rateLimitInterval: TimeInterval = 1.0

    static func show(title: String, body: String) {
        // Rate limit notifications
        if let lastTime = lastNotificationTime,
           Date().timeIntervalSince(lastTime) < rateLimitInterval {
            return
        }
        lastNotificationTime = Date()

        // Use UserNotifications for macOS 10.14+
        if #available(macOS 10.14, *) {
            let center = UNUserNotificationCenter.current()
            center.requestAuthorization(options: [.alert, .sound]) { _, _ in }

            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default

            let request = UNNotificationRequest(
                identifier: UUID().uuidString,
                content: content,
                trigger: nil
            )

            center.add(request) { error in
                if let error = error {
                    print("Notification error: \(error)")
                }
            }
        } else {
            // Fallback for older macOS
            let notification = NSUserNotification()
            notification.title = title
            notification.informativeText = body
            notification.soundName = NSUserNotificationDefaultSoundName
            NSUserNotificationCenter.default.deliver(notification)
        }
    }
}

// Import for UNUserNotificationCenter
import UserNotifications
