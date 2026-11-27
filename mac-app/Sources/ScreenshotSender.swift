import Cocoa
import ScreenCaptureKit

/// Silent screenshot of the display under the mouse, sized to fit the 5 MiB relay limit.
/// Captured in-process with ScreenCaptureKit so macOS checks ClipboardMac's own Screen
/// Recording grant (a spawned /usr/sbin/screencapture isn't covered by it on macOS 15+).
enum ScreenshotSender {
    static let maxBytes = 5 * 1024 * 1024
    private static var askedThisLaunch = false

    static func capture(completion: @escaping (Data, String) -> Void) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        let displayID = screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
        let scale = screen?.backingScaleFactor ?? 2

        Task.detached(priority: .userInitiated) {
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                guard let display = content.displays.first(where: { $0.displayID == displayID }) ?? content.displays.first else {
                    print("✗ Screenshot: no display found")
                    return
                }
                let config = SCStreamConfiguration()
                config.width = Int(CGFloat(display.width) * scale)
                config.height = Int(CGFloat(display.height) * scale)
                config.showsCursor = false
                let image = try await SCScreenshotManager.captureImage(
                    contentFilter: SCContentFilter(display: display, excludingWindows: []),
                    configuration: config)

                guard let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]),
                      let (data, mime) = fit(png) else {
                    print("✗ Screenshot encode failed")
                    return
                }
                await MainActor.run {
                    completion(data, mime)
                    print("→ Screenshot \(data.count / 1024) KB (\(mime)) queued for Android")
                }
            } catch {
                print("✗ Screenshot failed: \(error.localizedDescription) — allow ClipboardMac in Screen Recording")
                await MainActor.run {
                    // Ask once per launch, not on every press.
                    if !askedThisLaunch { askedThisLaunch = true; _ = CGRequestScreenCaptureAccess() }
                }
            }
        }
    }

    /// PNG if it fits, else JPEG at decreasing quality / scale.
    static func fit(_ png: Data) -> (Data, String)? {
        if png.count <= maxBytes { return (png, "image/png") }
        guard var rep = NSBitmapImageRep(data: png) else { return nil }
        for quality in [0.85, 0.7, 0.5] {
            if let jpg = rep.representation(using: .jpeg, properties: [.compressionFactor: quality]), jpg.count <= maxBytes {
                return (jpg, "image/jpeg")
            }
        }
        // ponytail: one halving covers 6K/8K displays; loop if bigger screens appear.
        guard let half = scaled(rep, by: 0.5) else { return nil }
        rep = half
        return rep.representation(using: .jpeg, properties: [.compressionFactor: 0.7]).map { ($0, "image/jpeg") }
    }

    private static func scaled(_ rep: NSBitmapImageRep, by factor: CGFloat) -> NSBitmapImageRep? {
        guard let cg = rep.cgImage else { return nil }
        let w = Int(CGFloat(cg.width) * factor), h = Int(CGFloat(cg.height) * factor)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage().map { NSBitmapImageRep(cgImage: $0) }
    }
}
