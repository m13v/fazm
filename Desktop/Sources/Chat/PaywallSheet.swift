import SwiftUI
import AppKit

/// Paywall overlay shown when the user exceeds their free message limit after the trial.
struct PaywallSheet: View {
    let onSubscribe: () -> Void
    let onDismiss: () -> Void

    @State private var showReferral = false
    @State private var referralCode: String = ""
    @State private var referralUrl: String = ""
    @State private var isLoadingReferral = false
    @State private var linkCopied = false

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                if showReferral {
                    Button(action: { showReferral = false }) {
                        Image(systemName: "chevron.left")
                            .scaledFont(size: 14, weight: .medium)
                            .foregroundColor(FazmColors.textTertiary)
                    }
                    .buttonStyle(.plain)
                }

                Text(showReferral ? "Refer a Friend" : "Upgrade to Fazm Pro")
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

            if showReferral {
                referralView
            } else {
                paywallView
            }
        }
        .frame(width: 400, height: 560)
        .background(FazmColors.backgroundPrimary)
    }

    // MARK: - Paywall View

    private var paywallView: some View {
        VStack(spacing: 0) {
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
                Button(action: {
                    AnalyticsManager.shared.subscriptionUpgradeTapped(source: "paywall")
                    onSubscribe()
                }) {
                    Text("Subscribe Now")
                        .scaledFont(size: 14, weight: .semibold)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(FazmColors.purpleGradient)
                        .foregroundColor(.white)
                        .cornerRadius(8)
                }
                .buttonStyle(.plain)

                Button(action: {
                    AnalyticsManager.shared.paywallReferralTapped()
                    showReferral = true
                    loadReferralCode()
                }) {
                    HStack(spacing: 6) {
                        Image(systemName: "person.2.fill")
                            .scaledFont(size: 12)
                        Text("Get 1 month free — refer a friend")
                            .scaledFont(size: 12, weight: .medium)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(FazmColors.backgroundTertiary.opacity(0.6))
                    .foregroundColor(FazmColors.textSecondary)
                    .cornerRadius(8)
                }
                .buttonStyle(.plain)

                Button(action: {
                    AnalyticsManager.shared.paywallFounderCallTapped()
                    if let url = URL(string: "https://cal.com/team/mediar/onboarding") {
                        NSWorkspace.shared.open(url)
                    }
                }) {
                    HStack(spacing: 6) {
                        Image(systemName: "video.fill")
                            .scaledFont(size: 12)
                        Text("Get 1 month free — chat with our founder")
                            .scaledFont(size: 12, weight: .medium)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(FazmColors.backgroundTertiary.opacity(0.6))
                    .foregroundColor(FazmColors.textSecondary)
                    .cornerRadius(8)
                }
                .buttonStyle(.plain)

                Button(action: {
                    AnalyticsManager.shared.paywallDismissed()
                    onDismiss()
                }) {
                    Text("Maybe Later")
                        .scaledFont(size: 13)
                        .foregroundColor(FazmColors.textTertiary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 20)
        }
    }

    // MARK: - Referral View

    private var referralView: some View {
        VStack(spacing: 0) {
            VStack(spacing: 20) {
                Image(systemName: "gift.fill")
                    .scaledFont(size: 40)
                    .foregroundStyle(FazmColors.purpleGradient)
                    .padding(.top, 16)

                VStack(spacing: 8) {
                    Text("Get 1 month free")
                        .scaledFont(size: 17, weight: .semibold)
                        .foregroundColor(FazmColors.textPrimary)

                    Text("Share your link with a friend. When they install Fazm and send 5 messages, you both get 1 month of Pro free.")
                        .scaledFont(size: 13)
                        .foregroundColor(FazmColors.textTertiary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 20)

                if isLoadingReferral {
                    ProgressView()
                        .scaleEffect(0.8)
                        .padding(.vertical, 20)
                } else if !referralCode.isEmpty {
                    // Referral code display
                    VStack(spacing: 12) {
                        Text("Your referral code")
                            .scaledFont(size: 12)
                            .foregroundColor(FazmColors.textTertiary)

                        Text(referralCode)
                            .scaledFont(size: 24, weight: .bold)
                            .foregroundColor(FazmColors.textPrimary)
                            .tracking(4)
                            .padding(.horizontal, 20)
                            .padding(.vertical, 10)
                            .background(FazmColors.backgroundTertiary.opacity(0.5))
                            .cornerRadius(8)
                    }

                    // Copy link button
                    Button(action: copyLink) {
                        HStack(spacing: 6) {
                            Image(systemName: linkCopied ? "checkmark" : "doc.on.doc")
                                .scaledFont(size: 13)
                            Text(linkCopied ? "Link copied!" : "Copy referral link")
                                .scaledFont(size: 14, weight: .medium)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background {
                            if linkCopied {
                                FazmColors.success.opacity(0.2)
                            } else {
                                FazmColors.purpleGradient
                            }
                        }
                        .foregroundColor(linkCopied ? FazmColors.success : .white)
                        .cornerRadius(8)
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 20)
                }

                // Steps
                VStack(alignment: .leading, spacing: 10) {
                    stepRow(number: "1", text: "Share your link with a friend")
                    stepRow(number: "2", text: "They download and install Fazm")
                    stepRow(number: "3", text: "They send 5 messages from the floating bar")
                    stepRow(number: "4", text: "You both get 1 month of Pro free")
                }
                .padding(.horizontal, 20)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 8)

            Spacer()

            Button(action: { showReferral = false }) {
                Text("Back to upgrade options")
                    .scaledFont(size: 13)
                    .foregroundColor(FazmColors.textTertiary)
            }
            .buttonStyle(.plain)
            .padding(.bottom, 20)
        }
    }

    // MARK: - Helpers

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

    private func stepRow(number: String, text: String) -> some View {
        HStack(spacing: 10) {
            Text(number)
                .scaledFont(size: 11, weight: .bold)
                .foregroundColor(.white)
                .frame(width: 20, height: 20)
                .background(FazmColors.purpleGradient)
                .clipShape(Circle())
            Text(text)
                .scaledFont(size: 13)
                .foregroundColor(FazmColors.textSecondary)
        }
    }

    private func loadReferralCode() {
        guard referralCode.isEmpty else { return }
        isLoadingReferral = true
        Task {
            do {
                let (code, url) = try await ReferralService.shared.generateReferralCode()
                await MainActor.run {
                    referralCode = code
                    referralUrl = url
                    isLoadingReferral = false
                }
            } catch {
                log("PaywallSheet: referral load error: \(error.localizedDescription)")
                await MainActor.run {
                    isLoadingReferral = false
                }
            }
        }
    }

    private func copyLink() {
        guard !referralUrl.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(referralUrl, forType: .string)
        linkCopied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            linkCopied = false
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

        Task { @MainActor in AnalyticsManager.shared.paywallShown() }
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
        hostingView.setFrameSize(NSSize(width: 400, height: 560))

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: NSSize(width: 400, height: 560)),
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

        let mouseScreen = NSScreen.screens.first(where: { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) })
            ?? NSScreen.main ?? NSScreen.screens.first
        if let screen = mouseScreen {
            let sf = screen.visibleFrame
            let x = sf.origin.x + (sf.width - 400) / 2
            let y = sf.origin.y + (sf.height - 560) / 2
            window.setFrame(NSRect(x: x, y: y, width: 400, height: 560), display: true)
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
