import Cocoa
import SwiftUI

/// A read-only selectable text view with visible selection highlighting.
/// Use instead of `Text(...).textSelection(.enabled)` when the default
/// selection color is invisible (e.g. vibrantLight floating bar).
struct SelectableText: NSViewRepresentable {
    let text: String
    var fontSize: CGFloat = 13
    var textColor: NSColor = .labelColor
    var lineLimit: Int? = nil

    func makeNSView(context: Context) -> NSTextView {
        let textView = NSTextView()
        textView.string = text
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.backgroundColor = .clear
        textView.font = .systemFont(ofSize: fontSize)
        textView.textColor = textColor
        textView.selectedTextAttributes = [
            .backgroundColor: NSColor(Color(hex: 0x8B5CF6)).withAlphaComponent(0.3),
            .foregroundColor: NSColor.labelColor,
        ]
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainerInset = .zero
        textView.textContainer?.widthTracksTextView = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        if let lineLimit {
            textView.textContainer?.maximumNumberOfLines = lineLimit
            textView.textContainer?.lineBreakMode = .byTruncatingTail
        }
        return textView
    }

    func updateNSView(_ textView: NSTextView, context: Context) {
        if textView.string != text {
            textView.string = text
        }
        textView.textColor = textColor
    }
}
