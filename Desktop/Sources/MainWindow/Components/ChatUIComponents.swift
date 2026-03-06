import SwiftUI
import MarkdownUI

// MARK: - Content Block Grouping

/// Groups consecutive content blocks of the same type for rendering
enum ContentBlockGroup: Identifiable {
    case text(id: String, text: String)
    case toolCalls(id: String, calls: [(name: String, status: ToolCallStatus, toolUseId: String?, input: ToolCallInput?, output: String?)])
    case thinking(id: String, text: String)
    case discoveryCard(id: String, title: String, summary: String, fullText: String)

    var id: String {
        switch self {
        case .text(let id, _): return id
        case .toolCalls(let id, _): return id
        case .thinking(let id, _): return id
        case .discoveryCard(let id, _, _, _): return id
        }
    }

    /// Groups consecutive content blocks into display groups
    static func group(_ blocks: [ChatContentBlock]) -> [ContentBlockGroup] {
        var result: [ContentBlockGroup] = []
        var pendingText = ""
        var pendingTextId = ""
        var pendingToolCalls: [(name: String, status: ToolCallStatus, toolUseId: String?, input: ToolCallInput?, output: String?)] = []
        var pendingToolCallsId = ""

        func flushText() {
            if !pendingText.isEmpty {
                result.append(.text(id: pendingTextId, text: pendingText))
                pendingText = ""
                pendingTextId = ""
            }
        }

        func flushToolCalls() {
            if !pendingToolCalls.isEmpty {
                result.append(.toolCalls(id: pendingToolCallsId, calls: pendingToolCalls))
                pendingToolCalls = []
                pendingToolCallsId = ""
            }
        }

        for block in blocks {
            switch block {
            case .text(let id, let text):
                flushToolCalls()
                if pendingText.isEmpty {
                    pendingTextId = id
                }
                pendingText += (pendingText.isEmpty ? "" : "\n\n") + text

            case .toolCall(let id, let name, let status, let toolUseId, let input, let output):
                flushText()
                if pendingToolCalls.isEmpty {
                    pendingToolCallsId = id
                }
                pendingToolCalls.append((name: name, status: status, toolUseId: toolUseId, input: input, output: output))

            case .thinking(let id, let text):
                flushText()
                flushToolCalls()
                result.append(.thinking(id: id, text: text))

            case .discoveryCard(let id, let title, let summary, let fullText):
                flushText()
                flushToolCalls()
                result.append(.discoveryCard(id: id, title: title, summary: summary, fullText: fullText))
            }
        }

        flushText()
        flushToolCalls()
        return result
    }
}

// MARK: - Tool Calls Group View

struct ToolCallsGroup: View {
    let calls: [(name: String, status: ToolCallStatus, toolUseId: String?, input: ToolCallInput?, output: String?)]
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .scaledFont(size: 10)
                    Text("\(calls.count) tool \(calls.count == 1 ? "call" : "calls")")
                        .scaledFont(size: 12, weight: .medium)
                    if calls.contains(where: { $0.status == .running }) {
                        ProgressView()
                            .scaleEffect(0.5)
                            .frame(width: 12, height: 12)
                    }
                }
                .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)

            if isExpanded {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(calls.enumerated()), id: \.offset) { _, call in
                        HStack(spacing: 6) {
                            Image(systemName: call.status == .running ? "arrow.triangle.2.circlepath" : "checkmark.circle.fill")
                                .scaledFont(size: 11)
                                .foregroundColor(call.status == .running ? .orange : .green)
                            Text(call.name)
                                .scaledFont(size: 12)
                                .foregroundColor(.primary)
                            if let input = call.input {
                                Text(input.summary)
                                    .scaledFont(size: 11)
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                            }
                        }
                    }
                }
                .padding(.leading, 16)
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Thinking Block View

struct ThinkingBlock: View {
    let text: String
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .scaledFont(size: 10)
                    Image(systemName: "brain")
                        .scaledFont(size: 11)
                    Text("Thinking...")
                        .scaledFont(size: 12, weight: .medium)
                }
                .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)

            if isExpanded {
                Text(text)
                    .scaledFont(size: 12)
                    .foregroundColor(.secondary)
                    .padding(.leading, 16)
                    .textSelection(.enabled)
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Discovery Card View

struct DiscoveryCard: View {
    let title: String
    let summary: String
    let fullText: String
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title)
                    .scaledFont(size: 14, weight: .semibold)
                    .foregroundColor(.primary)
                Spacer()
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isExpanded.toggle()
                    }
                } label: {
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .scaledFont(size: 11)
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }

            Text(isExpanded ? fullText : summary)
                .scaledFont(size: 13)
                .foregroundColor(.secondary)
                .textSelection(.enabled)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.white.opacity(0.05))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Color.white.opacity(0.1), lineWidth: 1)
                )
        )
    }
}

// MARK: - Typing Indicator

struct TypingIndicator: View {
    @State private var phase = 0.0

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .fill(Color.secondary)
                    .frame(width: 6, height: 6)
                    .opacity(dotOpacity(for: index))
            }
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
                phase = 1.0
            }
        }
    }

    private func dotOpacity(for index: Int) -> Double {
        let offset = Double(index) * 0.3
        let adjusted = (phase + offset).truncatingRemainder(dividingBy: 1.0)
        return 0.3 + adjusted * 0.7
    }
}

// MARK: - MarkdownUI Theme Extensions

extension Theme {
    static func aiMessage() -> Theme {
        .gitHub.text {
            ForegroundColor(FazmColors.textPrimary)
            FontSize(14)
        }
        .code {
            FontFamilyVariant(.monospaced)
            FontSize(13)
            BackgroundColor(Color(nsColor: .controlBackgroundColor).opacity(0.5))
        }
        .link {
            ForegroundColor(FazmColors.purplePrimary)
        }
    }

    static func userMessage() -> Theme {
        .gitHub.text {
            ForegroundColor(.white)
            FontSize(14)
        }
        .code {
            FontFamilyVariant(.monospaced)
            FontSize(13)
            BackgroundColor(Color.white.opacity(0.15))
        }
        .link {
            ForegroundColor(.white.opacity(0.9))
        }
    }
}
