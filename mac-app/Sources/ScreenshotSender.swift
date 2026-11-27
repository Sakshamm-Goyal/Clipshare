import Cocoa

/// Silent screenshot of the display under the mouse, sized to fit the 5 MiB relay limit.
enum ScreenshotSender {
    static let maxBytes = 5 * 1024 * 1024

    static func requestPermissionIfNeeded() {
        if !CGPreflightScreenCaptureAccess() { CGRequestScreenCaptureAccess() }
    }

    static func capture(completion: @escaping (Data, String) -> Void) {
        guard CGPreflightScreenCaptureAccess() else {
            // Without Screen Recording access macOS returns only the wallpaper.
            print("✗ Screenshot needs Screen Recording permission")
            CGRequestScreenCaptureAccess()
            return
        }
        let display = displayUnderMouse()
        DispatchQueue.global(qos: .userInitiated).async {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("clipshare-\(UUID().uuidString).png")
            defer { try? FileManager.default.removeItem(at: url) }

            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            task.arguments = ["-x", "-D", String(display), "-t", "png", url.path]  // -x: no shutter sound
            do { try task.run() } catch { print("✗ screencapture failed: \(error)"); return }
            task.waitUntilExit()

            guard let png = try? Data(contentsOf: url), let (data, mime) = fit(png) else {
                print("✗ Screenshot capture failed")
                return
            }
            DispatchQueue.main.async {
                completion(data, mime)
                print("→ Screenshot \(data.count / 1024) KB (\(mime)) queued for Android")
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

    /// screencapture -D is 1-based in NSScreen.screens order (1 = main).
    private static func displayUnderMouse() -> Int {
        let mouse = NSEvent.mouseLocation
        let index = NSScreen.screens.firstIndex { NSMouseInRect(mouse, $0.frame, false) } ?? 0
        return index + 1
    }
}
