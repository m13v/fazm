import SwiftUI

/// A press-and-hold microphone button that triggers PushToTalkManager.
/// Uses an NSView overlay to reliably capture mouseDown/mouseUp events.
struct PushToTalkButton: View {
    var isListening: Bool
    var iconSize: CGFloat = 18
    var frameSize: CGFloat = 28

    var body: some View {
        Image(systemName: isListening ? "mic.fill" : "mic")
            .scaledFont(size: iconSize)
            .foregroundColor(isListening ? .red : .secondary)
            .frame(width: frameSize, height: frameSize)
            .contentShape(Rectangle())
            .scaleEffect(isListening ? 1.15 : 1.0)
            .animation(.easeInOut(duration: 0.3), value: isListening)
            .overlay(PushToTalkMouseHandler())
            .help("Hold to talk")
    }
}

/// NSViewRepresentable that captures mouseDown/mouseUp for press-and-hold PTT.
private struct PushToTalkMouseHandler: NSViewRepresentable {
    func makeNSView(context: Context) -> PushToTalkMouseView {
        PushToTalkMouseView()
    }

    func updateNSView(_ nsView: PushToTalkMouseView, context: Context) {}
}

/// Custom NSView that forwards mouse press/release to PushToTalkManager.
final class PushToTalkMouseView: NSView {
    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        Task { @MainActor in
            PushToTalkManager.shared.startUIListening()
        }
    }

    override func mouseUp(with event: NSEvent) {
        Task { @MainActor in
            PushToTalkManager.shared.finalizeUIListening()
        }
    }
}
