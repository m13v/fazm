import Cocoa
import Combine
import SwiftUI

// MARK: - Tutorial Step

enum TutorialStep: Int, CaseIterable {
    case pressKey = 0
    case speaking = 1
    case done = 2
}

// MARK: - TutorialViewModel

@MainActor
class TutorialViewModel: ObservableObject {
    @Published var step: TutorialStep = .pressKey
    @Published var pulseScale: CGFloat = 1.0

    private var pulseTimer: Timer?

    func startPulse() {
        pulseTimer = Timer.scheduledTimer(withTimeInterval: 1.2, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                withAnimation(.easeInOut(duration: 0.6)) {
                    self.pulseScale = 1.15
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    withAnimation(.easeInOut(duration: 0.6)) {
                        self.pulseScale = 1.0
                    }
                }
            }
        }
    }

    func stopPulse() {
        pulseTimer?.invalidate()
        pulseTimer = nil
    }

    deinit {
        pulseTimer?.invalidate()
    }
}

// MARK: - PostOnboardingTutorialManager

@MainActor
class PostOnboardingTutorialManager {
    static let shared = PostOnboardingTutorialManager()

    private var window: PostOnboardingTutorialWindow?
    private var viewModel = TutorialViewModel()
    private var cancellables = Set<AnyCancellable>()
    private let userDefaultsKey = "hasSeenPostOnboardingTutorial"

    private init() {}

    func showIfNeeded(barState: FloatingControlBarState) {
        guard !UserDefaults.standard.bool(forKey: userDefaultsKey) else { return }

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self else { return }
            self.show()
            self.observeVoiceState(barState: barState)
        }
    }

    private func show() {
        guard window == nil else { return }

        let tutorialWindow = PostOnboardingTutorialWindow(viewModel: viewModel)
        self.window = tutorialWindow

        positionBelowBar(tutorialWindow)
        viewModel.startPulse()

        tutorialWindow.alphaValue = 0
        tutorialWindow.orderFront(nil)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.3
            tutorialWindow.animator().alphaValue = 1
        }
    }

    private func positionBelowBar(_ tutorialWindow: NSWindow) {
        let windowSize = NSSize(width: 320, height: 160)

        if let barFrame = FloatingControlBarManager.shared.barWindowFrame {
            let x = barFrame.midX - windowSize.width / 2
            let y = barFrame.minY - windowSize.height - 12
            tutorialWindow.setFrame(NSRect(origin: NSPoint(x: x, y: y), size: windowSize), display: true)
        } else if let screen = NSScreen.main {
            let x = screen.frame.midX - windowSize.width / 2
            let y = screen.frame.maxY - 80 - windowSize.height
            tutorialWindow.setFrame(NSRect(origin: NSPoint(x: x, y: y), size: windowSize), display: true)
        }
    }

    private func observeVoiceState(barState: FloatingControlBarState) {
        barState.$isVoiceListening
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isListening in
                guard let self else { return }
                switch self.viewModel.step {
                case .pressKey:
                    if isListening {
                        self.viewModel.stopPulse()
                        withAnimation(.easeInOut(duration: 0.3)) {
                            self.viewModel.step = .speaking
                        }
                    }
                case .speaking:
                    if !isListening {
                        withAnimation(.easeInOut(duration: 0.3)) {
                            self.viewModel.step = .done
                        }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                            self?.dismiss()
                        }
                    }
                case .done:
                    break
                }
            }
            .store(in: &cancellables)
    }

    func dismiss() {
        UserDefaults.standard.set(true, forKey: userDefaultsKey)
        cancellables.removeAll()
        viewModel.stopPulse()

        guard let window else { return }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.3
            window.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            self?.window?.orderOut(nil)
            self?.window = nil
        })
    }
}

// MARK: - PostOnboardingTutorialWindow

class PostOnboardingTutorialWindow: NSWindow {
    init(viewModel: TutorialViewModel) {
        let size = NSSize(width: 320, height: 160)
        super.init(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )

        self.appearance = NSAppearance(named: .vibrantDark)
        self.isOpaque = false
        self.backgroundColor = .clear
        self.hasShadow = true
        self.level = .floating
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        self.isMovableByWindowBackground = false

        let hostingView = NSHostingView(rootView: PostOnboardingTutorialView(viewModel: viewModel, onSkip: { [weak self] in
            Task { @MainActor in
                PostOnboardingTutorialManager.shared.dismiss()
                _ = self  // prevent unused capture warning
            }
        }))
        hostingView.frame = NSRect(origin: .zero, size: size)
        self.contentView = hostingView
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

// MARK: - PostOnboardingTutorialView

struct PostOnboardingTutorialView: View {
    @ObservedObject var viewModel: TutorialViewModel
    var onSkip: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            // Upward arrow
            Triangle()
                .fill(Color(nsColor: NSColor(white: 0.12, alpha: 1.0)))
                .frame(width: 16, height: 8)

            // Card
            VStack(spacing: 12) {
                stepContent
                    .animation(.easeInOut(duration: 0.3), value: viewModel.step)

                // Progress dots
                HStack(spacing: 8) {
                    ForEach(TutorialStep.allCases, id: \.rawValue) { step in
                        Circle()
                            .fill(step == viewModel.step ? FazmColors.purplePrimary : Color.white.opacity(0.3))
                            .frame(width: step == viewModel.step ? 8 : 6, height: step == viewModel.step ? 8 : 6)
                            .animation(.easeInOut(duration: 0.2), value: viewModel.step)
                    }
                }

                if viewModel.step != .done {
                    Button(action: onSkip) {
                        Text("Skip")
                            .font(.system(size: 12))
                            .foregroundColor(FazmColors.textTertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 12)
            .floatingBackground(cornerRadius: 16)
        }
    }

    @ViewBuilder
    private var stepContent: some View {
        switch viewModel.step {
        case .pressKey:
            VStack(spacing: 8) {
                KeyCapView(pulseScale: viewModel.pulseScale)
                Text("Press and hold Right ⌘ to talk")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(FazmColors.textPrimary)
                Text("Your voice becomes your cursor")
                    .font(.system(size: 12))
                    .foregroundColor(FazmColors.textTertiary)
            }
            .transition(.opacity)

        case .speaking:
            VStack(spacing: 8) {
                ActiveListeningIndicator()
                    .frame(height: 28)
                Text("Say: Go to Google and search for fazm.ai")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(FazmColors.textPrimary)
                    .multilineTextAlignment(.center)
                Text("Then release ⌘ to send")
                    .font(.system(size: 12))
                    .foregroundColor(FazmColors.textTertiary)
            }
            .transition(.opacity)

        case .done:
            VStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 28))
                    .foregroundColor(FazmColors.purplePrimary)
                Text("You're ready!")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(FazmColors.textPrimary)
                Text("Right ⌘ → speak → release, anytime")
                    .font(.system(size: 12))
                    .foregroundColor(FazmColors.textTertiary)
            }
            .transition(.opacity)
        }
    }
}

// MARK: - KeyCapView

struct KeyCapView: View {
    var pulseScale: CGFloat

    var body: some View {
        HStack(spacing: 4) {
            Text("⌘")
                .font(.system(size: 16, weight: .medium))
            Text("Right")
                .font(.system(size: 11, weight: .medium))
        }
        .foregroundColor(FazmColors.textPrimary)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(nsColor: NSColor(white: 0.18, alpha: 1.0)))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(FazmColors.purplePrimary.opacity(0.6), lineWidth: 1)
        )
        .shadow(color: FazmColors.purplePrimary.opacity(0.4), radius: 8 * pulseScale, x: 0, y: 0)
        .scaleEffect(pulseScale)
    }
}

// MARK: - ActiveListeningIndicator

struct ActiveListeningIndicator: View {
    @State private var animating = false

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<5, id: \.self) { index in
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(FazmColors.purplePrimary)
                    .frame(width: 3, height: animating ? barHeight(for: index) : 4)
                    .animation(
                        .easeInOut(duration: 0.4 + Double(index) * 0.1)
                        .repeatForever(autoreverses: true)
                        .delay(Double(index) * 0.1),
                        value: animating
                    )
            }
        }
        .onAppear { animating = true }
    }

    private func barHeight(for index: Int) -> CGFloat {
        let heights: [CGFloat] = [12, 20, 28, 18, 14]
        return heights[index]
    }
}

// MARK: - Triangle Shape

struct Triangle: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}
