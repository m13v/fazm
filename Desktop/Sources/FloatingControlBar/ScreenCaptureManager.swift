import AppKit
import ImageIO

class ScreenCaptureManager {
    /// Capture the frontmost window of a specific application by PID.
    /// Falls back to full-screen capture if the window cannot be found.
    static func captureAppWindow(pid: pid_t) -> URL? {
        // Find the frontmost on-screen window belonging to this PID
        guard let windowList = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
        ) as? [[CFString: Any]] else {
            log("ScreenCaptureManager: Could not get window list, falling back to full screen")
            return captureScreen()
        }

        // Find the first regular window for this PID (skip menu bar, status items, etc.)
        let targetWindow = windowList.first { info in
            guard let ownerPID = info[kCGWindowOwnerPID] as? pid_t,
                  ownerPID == pid,
                  let layer = info[kCGWindowLayer] as? Int,
                  layer == 0  // Normal window layer
            else { return false }
            return true
        }

        guard let windowInfo = targetWindow,
              let windowID = windowInfo[kCGWindowNumber] as? CGWindowID else {
            log("ScreenCaptureManager: No window found for PID \(pid), falling back to full screen")
            return captureScreen()
        }

        let ownerName = windowInfo[kCGWindowOwnerName as CFString] as? String ?? "unknown"

        // Capture just this window (including its shadow for context)
        guard let image = CGWindowListCreateImage(
            .null,  // Use the window's own bounds
            .optionIncludingWindow,
            windowID,
            [.boundsIgnoreFraming, .bestResolution]
        ) else {
            log("ScreenCaptureManager: Could not capture window for PID \(pid), falling back to full screen")
            return captureScreen()
        }

        log("ScreenCaptureManager: Captured window of '\(ownerName)' (PID \(pid), \(image.width)×\(image.height))")
        return saveImage(image)
    }

    /// Capture the entire main display.
    static func captureScreen() -> URL? {
        guard let image = CGDisplayCreateImage(CGMainDisplayID()) else {
            log("ScreenCaptureManager: Could not capture screen")
            return nil
        }

        log("ScreenCaptureManager: Captured full screen (\(image.width)×\(image.height))")
        return saveImage(image)
    }

    /// Save a CGImage as JPEG and return the file URL.
    private static func saveImage(_ image: CGImage) -> URL? {
        let fileManager = FileManager.default
        guard let documentsDirectory = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first else {
            log("ScreenCaptureManager: Could not find documents directory")
            return nil
        }
        let screenshotsDirectory = documentsDirectory
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

        guard let destination = CGImageDestinationCreateWithURL(fileURL as CFURL, "public.jpeg" as CFString, 1, nil) else {
            log("ScreenCaptureManager: Could not create image destination")
            return nil
        }

        // JPEG at 0.75 quality keeps file size ~400–800 KB vs 5+ MB for PNG,
        // staying well under the Claude API's 5 MB base64 limit.
        let options: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.75]
        CGImageDestinationAddImage(destination, image, options as CFDictionary)

        if !CGImageDestinationFinalize(destination) {
            log("ScreenCaptureManager: Could not save image")
            return nil
        }

        log("ScreenCaptureManager: Screenshot saved to \(fileURL.path)")
        return fileURL
    }
}
