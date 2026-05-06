import SwiftUI

/// NSVisualEffectView wrapper for dark blur background.
struct VisualEffectView: NSViewRepresentable {
    var material: NSVisualEffectView.Material
    var blendingMode: NSVisualEffectView.BlendingMode
    var alphaValue: CGFloat

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        view.alphaValue = alphaValue
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
        nsView.alphaValue = alphaValue
    }
}

/// Background modifier: solid dark when conversation is focused, semi-transparent blur otherwise.
struct FloatingBackgroundModifier: ViewModifier {
    let cornerRadius: CGFloat
    @EnvironmentObject private var state: FloatingControlBarState

    /// Use solid background when the AI conversation is open and not collapsed, or during push-to-talk.
    private var useSolid: Bool {
        (state.streaming.showingAIConversation && !state.isCollapsed) || state.isVoiceListening
    }

    func body(content: Content) -> some View {
        content
            .background(
                ZStack {
                    VisualEffectView(material: .fullScreenUI, blendingMode: .behindWindow, alphaValue: 0.6)
                        .opacity(useSolid ? 0 : 1)
                    FazmColors.backgroundSecondary
                        .opacity(useSolid ? 1 : 0)
                }
                .animation(.easeInOut(duration: 0.25), value: useSolid)
            )
            .cornerRadius(cornerRadius)
            .animation(.easeInOut(duration: 0.25), value: cornerRadius)
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .strokeBorder(FazmColors.overlayBorder.opacity(0.5), lineWidth: 1)
                    .animation(.easeInOut(duration: 0.25), value: cornerRadius)
            )
    }
}

extension View {
    func floatingBackground(cornerRadius: CGFloat = 20) -> some View {
        modifier(FloatingBackgroundModifier(cornerRadius: cornerRadius))
    }
}

/// Simple spinning loader for the floating bar.
struct FloatingLoadingSpinner: View {
    @State private var isSpinning = false

    var body: some View {
        Circle()
            .trim(from: 0.1, to: 0.9)
            .stroke(FazmColors.overlayForeground, lineWidth: 2)
            .rotationEffect(.degrees(isSpinning ? 360 : 0))
            .onAppear { isSpinning = true }
            .animation(
                .linear(duration: 1).repeatForever(autoreverses: false),
                value: isSpinning
            )
    }
}
