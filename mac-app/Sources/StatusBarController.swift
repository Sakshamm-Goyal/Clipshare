import Cocoa

enum ConnectionStatus {
    case connected
    case connecting
    case disconnected
}

class StatusBarController {
    weak var delegate: StatusBarControllerDelegate?

    private var statusItem: NSStatusItem!
    private var menu: NSMenu!

    init() {
        NSLog("→ Creating status bar item...")

        // Create status item with fixed square length
        statusItem = NSStatusBar.system.statusItem(withLength: 28)

        NSLog("→ Status item created: %@", statusItem != nil ? "true" : "false")
        NSLog("→ Status bar thickness: %f", NSStatusBar.system.thickness)

        guard let button = statusItem.button else {
            NSLog("✗ Failed to create status bar button")
            return
        }

        NSLog("→ Button created successfully")

        // Use a simple, high-contrast approach
        button.title = "📋"
        button.font = NSFont.systemFont(ofSize: 14)
        NSLog("✓ Status bar title set to clipboard emoji")

        setupMenu()
        NSLog("✓ Status bar menu configured")
        NSLog("→ Status item isVisible: %@", statusItem.isVisible ? "true" : "false")
        NSLog("→ Button frame: %@", NSStringFromRect(button.frame))
        NSLog("→ Button bounds: %@", NSStringFromRect(button.bounds))
    }

    func setupMenu() {
        menu = NSMenu()

        let statusMenuItem = NSMenuItem(title: "Disconnected", action: nil, keyEquivalent: "")
        statusMenuItem.tag = 999 // Tag for status item
        menu.addItem(statusMenuItem)

        menu.addItem(NSMenuItem.separator())

        let pairMenuItem = NSMenuItem(title: "Pair New Device...", action: #selector(pairDevice), keyEquivalent: "p")
        pairMenuItem.target = self
        menu.addItem(pairMenuItem)

        let settingsMenuItem = NSMenuItem(title: "Settings...", action: #selector(openSettings), keyEquivalent: ",")
        settingsMenuItem.target = self
        menu.addItem(settingsMenuItem)

        menu.addItem(NSMenuItem.separator())

        let quitMenuItem = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q")
        quitMenuItem.target = self
        menu.addItem(quitMenuItem)

        statusItem.menu = menu
    }

    func setStatus(_ status: ConnectionStatus) {
        guard let statusMenuItem = menu.item(withTag: 999) else { return }

        // Update on main thread for UI changes
        DispatchQueue.main.async { [weak self] in
            guard let self = self, let button = self.statusItem.button else { return }

            switch status {
            case .connected:
                statusMenuItem.title = "✓ Connected"
                // Keep emoji title for reliability, add green tint via attributed string
                button.title = "📋"
                button.contentTintColor = .systemGreen

            case .connecting:
                statusMenuItem.title = "⟳ Connecting..."
                button.title = "📋"
                button.contentTintColor = .systemOrange

            case .disconnected:
                statusMenuItem.title = "✗ Disconnected"
                button.title = "📋"
                button.contentTintColor = .systemRed
            }
        }
    }

    @objc func pairDevice() {
        delegate?.statusBarDidRequestPairing()
    }

    @objc func openSettings() {
        delegate?.statusBarDidRequestSettings()
    }

    @objc func quit() {
        delegate?.statusBarDidRequestQuit()
    }
}
