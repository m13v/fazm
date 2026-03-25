import AppKit
import ImageIO

class ScreenCaptureManager {

    enum CaptureResult {
        case success(URL)
        /// Window found but CGWindowListCreateImage returned nil — almost certainly a Screen Recording permission issue.
        case permissionDenied
    }

    /// Capture the frontmost window of a specific application by PID.
    /// Returns `.permissionDenied` when the window is found but pixel capture fails (Screen Recording permission revoked).
    static func captureAppWindow(pid: pid_t) -> CaptureResult {
        // Try on-screen windows first, then all windows (catches fullscreen apps in other Spaces)
        let windowInfo = findWindow(for: pid, onScreenOnly: true)
            ?? findWindow(for: pid, onScreenOnly: false)

        guard let windowInfo, let windowID = windowInfo[kCGWindowNumber] as? CGWindowID else {
            log("ScreenCaptureManager: No window found for PID \(pid), falling back to full screen")
            if let url = captureScreen() { return .success(url) }
            return .permissionDenied
        }

        let ownerName = windowInfo[kCGWindowOwnerName as CFString] as? String ?? "unknown"

        // Capture just this window (including its shadow for context)
        guard let image = Self.captureWindow(windowID) else {
            // Window metadata is readable but pixel capture failed — Screen Recording permission is missing/stale
            log("ScreenCaptureManager: Could not capture window '\(ownerName)' for PID \(pid) — likely missing Screen Recording permission")
            return .permissionDenied
        }

        log("ScreenCaptureManager: Captured window of '\(ownerName)' (PID \(pid), \(image.width)×\(image.height))")
        if let url = saveImage(image) { return .success(url) }
        return .permissionDenied
    }

    /// Find the best window for a PID. Accepts any window layer (including fullscreen).
    /// Prefers larger windows when multiple exist (the main content window, not a toolbar float).
    private static func findWindow(for pid: pid_t, onScreenOnly: Bool) -> [CFString: Any]? {
        let options: CGWindowListOption = onScreenOnly
            ? [.optionOnScreenOnly, .excludeDesktopElements]
            : [.optionAll, .excludeDesktopElements]

        guard let windowList = CGWindowListCopyWindowInfo(options, kCGNullWindowID)
                as? [[CFString: Any]] else { return nil }

        // Collect all windows for this PID, any layer
        let candidates = windowList.filter { info in
            guard let ownerPID = info[kCGWindowOwnerPID] as? pid_t,
                  ownerPID == pid else { return false }
            // Skip tiny windows (status bar items, tooltips)
            if let bounds = info[kCGWindowBounds] as? [String: CGFloat],
               let w = bounds["Width"], let h = bounds["Height"],
               w >= 100, h >= 100 {
                return true
            }
            // Also accept windows without bounds info
            return info[kCGWindowBounds] == nil
        }

        guard !candidates.isEmpty else { return nil }

        // Pick the largest window (by area) — the main/fullscreen window
        let best = candidates.max { a, b in
            let areaA = windowArea(a)
            let areaB = windowArea(b)
            return areaA < areaB
        }

        let label = onScreenOnly ? "on-screen" : "all-windows"
        if let best, let layer = best[kCGWindowLayer] as? Int {
            log("ScreenCaptureManager: Found window for PID \(pid) via \(label) search (layer=\(layer))")
        }
        return best
    }

    private static func windowArea(_ info: [CFString: Any]) -> CGFloat {
        guard let bounds = info[kCGWindowBounds] as? [String: CGFloat],
              let w = bounds["Width"], let h = bounds["Height"] else { return 0 }
        return w * h
    }

    /// Capture the entire main display.
    // Isolated to suppress the deprecation warning — ScreenCaptureKit migration is non-trivial
    // and this synchronous API still works reliably for our use case.
    @available(macOS, deprecated: 14.0, message: "Migrate to ScreenCaptureKit when feasible")
    private static func captureWindow(_ windowID: CGWindowID) -> CGImage? {
        CGWindowListCreateImage(
            .null,
            .optionIncludingWindow,
            windowID,
            [.boundsIgnoreFraming, .bestResolution]
        )
    }

    static func captureScreen() -> URL? {
        guard let image = CGDisplayCreateImage(CGMainDisplayID()) else {
            log("ScreenCaptureManager: Could not capture screen")
            return nil
        }

        log("ScreenCaptureManager: Captured full screen (\(image.width)×\(image.height))")
        return saveImage(image)
    }

    /// Maximum raw JPEG size in bytes (~3.5 MB keeps base64 under the 5 MB API limit).
    private static let maxJPEGBytes = 3_500_000

    /// Downscale a CGImage so its longest edge is at most `maxEdge` pixels.
    private static func downscale(_ image: CGImage, maxEdge: Int) -> CGImage {
        let w = image.width
        let h = image.height
        guard max(w, h) > maxEdge else { return image }
        let scale = CGFloat(maxEdge) / CGFloat(max(w, h))
        let newW = Int(CGFloat(w) * scale)
        let newH = Int(CGFloat(h) * scale)
        guard let ctx = CGContext(
            data: nil, width: newW, height: newH,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return image }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: newW, height: newH))
        return ctx.makeImage() ?? image
    }

    /// Save a CGImage as JPEG and return the file URL.
    /// Downscales large images and adjusts quality to stay under the API size limit.
    private static func saveImage(_ image: CGImage) -> URL? {
        let fileManager = FileManager.default
        guard let appSupportDirectory = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            log("ScreenCaptureManager: Could not find Application Support directory")
            return nil
        }
        let screenshotsDirectory = appSupportDirectory
            .appendingPathComponent("Fazm")
            .appendingPathComponent("Screenshots")

        do {
            try fileManager.createDirectory(at: screenshotsDirectory, withIntermediateDirectories: true, attributes: nil)
        } catch {
            log("ScreenCaptureManager: Error creating directory: \(error)")
            return nil
        }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let timestamp = formatter.string(from: Date())
        let fileName = "screenshot-\(timestamp).jpg"
        let fileURL = screenshotsDirectory.appendingPathComponent(fileName)

        // Downscale Retina captures to max 1568px on the longest edge.
        // Claude API enforces a 2000px limit per image in multi-image conversations;
        // staying at 1568 leaves headroom for the API's stricter "many-image" path.
        let scaled = downscale(image, maxEdge: 1568)

        // Try JPEG at decreasing quality until under size limit
        for quality in stride(from: 0.7, through: 0.3, by: -0.1) {
            guard let destination = CGImageDestinationCreateWithURL(fileURL as CFURL, "public.jpeg" as CFString, 1, nil) else {
                log("ScreenCaptureManager: Could not create image destination")
                return nil
            }
            let options: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: quality]
            CGImageDestinationAddImage(destination, scaled, options as CFDictionary)
            guard CGImageDestinationFinalize(destination) else {
                log("ScreenCaptureManager: Could not save image")
                return nil
            }
            if let attrs = try? fileManager.attributesOfItem(atPath: fileURL.path),
               let size = attrs[.size] as? Int,
               size <= maxJPEGBytes {
                log("ScreenCaptureManager: Screenshot saved to \(fileURL.path) (\(size / 1024)KB, quality=\(String(format: "%.1f", quality)))")
                return fileURL
            }
        }

        // Even at lowest quality it's too big — save anyway (bridge will handle gracefully)
        log("ScreenCaptureManager: Screenshot saved to \(fileURL.path) (may exceed size limit)")
        return fileURL
    }

    /// Delete screenshots older than the specified number of days.
    static func cleanupOldScreenshots(olderThan days: Int = 30) {
        let fileManager = FileManager.default
        guard let appSupportDirectory = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return }
        let screenshotsDirectory = appSupportDirectory
            .appendingPathComponent("Fazm")
            .appendingPathComponent("Screenshots")

        guard let files = try? fileManager.contentsOfDirectory(at: screenshotsDirectory, includingPropertiesForKeys: [.creationDateKey]) else { return }

        let cutoff = Date().addingTimeInterval(-Double(days) * 86400)
        var deleted = 0
        for file in files {
            guard let attrs = try? file.resourceValues(forKeys: [.creationDateKey]),
                  let created = attrs.creationDate,
                  created < cutoff else { continue }
            try? fileManager.removeItem(at: file)
            deleted += 1
        }
        if deleted > 0 {
            log("ScreenCaptureManager: Cleaned up \(deleted) screenshots older than \(days) days")
        }
    }
}
