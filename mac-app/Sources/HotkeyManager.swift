import Cocoa
import Carbon

class HotkeyManager {
    weak var delegate: HotkeyManagerDelegate?

    private var eventHandler: EventHandlerRef?
    private var hotKeyRefs: [EventHotKeyRef] = []

    private static let pasteID: UInt32 = 1
    private static let screenshotID: UInt32 = 2

    /// Registers ⌥⌘V (paste staged item) and ⌘⇧I (silent screenshot → Android).
    func registerHotkeys() {
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))

        InstallEventHandler(GetApplicationEventTarget(), { (_, event, userData) -> OSStatus in
            guard let event = event, let userData = userData else { return OSStatus(eventNotHandledErr) }
            var hotKeyID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            let manager = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()
            switch hotKeyID.id {
            case HotkeyManager.pasteID: manager.delegate?.hotkeyDidTriggerPaste()
            case HotkeyManager.screenshotID: manager.delegate?.hotkeyDidTriggerScreenshot()
            default: return OSStatus(eventNotHandledErr)
            }
            return noErr
        }, 1, &eventType, Unmanaged.passUnretained(self).toOpaque(), &eventHandler)

        register(keyCode: 9, modifiers: UInt32(optionKey | cmdKey), id: Self.pasteID)          // V
        register(keyCode: 34, modifiers: UInt32(shiftKey | cmdKey), id: Self.screenshotID)     // I
        print("✓ Registered hotkeys: ⌥⌘V (paste), ⌘⇧I (screenshot → Android)")
    }

    private func register(keyCode: UInt32, modifiers: UInt32, id: UInt32) {
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(keyCode, modifiers, EventHotKeyID(signature: OSType(0x4141), id: id),
                                         GetApplicationEventTarget(), 0, &ref)
        if status == noErr, let ref = ref { hotKeyRefs.append(ref) } else { print("✗ Hotkey \(id) taken (\(status))") }
    }

    deinit {
        hotKeyRefs.forEach { UnregisterEventHotKey($0) }
        if let eventHandler = eventHandler {
            RemoveEventHandler(eventHandler)
        }
    }
}

// MARK: - Accessibility Helper

class AccessibilityHelper {
    static func hasPermission() -> Bool {
        return AXIsProcessTrusted()
    }

    static func requestPermission() {
        let options: NSDictionary = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        AXIsProcessTrustedWithOptions(options)
    }

    static func simulateCmdV() {
        // Create and post Cmd+V key event
        let source = CGEventSource(stateID: .combinedSessionState)

        // Key down
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true) // V key
        keyDown?.flags = .maskCommand
        keyDown?.post(tap: .cghidEventTap)

        // Key up
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false)
        keyUp?.flags = .maskCommand
        keyUp?.post(tap: .cghidEventTap)
    }
}
