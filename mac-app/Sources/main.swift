import Cocoa

let app = NSApplication.shared
app.setActivationPolicy(.accessory)  // Menu bar app only, no dock icon
let delegate = AppDelegate()
app.delegate = delegate
app.run()
