import Cocoa
setvbuf(stdout, nil, _IOLBF, 0) // line-buffer so launchd log file shows output live

let app = NSApplication.shared
app.setActivationPolicy(.accessory)  // Menu bar app only, no dock icon
let delegate = AppDelegate()
app.delegate = delegate
app.run()
