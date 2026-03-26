import SwiftUI
import AppKit

/// Overlay window shown when session recording is enabled via feature flag
/// but the user hasn't granted screen recording permission yet.
/// Follows the same pattern as ClaudeAuthWindowController.
struct SessionRecordingPermissionSheet: View {
    let onGrantPermission: () -> Void
    let onDismiss: () -> Void

    @State private var hasClickedGrant = false

    private let appName = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "Fazm"

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Screen Recording Permission")
                    .scaledFont(size: 18, weight: .semibold)
                    .foregroundColor(FazmColors.textPrimary)

                Spacer()

                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .scaledFont(size: 14, weight: .medium)
                        .foregroundColor(FazmColors.textTertiary)
                        .frame(width: 28, height: 28)
                        .background(FazmColors.backgroundTertiary.opacity(0.5))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 24)
            .padding(.top, 20)
            .padding(.bottom, 16)

            Divider()
                .foregroundColor(FazmColors.border)

            // Content
            VStack(spacing: 20) {
                // Icon
                HStack(spacing: 12) {
                    Image(systemName: "testtube.2")
                        .scaledFont(size: 32)
                        .foregroundColor(FazmColors.purplePrimary)

                    Text("Beta")
                        .scaledFont(size: 12, weight: .semibold)
                        .foregroundColor(FazmColors.purplePrimary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(FazmColors.purplePrimary.opacity(0.15))
                        .cornerRadius(6)
                }
                .padding(.top, 8)

                // Description
                VStack(spacing: 12) {
                    Text("Help us improve Fazm")
                        .scaledFont(size: 16, weight: .semibold)
                        .foregroundColor(FazmColors.textPrimary)
                        .multilineTextAlignment(.center)

                    Text("As a beta user, we'd like to record your screen while using Fazm to identify UX issues and improve the product.")
                        .scaledFont(size: 13)
                        .foregroundColor(FazmColors.textSecondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }

                // Privacy details
                VStack(alignment: .leading, spacing: 6) {
                    privacyItem(icon: "lock.shield", text: "Encrypted and stored securely on Google Cloud")
                    privacyItem(icon: "clock", text: "Automatically deleted after 30 days")
                    privacyItem(icon: "eye.slash", text: "Only used internally by the Fazm team")
                    privacyItem(icon: "hand.raised", text: "Opt out anytime in Settings → Beta channel")
                }
                .padding(.horizontal, 8)

                if !hasClickedGrant {
                    // Instructions
                    VStack(alignment: .leading, spacing: 8) {
                        Text("How to enable:")
                            .scaledFont(size: 13, weight: .medium)
                            .foregroundColor(FazmColors.textPrimary)

                        instructionStep(number: 1, text: "Click \"Grant Permission\" to open System Settings")
                        instructionStep(number: 2, text: "Find \"\(appName)\" and toggle it on")
                        instructionStep(number: 3, text: "Return here — recording starts automatically")
                    }
                    .padding(.horizontal, 8)
                } else {
                    // Waiting state
                    VStack(spacing: 8) {
                        ProgressView()
                            .scaleEffect(0.8)
                        Text("Waiting for permission to be granted...")
                            .scaledFont(size: 12)
                            .foregroundColor(FazmColors.textTertiary)
                    }
                }

                Spacer()

                // Buttons
                HStack(spacing: 12) {
                    Button(action: onDismiss) {
                        Text("Not Now")
                            .scaledFont(size: 14, weight: .medium)
                            .foregroundColor(FazmColors.textSecondary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(
                                RoundedRectangle(cornerRadius: 10)
                                    .stroke(FazmColors.border, lineWidth: 1)
                            )
                    }
                    .buttonStyle(.plain)

                    Button(action: {
                        hasClickedGrant = true
                        onGrantPermission()
                    }) {
                        HStack(spacing: 6) {
                            Image(systemName: "gear")
                                .scaledFont(size: 13)
                            Text("Grant Permission")
                                .scaledFont(size: 14, weight: .semibold)
                        }
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(
                            RoundedRectangle(cornerRadius: 10)
                                .fill(FazmColors.purplePrimary)
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(hasClickedGrant)
                    .opacity(hasClickedGrant ? 0.5 : 1)
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
        }
        .background(FazmColors.backgroundPrimary)
        .preferredColorScheme(.dark)
    }

    private func privacyItem(icon: String, text: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .scaledFont(size: 12)
                .foregroundColor(FazmColors.purplePrimary)
                .frame(width: 16)
            Text(text)
                .scaledFont(size: 12)
                .foregroundColor(FazmColors.textTertiary)
        }
    }

    private func instructionStep(number: Int, text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(number)")
                .scaledFont(size: 10, weight: .bold)
                .foregroundColor(.white)
                .frame(width: 18, height: 18)
                .background(Circle().fill(FazmColors.purplePrimary))
            Text(text)
                .scaledFont(size: 12)
                .foregroundColor(FazmColors.textSecondary)
        }
    }
}

// MARK: - Window Controller

@MainActor
final class SessionRecordingPermissionWindowController {
    static let shared = SessionRecordingPermissionWindowController()
    private var window: NSWindow?
    private var permissionCheckTimer: Timer?
    /// Prevent showing the prompt more than once per app session
    private var hasShownThisSession = false

    /// Show the prompt for testing — bypasses the once-per-session guard.
    func showForTesting() {
        log("SessionRecordingPermission: triggered via test notification")
        hasShownThisSession = false
        show(onPermissionGranted: {
            log("SessionRecordingPermission: permission granted (test trigger)")
            SessionRecordingManager.shared.checkFlagAndUpdate()
        })
    }

    func show(onPermissionGranted: @escaping () -> Void) {
        guard !hasShownThisSession else {
            log("SessionRecordingPermission: already shown this session, skipping")
            return
        }
        hasShownThisSession = true

        if let existing = window, existing.isVisible {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let controller = self
        let content = SessionRecordingPermissionSheet(
            onGrantPermission: {
                // Open System Settings first
                ScreenCaptureService.openScreenRecordingPreferences()
                // Trigger the permission prompt so the app appears in the list
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    ScreenCaptureService.requestAllScreenCapturePermissions()
                }
                // Start polling for permission grant
                controller.startPermissionPolling(onGranted: onPermissionGranted)
            },
            onDismiss: {
                controller.close()
            }
        )

        let hostingView = NSHostingView(rootView: AnyView(content))
        hostingView.setFrameSize(NSSize(width: 420, height: 520))

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: NSSize(width: 420, height: 520)),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.contentView = hostingView
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.standardWindowButton(.closeButton)?.isHidden = true
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
        window.isMovableByWindowBackground = true
        window.backgroundColor = .clear
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.appearance = NSAppearance(named: .darkAqua)

        let mouseScreen = NSScreen.screens.first(where: { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) })
            ?? NSScreen.main ?? NSScreen.screens.first
        if let screen = mouseScreen {
            let x = screen.frame.midX - 210
            let y = screen.frame.midY - 260
            window.setFrameOrigin(NSPoint(x: x, y: y))
        }

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = window

        log("SessionRecordingPermission: showing permission prompt")
    }

    func close() {
        permissionCheckTimer?.invalidate()
        permissionCheckTimer = nil
        window?.orderOut(nil)
        window = nil
        log("SessionRecordingPermission: dismissed")
    }

    private func startPermissionPolling(onGranted: @escaping () -> Void) {
        permissionCheckTimer?.invalidate()
        permissionCheckTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            if ScreenCaptureService.checkPermission() {
                log("SessionRecordingPermission: permission granted!")
                self?.close()
                onGranted()
            }
        }
    }
}
