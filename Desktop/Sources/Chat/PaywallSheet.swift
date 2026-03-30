import SwiftUI
import AppKit

/// Paywall overlay shown when the user exceeds their free message limit after the trial.
struct PaywallSheet: View {
    let onSubscribe: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Upgrade to Fazm Pro")
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
                Image(systemName: "lock.fill")
                    .scaledFont(size: 40)
                    .foregroundStyle(FazmColors.purpleGradient)
                    .padding(.top, 8)

                VStack(spacing: 8) {
                    Text("Your free trial has ended")
                        .scaledFont(size: 15, weight: .medium)
                        .foregroundColor(FazmColors.textPrimary)
                        .multilineTextAlignment(.center)

                    Text("Subscribe to Fazm Pro to continue using the AI assistant with unlimited messages.")
                        .scaledFont(size: 13)
                        .foregroundColor(FazmColors.textTertiary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 20)

                // Pricing
                VStack(spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text("$9")
                            .scaledFont(size: 28, weight: .bold)
                            .foregroundColor(FazmColors.textPrimary)
                        Text("first month")
                            .scaledFont(size: 13)
                            .foregroundColor(FazmColors.textTertiary)
                    }
                    Text("then $49/month")
                        .scaledFont(size: 13)
                        .foregroundColor(FazmColors.textQuaternary)
                }
                .padding(.vertical, 8)

                // Features
                VStack(alignment: .leading, spacing: 8) {
                    featureRow("Unlimited AI messages")
                    featureRow("Voice and text queries")
                    featureRow("Screen context awareness")
                }
                .padding(.horizontal, 20)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)

            Spacer()

            // Actions
            VStack(spacing: 12) {
                Button(action: onSubscribe) {
                    Text("Subscribe Now")
                        .scaledFont(size: 14, weight: .semibold)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(FazmColors.purpleGradient)
                        .foregroundColor(.white)
                        .cornerRadius(8)
                }
                .buttonStyle(.plain)

                Button(action: onDismiss) {
                    Text("Maybe Later")
                        .scaledFont(size: 13)
                        .foregroundColor(FazmColors.textTertiary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 20)
        }
        .frame(width: 400, height: 480)
        .background(FazmColors.backgroundPrimary)
    }

    private func featureRow(_ text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .scaledFont(size: 14)
                .foregroundColor(FazmColors.success)
            Text(text)
                .scaledFont(size: 13)
                .foregroundColor(FazmColors.textSecondary)
        }
    }
}

// MARK: - Window Content Wrapper

private struct PaywallWindowContent: View {
    @ObservedObject var chatProvider: ChatProvider
    let onDismiss: () -> Void

    var body: some View {
        PaywallSheet(
            onSubscribe: {
                Task {
                    try? await SubscriptionService.shared.openCheckout()
                }
                onDismiss()
            },
            onDismiss: onDismiss
        )
        .onReceive(chatProvider.$showPaywall.removeDuplicates().dropFirst()) { show in
            if !show {
                onDismiss()
            }
        }
    }
}

// MARK: - Standalone Window Controller

/// Manages a standalone floating window for the paywall.
final class PaywallWindowController {
    static let shared = PaywallWindowController()
    private var window: NSWindow?
    private var hostingView: NSHostingView<AnyView>?

    func show(chatProvider: ChatProvider) {
        if let existing = window, existing.isVisible {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let controller = self
        let content = PaywallWindowContent(
            chatProvider: chatProvider,
            onDismiss: { @MainActor in
                guard chatProvider.showPaywall else {
                    controller.close()
                    return
                }
                chatProvider.showPaywall = false
                controller.close()
            }
        )

        let hostingView = NSHostingView(rootView: AnyView(content))
        hostingView.setFrameSize(NSSize(width: 400, height: 480))

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: NSSize(width: 400, height: 480)),
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
            let sf = screen.visibleFrame
            let x = sf.origin.x + (sf.width - 400) / 2
            let y = sf.origin.y + (sf.height - 480) / 2
            window.setFrame(NSRect(x: x, y: y, width: 400, height: 480), display: true)
        } else {
            window.center()
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        self.window = window
        self.hostingView = hostingView
    }

    func close() {
        window?.orderOut(nil)
        window = nil
        hostingView = nil
    }
}
