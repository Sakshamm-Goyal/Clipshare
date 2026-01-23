import Cocoa
import Carbon

class HotkeyManager {
    weak var delegate: HotkeyManagerDelegate?

    private var eventHandler: EventHandlerRef?
    private var hotKeyRef: EventHotKeyRef?

    func registerPasteHotkey() {
        // Register ⌥⌘V (Option+Command+V)
        let keyCode: UInt32 = 9 // V key
        let modifiers: UInt32 = UInt32(optionKey | cmdKey)

        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))

        InstallEventHandler(GetApplicationEventTarget(), { (nextHandler, event, userData) -> OSStatus in
            guard let userData = userData else { return OSStatus(eventNotHandledErr) }

            let manager = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()
            manager.delegate?.hotkeyDidTriggerPaste()

            return noErr
        }, 1, &eventType, Unmanaged.passUnretained(self).toOpaque(), &eventHandler)

        var hotKeyID = EventHotKeyID(signature: OSType(0x4141), id: 1)
        RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetApplicationEventTarget(), 0, &hotKeyRef)

        print("✓ Registered hotkey: ⌥⌘V")
    }

    deinit {
        if let hotKeyRef = hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
        }
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
