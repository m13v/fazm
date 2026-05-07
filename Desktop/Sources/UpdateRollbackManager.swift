import Foundation
import AppKit

/// Manages automatic rollback when a Sparkle update causes a crash loop.
///
/// Three phases:
/// 1. **Backup** — before Sparkle replaces the app, copy the current bundle to Application Support
/// 2. **Detect** — on every launch, track rapid restarts; 3 crashes within 60s = crash loop
/// 3. **Restore** — copy the backup over the broken app, block the bad version, relaunch
///
/// All detection/restore code uses only Foundation + logSync() — no Firebase, Sentry, or PostHog
/// (those frameworks might be what's crashing).
enum UpdateRollbackManager {

    // MARK: - UserDefaults Keys

    private static let kLaunchCount = "rollback_launchCount"
    private static let kLaunchTimestamp = "rollback_launchTimestamp"
    private static let kBlockedVersion = "rollback_blockedVersion"
    private static let kDidRollback = "rollback_didRollback"
    private static let kRolledBackFromVersion = "rollback_rolledBackFromVersion"
    private static let kRestoredVersion = "rollback_restoredVersion"

    /// Max rapid crashes before triggering rollback
    private static let crashThreshold = 3
    /// Max seconds between launches to count as a crash loop (not a manual relaunch)
    private static let rapidCrashWindow: TimeInterval = 60

    // MARK: - Paths

    /// Directory for the backup app bundle and metadata
    private static var backupDirectory: URL {
        AppPaths.supportRoot
            .appendingPathComponent("UpdateBackup", isDirectory: true)
    }

    /// Path to the backup-info.plist metadata file
    private static var backupInfoPath: URL {
        backupDirectory.appendingPathComponent("backup-info.plist")
    }

    /// The app name (e.g., "Fazm.app" or "Fazm Dev.app")
    private static var appBundleName: String {
        (Bundle.main.bundlePath as NSString).lastPathComponent
    }

    /// Path to the backed-up app bundle
    private static var backupAppPath: URL {
        backupDirectory.appendingPathComponent(appBundleName)
    }

    // MARK: - Phase 1: Backup Before Update

    /// Back up the current app bundle before Sparkle replaces it.
    /// Call from `willInstallUpdate(_:item:)` — must be synchronous.
    static func backupCurrentApp() {
        let source = Bundle.main.bundlePath
        let dest = backupAppPath
        let fm = FileManager.default

        logSync("Rollback: Backing up \(source) → \(dest.path)")

        // Ensure backup directory exists
        do {
            try fm.createDirectory(at: backupDirectory, withIntermediateDirectories: true)
        } catch {
            logSync("Rollback: Failed to create backup directory: \(error)")
            return
        }

        // Remove existing backup
        if fm.fileExists(atPath: dest.path) {
            do {
                try fm.removeItem(at: dest)
            } catch {
                logSync("Rollback: Failed to remove old backup: \(error)")
                return
            }
        }

        // Copy using ditto (preserves code signature, xattrs, resource forks)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = [source, dest.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            logSync("Rollback: ditto failed to launch: \(error)")
            return
        }

        guard process.terminationStatus == 0 else {
            logSync("Rollback: ditto exited with status \(process.terminationStatus)")
            return
        }

        // Write backup metadata
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
        let info: [String: Any] = [
            "version": version,
            "build": build,
            "appName": appBundleName,
            "date": ISO8601DateFormatter().string(from: Date()),
        ]
        let data = try? PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        fm.createFile(atPath: backupInfoPath.path, contents: data)

        logSync("Rollback: Backup complete (v\(version)+\(build))")
    }

    // MARK: - Phase 2: Crash-Loop Detection

    /// Check for crash-loop at the very top of launch. If detected, restore and relaunch.
    /// This method may terminate the process (via rollback + relaunch). If it returns, launch is safe.
    static func checkForCrashLoop() {
        let defaults = UserDefaults.standard
        let now = Date().timeIntervalSince1970

        let previousTimestamp = defaults.double(forKey: kLaunchTimestamp)
        let launchCount = defaults.integer(forKey: kLaunchCount) + 1

        // Always update timestamp and count
        defaults.set(now, forKey: kLaunchTimestamp)
        defaults.set(launchCount, forKey: kLaunchCount)

        // If this is the first or second launch, no crash loop yet
        guard launchCount >= crashThreshold else { return }

        // Check if launches are happening rapidly (within the crash window)
        let interval = previousTimestamp > 0 ? (now - previousTimestamp) : Double.greatestFiniteMagnitude
        if interval > rapidCrashWindow {
            // Not rapid — user relaunched manually after a while. Reset counter.
            defaults.set(1, forKey: kLaunchCount)
            return
        }

        // Crash loop detected — attempt rollback
        logSync("Rollback: Crash loop detected (\(launchCount) launches within \(Int(interval))s)")
        performRollback()
    }

    /// Mark a successful launch — reset the crash counter.
    /// Call at the end of `applicationDidFinishLaunching` after all init succeeds.
    static func markSuccessfulLaunch() {
        UserDefaults.standard.set(0, forKey: kLaunchCount)
    }

    // MARK: - Phase 3: Restore

    /// Restore the backup app bundle and relaunch. Terminates the process on success.
    private static func performRollback() {
        let fm = FileManager.default
        let backupApp = backupAppPath

        guard fm.fileExists(atPath: backupApp.path) else {
            logSync("Rollback: No backup found at \(backupApp.path) — cannot rollback, resetting counter")
            UserDefaults.standard.set(0, forKey: kLaunchCount)
            return
        }

        // Read backup metadata
        var restoredVersion = "unknown"
        if let data = fm.contents(atPath: backupInfoPath.path),
           let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] {
            restoredVersion = info["version"] as? String ?? "unknown"
        }

        let badVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
        let installPath = Bundle.main.bundlePath

        logSync("Rollback: Restoring v\(restoredVersion) over broken v\(badVersion) at \(installPath)")

        // Store rollback state for post-relaunch notification
        let defaults = UserDefaults.standard
        defaults.set(badVersion, forKey: kBlockedVersion)
        defaults.set(true, forKey: kDidRollback)
        defaults.set(badVersion, forKey: kRolledBackFromVersion)
        defaults.set(restoredVersion, forKey: kRestoredVersion)
        defaults.set(0, forKey: kLaunchCount)

        // Copy backup to a temp location first, then atomically replace.
        // This prevents the app from vanishing if the copy fails.
        let tempRestore = installPath + ".rollback-tmp"

        // Clean up any leftover temp from a previous failed attempt
        if fm.fileExists(atPath: tempRestore) {
            try? fm.removeItem(atPath: tempRestore)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = [backupApp.path, tempRestore]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            logSync("Rollback: ditto restore to temp failed: \(error) — aborting (app untouched)")
            defaults.set(0, forKey: kLaunchCount)
            return
        }

        guard process.terminationStatus == 0 else {
            logSync("Rollback: ditto restore exited with status \(process.terminationStatus) — aborting (app untouched)")
            try? fm.removeItem(atPath: tempRestore)
            defaults.set(0, forKey: kLaunchCount)
            return
        }

        // Temp copy succeeded — now swap: remove broken app, move temp into place
        do {
            try fm.removeItem(atPath: installPath)
        } catch {
            logSync("Rollback: Failed to remove broken app: \(error) — aborting rollback")
            try? fm.removeItem(atPath: tempRestore)
            defaults.set(0, forKey: kLaunchCount)
            return
        }

        do {
            try fm.moveItem(atPath: tempRestore, toPath: installPath)
        } catch {
            logSync("Rollback: CRITICAL — broken app removed but move failed: \(error). Attempting direct ditto recovery.")
            // Last resort: try ditto directly since the temp copy exists
            let recovery = Process()
            recovery.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            recovery.arguments = [tempRestore, installPath]
            recovery.standardOutput = FileHandle.nullDevice
            recovery.standardError = FileHandle.nullDevice
            try? recovery.run()
            recovery.waitUntilExit()
            try? fm.removeItem(atPath: tempRestore)
            guard fm.fileExists(atPath: installPath) else {
                logSync("Rollback: CRITICAL — app lost, recovery failed")
                return
            }
        }

        logSync("Rollback: Restore complete — relaunching")

        // Relaunch the restored app
        let appURL = URL(fileURLWithPath: installPath)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            let config = NSWorkspace.OpenConfiguration()
            config.createsNewApplicationInstance = true
            NSWorkspace.shared.openApplication(at: appURL, configuration: config) { _, error in
                if let error {
                    logSync("Rollback: Relaunch failed: \(error)")
                }
            }
            // Give the new process time to start, then exit
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                NSApp.terminate(nil)
            }
        }
    }

    // MARK: - Version Blocking

    /// Returns the version string that should be blocked, or nil if none.
    static var blockedVersion: String? {
        UserDefaults.standard.string(forKey: kBlockedVersion)
    }

    /// Clear the blocked version (called when a newer version is available).
    static func clearBlockedVersion() {
        UserDefaults.standard.removeObject(forKey: kBlockedVersion)
    }

    // MARK: - Post-Rollback Notification

    /// Check if a rollback just happened and show an alert + track analytics.
    /// Call at the end of `applicationDidFinishLaunching` (PostHog/Sentry are initialized by then).
    @MainActor static func handlePostRollbackIfNeeded() {
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: kDidRollback) else { return }

        let badVersion = defaults.string(forKey: kRolledBackFromVersion) ?? "unknown"
        let restoredVersion = defaults.string(forKey: kRestoredVersion) ?? "unknown"

        // Clear one-time flags
        defaults.removeObject(forKey: kDidRollback)
        defaults.removeObject(forKey: kRolledBackFromVersion)
        defaults.removeObject(forKey: kRestoredVersion)

        logSync("Rollback: Post-rollback handler — rolled back from v\(badVersion) to v\(restoredVersion)")

        // Track analytics (PostHog is initialized by now)
        PostHogManager.shared.track("update_rollback_triggered", properties: [
            "bad_version": badVersion,
            "restored_version": restoredVersion,
            "crash_count": crashThreshold,
        ])

        // Show alert on main thread after a brief delay (let the window appear first)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            let alert = NSAlert()
            alert.alertStyle = .informational
            alert.messageText = "Update Rolled Back"
            alert.informativeText = "Version \(badVersion) crashed on launch, so Fazm automatically restored the previous version. The problematic update has been blocked.\n\nYou'll receive the next update when a fix is available."
            alert.addButton(withTitle: "OK")

            if let window = NSApp.keyWindow ?? NSApp.mainWindow {
                alert.beginSheetModal(for: window) { _ in }
            } else {
                alert.runModal()
            }
        }
    }
}
