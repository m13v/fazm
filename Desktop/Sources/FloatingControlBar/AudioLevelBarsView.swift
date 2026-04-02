import Combine
import SwiftUI

/// Animated equalizer-style bars that respond to an audio level (0.0–1.0).
/// Each bar gets a slightly different height based on pseudo-random offsets
/// so the visualization looks organic rather than a flat meter.
struct AudioLevelBarsView: View {
    let level: Float
    var barCount: Int = 5
    var barWidth: CGFloat = 3
    var spacing: CGFloat = 2
    var maxHeight: CGFloat = 20
    var minHeight: CGFloat = 3
    var color: Color = FazmColors.overlayForeground

    var body: some View {
        HStack(spacing: spacing) {
            ForEach(0..<barCount, id: \.self) { index in
                let barLevel = barHeight(for: index)
                RoundedRectangle(cornerRadius: barWidth / 2)
                    .fill(barColor(for: index))
                    .frame(width: barWidth, height: barLevel)
                    .animation(.easeOut(duration: 0.08), value: level)
            }
        }
        .frame(height: maxHeight)
    }

    private func barHeight(for index: Int) -> CGFloat {
        guard level > 0.001 else { return minHeight }
        // Each bar gets a different multiplier for organic look
        let offsets: [Float] = [0.7, 1.0, 0.85, 0.95, 0.75, 0.9, 0.8, 0.65]
        let offset = offsets[index % offsets.count]
        let scaled = CGFloat(min(1.0, level * offset * 1.4))
        return max(minHeight, scaled * maxHeight)
    }

    private func barColor(for index: Int) -> Color {
        let normalized = CGFloat(level)
        if normalized > 0.7 {
            return .red
        } else if normalized > 0.4 {
            return .yellow
        }
        return color
    }
}

/// Wrapper that observes AudioLevelState directly, so only this view
/// re-renders on audio level changes — not the entire conversation tree.
struct ObservedAudioLevelBarsView: View {
    @ObservedObject var audioLevel: AudioLevelState
    var barCount: Int = 5
    var barWidth: CGFloat = 3
    var spacing: CGFloat = 2
    var maxHeight: CGFloat = 20
    var minHeight: CGFloat = 3
    var color: Color = FazmColors.overlayForeground

    var body: some View {
        AudioLevelBarsView(
            level: audioLevel.level,
            barCount: barCount,
            barWidth: barWidth,
            spacing: spacing,
            maxHeight: maxHeight,
            minHeight: minHeight,
            color: color
        )
    }
}

/// Observed transcript view that only re-renders when AudioLevelState changes,
/// not when the entire FloatingControlBarState changes.
struct ObservedTranscriptView: View {
    @ObservedObject var audioLevel: AudioLevelState
    var isVoiceFinalizing: Bool
    var isVoiceLocked: Bool
    var pttKeySymbol: String

    var body: some View {
        if isVoiceFinalizing {
            Text("Transcribing...")
                .scaledFont(size: 13)
                .foregroundColor(FazmColors.overlayForeground.opacity(0.8))
        } else if !audioLevel.transcript.isEmpty {
            Text(audioLevel.transcript)
                .scaledFont(size: 13)
                .foregroundColor(FazmColors.overlayForeground.opacity(0.8))
                .lineLimit(1)
                .truncationMode(.head)
        } else {
            Text(isVoiceLocked ? "Tap \(pttKeySymbol) to send" : "Release \(pttKeySymbol) to send")
                .scaledFont(size: 13)
                .foregroundColor(FazmColors.overlayForeground.opacity(0.5))
        }
    }
}

/// Larger version for Settings with green/yellow/red gradient bars.
struct AudioLevelBarsSettingsView: View {
    let level: Float
    var barCount: Int = 20
    var barWidth: CGFloat = 4
    var spacing: CGFloat = 2
    var maxHeight: CGFloat = 24
    var minHeight: CGFloat = 2

    var body: some View {
        HStack(spacing: spacing) {
            ForEach(0..<barCount, id: \.self) { index in
                let threshold = Float(index) / Float(barCount)
                let isActive = level > threshold
                RoundedRectangle(cornerRadius: barWidth / 2)
                    .fill(isActive ? activeColor(for: index) : FazmColors.backgroundTertiary.opacity(0.8))
                    .frame(width: barWidth, height: isActive ? activeHeight(for: index) : minHeight)
                    .animation(.easeOut(duration: 0.06), value: level)
            }
        }
        .frame(height: maxHeight)
    }

    private func activeHeight(for index: Int) -> CGFloat {
        let progress = CGFloat(index) / CGFloat(barCount)
        return max(minHeight, (0.3 + progress * 0.7) * maxHeight)
    }

    private func activeColor(for index: Int) -> Color {
        let progress = Double(index) / Double(barCount)
        if progress > 0.75 { return .red }
        if progress > 0.5 { return .yellow }
        return .green
    }
}

/// Self-contained audio level meter that subscribes directly to
/// AudioDeviceManager.audioLevelSubject. Only THIS view re-renders
/// on audio level changes — not the parent SettingsContentView.
struct ObservedAudioLevelBarsSettingsView: View {
    @State private var level: Float = 0
    var barCount: Int = 20
    var barWidth: CGFloat = 4
    var spacing: CGFloat = 2
    var maxHeight: CGFloat = 24
    var minHeight: CGFloat = 2

    var body: some View {
        AudioLevelBarsSettingsView(
            level: level,
            barCount: barCount,
            barWidth: barWidth,
            spacing: spacing,
            maxHeight: maxHeight,
            minHeight: minHeight
        )
        .onReceive(AudioDeviceManager.shared.audioLevelSubject) { newLevel in
            level = newLevel
        }
    }
}
