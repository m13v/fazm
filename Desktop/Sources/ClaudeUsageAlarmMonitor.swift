import Foundation
import AppKit
import UserNotifications

/// Watches the user's Claude plan 5-hour rolling-window utilization (via the
/// menu-bar app's cached snapshot file) and plays an alarm sound when usage
/// crosses 95% in the current window.
///
/// Toggle via the `claudeUsageAlarmEnabled` UserDefault (default: true).
/// Exposed in the floating-bar header dropdown so the user can mute the alarm.
///
/// Implementation notes:
/// - Reads `~/Library/Application Support/ClaudeMeter/snapshots.json` every
///   60s. Zero network calls; the ClaudeMeter menu-bar app is the single
///   poller and writes that file after every successful OAuth fetch. Earlier
///   versions invoked `claude-meter --json`, which spawned a subprocess that
///   re-fetched the OAuth endpoints, doubling the rate-limit pressure on
///   Anthropic's API and causing 429s.
/// - Fires at most once per 5-hour window. The window is identified by the
///   `resets_at` timestamp; when it changes, the "already-fired" flag clears
///   and the alarm becomes armed again.
/// - If multiple Claude orgs are returned, we use the maximum 5-hour
///   utilization across them (most aggressive trigger).
/// - The alarm plays the system "Sosumi" sound three times with 0.55s spacing
///   to feel like a notification alarm rather than a single ding.
/// - Snapshot freshness: we trust whatever the menu bar wrote. If the file
///   is older than 10 minutes we skip the alarm tick (the menu bar might be
///   paused/throttled/missing) rather than fire on stale data.
@MainActor
final class ClaudeUsageAlarmMonitor {
    static let shared = ClaudeUsageAlarmMonitor()

    /// UserDefaults key — also referenced by the SwiftUI toggle in
    /// `AIResponseView.swift`. Default seeded to `true` in `FazmApp.swift`.
    static let enabledKey = "claudeUsageAlarmEnabled"

    /// Threshold (percent) that triggers the alarm.
    private let threshold: Double = 95.0

    /// Where the ClaudeMeter menu-bar app persists its latest snapshot.
    /// We READ this file; we never spawn the CLI (which would re-fetch and
    /// double-poll Anthropic's OAuth endpoints).
    private let snapshotPath: String = {
        let support = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!
        return support.appendingPathComponent("ClaudeMeter/snapshots.json").path
    }()

    /// Polling interval. 60s matches the menu-bar app's own refresh cadence.
    private let pollInterval: TimeInterval = 60

    /// Maximum age of the menu-bar's snapshot before we treat it as stale and
    /// skip the alarm check. 10 minutes is generous: the menu bar polls every
    /// 30s, so anything older means it's down or throttled.
    private let maxSnapshotAge: TimeInterval = 10 * 60

    private var timer: Timer?

    /// `resets_at` of the window we already fired for. When the next poll sees
    /// a different (newer) `resets_at`, we re-arm.
    private var lastFiredWindowResetsAt: String?

    /// Tracks whether we've logged at least one successful poll. We log the
    /// first one (so users can confirm the monitor is reading data) and stay
    /// silent on the rest until utilization crosses the threshold.
    private var hasLoggedFirstPoll = false

    private init() {}

    func start() {
        guard timer == nil else { return }

        // Programmatic test hook — fires the alarm without needing the UI.
        // Trigger: xcrun swift -e 'import Foundation; DistributedNotificationCenter.default().postNotificationName(.init("com.fazm.testAlarm"), object: nil, userInfo: nil, deliverImmediately: true); RunLoop.current.run(until: Date(timeIntervalSinceNow: 1.0))'
        DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.fazm.testAlarm"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.logLine("test alarm received via distributed notification")
                self?.playTestAlarm()
            }
        }

        // Skip the polling timer entirely if the menu bar isn't running yet.
        // The test-alarm hook above still works so the user can verify the
        // sound, and the dropdown toggle still functions.
        if !FileManager.default.fileExists(atPath: snapshotPath) {
            logLine("snapshot file not yet at \(snapshotPath); polling will pick it up once ClaudeMeter writes it. Dropdown + test-alarm still active.")
        }

        logLine("starting, threshold=\(threshold)%, poll=\(pollInterval)s, source=\(snapshotPath)")

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

        guard let snapshot = readCachedSnapshot() else { return }
        guard let (utilization, resetsAt) = maxFiveHourUtilization(in: snapshot) else { return }

        if !hasLoggedFirstPoll {
            hasLoggedFirstPoll = true
            logLine("first poll OK: utilization=\(utilization)%, window resets at \(resetsAt ?? "?") (will fire alarm at \(threshold)%)")
        }

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

    /// Read the menu bar's cached snapshot file. Zero subprocesses, zero API
    /// calls. Returns nil on any error (missing file, parse failure, stale
    /// data) so `checkUsage` skips this tick.
    private func readCachedSnapshot() -> [[String: Any]]? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: snapshotPath)) else {
            // File not present yet, e.g. ClaudeMeter not running. Don't spam
            // the log — the start() banner already told the user.
            return nil
        }
        guard let parsed = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            logLine("snapshot file at \(snapshotPath) failed to parse as JSON array; skipping tick")
            return nil
        }

        // Skip if every snapshot is older than maxSnapshotAge. Use the
        // freshest fetched_at across snapshots so a single fresh row is enough.
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let formatterNoFrac = ISO8601DateFormatter()
        let now = Date()
        var freshest: Date?
        for snap in parsed {
            guard let fetchedAtString = snap["fetched_at"] as? String else { continue }
            let date = formatter.date(from: fetchedAtString)
                ?? formatterNoFrac.date(from: fetchedAtString)
            if let date {
                if freshest == nil || date > freshest! {
                    freshest = date
                }
            }
        }
        if let freshest {
            let age = now.timeIntervalSince(freshest)
            if age > maxSnapshotAge {
                logLine(String(format: "snapshot is %.0fs stale (max %.0fs); skipping. ClaudeMeter may be paused or rate-limited.", age, maxSnapshotAge))
                return nil
            }
        }
        return parsed
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
        log("ClaudeUsageAlarmMonitor: \(message)")
    }
}
