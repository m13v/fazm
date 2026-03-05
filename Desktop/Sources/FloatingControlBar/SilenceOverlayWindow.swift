import Cocoa
import SwiftUI

/// NSPanel subclass that can become key (required for NSPopUpButton and other
/// interactive controls to work in a borderless floating panel).
private class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Manages a separate floating window for the silence overlay (shown when PTT ends with no speech).
@MainActor
class SilenceOverlayWindow {
    static let shared = SilenceOverlayWindow()

    private var window: NSWindow?
    private static let overlayWidth: CGFloat = 300

    /// Show the silence overlay positioned below the given bar window frame.
    func show(below barFrame: NSRect) {
        dismiss()

        let hostingView = NSHostingView(
            rootView: SilenceOverlayView(onDismiss: { [weak self] in
                self?.dismiss()
            })
            .frame(width: Self.overlayWidth)
        )

        // Let SwiftUI compute the intrinsic height
        let fittingSize = hostingView.fittingSize
        let overlaySize = NSSize(width: Self.overlayWidth, height: fittingSize.height)

        let x = barFrame.midX - overlaySize.width / 2
        let y = barFrame.minY - overlaySize.height - 8

        let panel = KeyablePanel(
            contentRect: NSRect(origin: NSPoint(x: x, y: y), size: overlaySize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.becomesKeyOnlyIfNeeded = false

        hostingView.frame = NSRect(origin: .zero, size: overlaySize)
        panel.contentView = hostingView

        panel.makeKeyAndOrderFront(nil)
        self.window = panel
    }

    func dismiss() {
        window?.orderOut(nil)
        window = nil
    }
}
