import Foundation
import AppKit
import UserNotifications

/// Watches the user's Claude plan 5-hour rolling-window utilization (via the
/// locally-installed `claude-meter` CLI) and plays an alarm sound when usage
/// crosses 95% in the current window.
///
/// Toggle via the `claudeUsageAlarmEnabled` UserDefault (default: true).
/// Exposed in the floating-bar header dropdown so the user can mute the alarm.
///
/// Implementation notes:
/// - Polls every 60 seconds; `claude-meter --json` is cheap (it reads cached
///   data the menu-bar app already fetched).
/// - Fires at most once per 5-hour window. The window is identified by the
///   `resets_at` timestamp; when it changes, the "already-fired" flag clears
///   and the alarm becomes armed again.
/// - If multiple Claude orgs are returned, we use the maximum 5-hour
///   utilization across them (most aggressive trigger).
/// - The alarm plays the system "Sosumi" sound three times with 0.55s spacing
///   to feel like a notification alarm rather than a single ding.
@MainActor
final class ClaudeUsageAlarmMonitor {
    static let shared = ClaudeUsageAlarmMonitor()

    /// UserDefaults key — also referenced by the SwiftUI toggle in
    /// `AIResponseView.swift`. Default seeded to `true` in `FazmApp.swift`.
    static let enabledKey = "claudeUsageAlarmEnabled"

    /// Threshold (percent) that triggers the alarm.
    private let threshold: Double = 95.0

    /// Path to the bundled CLI shipped with the menu-bar app.
    private let claudeMeterCLI = "/Applications/ClaudeMeter.app/Contents/MacOS/claude-meter"

    /// Polling interval. 60s matches the menu-bar app's own refresh cadence.
    private let pollInterval: TimeInterval = 60

    private var timer: Timer?

    /// `resets_at` of the window we already fired for. When the next poll sees
    /// a different (newer) `resets_at`, we re-arm.
    private var lastFiredWindowResetsAt: String?

    private init() {}

    func start() {
        guard timer == nil else { return }

        // Skip entirely if the CLI isn't installed; nothing to monitor.
        guard FileManager.default.isExecutableFile(atPath: claudeMeterCLI) else {
            logLine("starting skipped — claude-meter CLI not found at \(claudeMeterCLI)")
            return
        }

        logLine("starting, threshold=\(threshold)%, poll=\(pollInterval)s")

        // Ask once for notification permission (silent if already decided).
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }

        // First check after a short delay so we don't block startup.
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            await self?.checkUsage()
        }

        timer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.checkUsage()
            }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// Public hook so the toggle UI can fire a test alarm without waiting for
    /// real usage to cross 95%. Bypasses the "already-fired" gate.
    func playTestAlarm() {
        playAlarmSound()
    }

    // MARK: - Internals

    private func checkUsage() async {
        // Re-check on every tick so toggling at runtime takes effect immediately.
        let enabled = UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? true
        guard enabled else { return }

        guard let snapshot = await runClaudeMeter() else { return }
        guard let (utilization, resetsAt) = maxFiveHourUtilization(in: snapshot) else { return }

        // If the window identifier changed since we last fired, re-arm.
        if let last = lastFiredWindowResetsAt, last != resetsAt {
            logLine("5h window rolled over (was \(last), now \(resetsAt ?? "nil")), re-arming")
            lastFiredWindowResetsAt = nil
        }

        if utilization >= threshold, lastFiredWindowResetsAt == nil {
            logLine("utilization=\(utilization)% >= \(threshold)%, firing alarm (window resets at \(resetsAt ?? "?"))")
            lastFiredWindowResetsAt = resetsAt ?? "fired"
            playAlarmSound()
            postSystemNotification(utilization: utilization, resetsAt: resetsAt)
        }
    }

    /// Run `claude-meter --json` and return the parsed array.
    private func runClaudeMeter() async -> [[String: Any]]? {
        let cliPath = claudeMeterCLI
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: cliPath)
                process.arguments = ["--json"]

                let outPipe = Pipe()
                let errPipe = Pipe()
                process.standardOutput = outPipe
                process.standardError = errPipe

                do {
                    try process.run()
                } catch {
                    NSLog("ClaudeUsageAlarmMonitor: failed to launch claude-meter: %@", String(describing: error))
                    continuation.resume(returning: nil)
                    return
                }

                // Hard 10s cap; the CLI usually returns in under a second.
                let deadline = DispatchTime.now() + .seconds(10)
                let group = DispatchGroup()
                group.enter()
                DispatchQueue.global().async {
                    process.waitUntilExit()
                    group.leave()
                }
                if group.wait(timeout: deadline) == .timedOut {
                    process.terminate()
                    NSLog("ClaudeUsageAlarmMonitor: claude-meter timed out")
                    continuation.resume(returning: nil)
                    return
                }

                let data = outPipe.fileHandleForReading.readDataToEndOfFile()
                guard !data.isEmpty,
                      let parsed = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: parsed)
            }
        }
    }

    /// Returns the max `usage.five_hour.utilization` across all orgs, plus the
    /// associated `resets_at` (used as a window identifier).
    private func maxFiveHourUtilization(in snapshot: [[String: Any]]) -> (Double, String?)? {
        var best: (Double, String?)?
        for org in snapshot {
            guard let usage = org["usage"] as? [String: Any],
                  let fiveHour = usage["five_hour"] as? [String: Any],
                  let util = (fiveHour["utilization"] as? NSNumber)?.doubleValue
            else { continue }
            let resetsAt = fiveHour["resets_at"] as? String
            if best == nil || util > best!.0 {
                best = (util, resetsAt)
            }
        }
        return best
    }

    /// Plays the system "Sosumi" sound three times with 0.55s spacing.
    /// "Sosumi" is the classic Mac alert tone, sharp enough to read as an
    /// alarm without sounding like a Slack ping.
    private func playAlarmSound() {
        DispatchQueue.global(qos: .userInitiated).async {
            for i in 0..<3 {
                if let sound = NSSound(named: "Sosumi") {
                    sound.volume = 0.9
                    sound.play()
                }
                if i < 2 {
                    Thread.sleep(forTimeInterval: 0.55)
                }
            }
        }
    }

    /// Best-effort visual notification so the alarm has a tappable surface,
    /// not just a sound. Falls back silently if Notifications aren't permitted.
    private func postSystemNotification(utilization: Double, resetsAt: String?) {
        let content = UNMutableNotificationContent()
        content.title = "Claude usage at \(Int(utilization))%"
        if let resetsAt, let resetDate = ISO8601DateFormatter().date(from: resetsAt) {
            let formatter = DateFormatter()
            formatter.timeStyle = .short
            content.subtitle = "5h window resets at \(formatter.string(from: resetDate))"
        } else {
            content.subtitle = "5-hour rolling window"
        }
        content.body = "You're close to the 5-hour limit. Wrap up or wait for the window to reset."
        // Sound handled separately via NSSound so we can repeat it.
        content.sound = nil

        let request = UNNotificationRequest(
            identifier: "claude-usage-alarm-\(resetsAt ?? UUID().uuidString)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request) { _ in }
    }

    private func logLine(_ message: String) {
        NSLog("ClaudeUsageAlarmMonitor: %@", message)
    }
}
