import Foundation
import AVFoundation

/// Detects double-clap patterns from the microphone to trigger actions.
///
/// Runs a lightweight background audio capture that only analyzes RMS energy
/// levels (no transcription). When two sharp transients (claps) are detected
/// within a short window, fires the `onDoubleClapDetected` callback.
///
/// Detection algorithm:
///   1. Compute RMS of each audio chunk (~100ms of 16kHz PCM)
///   2. Detect "onset" = RMS jumps above threshold while previous was quiet
///   3. Two onsets within 500ms = double clap
///   4. 2-second cooldown prevents repeated triggers
@MainActor
class ClapDetector: ObservableObject {
    static let shared = ClapDetector()

    // MARK: - Configuration

    /// RMS threshold to consider a chunk as a potential clap onset.
    /// Claps are impulsive transients — typical speech RMS is 0.02-0.05,
    /// while a clap near the mic reaches 0.12-0.25+.
    private let clapThreshold: Float = 0.12

    /// RMS must be below this before a new onset can be registered.
    /// Prevents sustained loud noise from triggering multiple onsets.
    private let quietThreshold: Float = 0.03

    /// Maximum time between two claps to count as a double-clap (seconds).
    private let doubleClapWindow: TimeInterval = 0.6

    /// Cooldown after a successful double-clap detection (seconds).
    private let cooldownDuration: TimeInterval = 2.5

    // MARK: - State

    @Published private(set) var isListening = false
    @Published private(set) var lastClapDetectedAt: Date?

    private var audioCaptureService: AudioCaptureService?
    private var previousRMS: Float = 0.0
    private var firstClapTime: TimeInterval?
    private var lastTriggerTime: TimeInterval = 0
    private var isInCooldown: Bool {
        CACurrentMediaTime() - lastTriggerTime < cooldownDuration
    }

    /// Called on the main thread when a double-clap is detected.
    var onDoubleClapDetected: (() -> Void)?

    private init() {}

    // MARK: - Public API

    /// Start listening for claps in the background.
    /// Uses its own AudioCaptureService instance (separate from PTT).
    func startListening() {
        guard !isListening else { return }

        guard AudioCaptureService.checkPermission() else {
            log("ClapDetector: microphone permission not granted, skipping")
            return
        }

        if audioCaptureService == nil {
            audioCaptureService = AudioCaptureService()
        }

        guard let capture = audioCaptureService else { return }

        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await capture.startCapture(
                    deviceUID: AudioDeviceManager.shared.effectiveDeviceUID,
                    onAudioChunk: { [weak self] audioData in
                        self?.analyzeChunk(audioData)
                    },
                    onAudioLevel: nil
                )
                self.isListening = true
                log("ClapDetector: background mic listening started")
            } catch {
                logError("ClapDetector: failed to start mic capture", error: error)
            }
        }
    }

    /// Stop listening for claps.
    func stopListening() {
        audioCaptureService?.stopCapture()
        isListening = false
        previousRMS = 0.0
        firstClapTime = nil
        log("ClapDetector: stopped")
    }

    // MARK: - Audio Analysis

    /// Analyze a chunk of 16-bit PCM audio data for clap-like transients.
    private nonisolated func analyzeChunk(_ data: Data) {
        let sampleCount = data.count / MemoryLayout<Int16>.size
        guard sampleCount > 0 else { return }

        // Calculate RMS from 16-bit PCM samples
        let rms: Float = data.withUnsafeBytes { rawBuffer in
            let samples = rawBuffer.bindMemory(to: Int16.self)
            var sumOfSquares: Float = 0.0
            for i in 0..<sampleCount {
                let normalized = Float(samples[i]) / 32767.0
                sumOfSquares += normalized * normalized
            }
            return sqrt(sumOfSquares / Float(sampleCount))
        }

        Task { @MainActor [weak self] in
            self?.processRMS(rms)
        }
    }

    /// Process RMS value on main thread for state management.
    private func processRMS(_ rms: Float) {
        defer { previousRMS = rms }

        // Skip if in cooldown
        guard !isInCooldown else { return }

        let now = CACurrentMediaTime()

        // Detect onset: RMS jumps from quiet to loud
        let isOnset = rms > clapThreshold && previousRMS < quietThreshold

        guard isOnset else {
            // If too much time passed since first clap, reset
            if let first = firstClapTime, (now - first) > doubleClapWindow {
                firstClapTime = nil
            }
            return
        }

        // We have an onset
        if firstClapTime == nil {
            // First clap
            firstClapTime = now
            log("ClapDetector: first clap detected (RMS: \(String(format: "%.3f", rms)))")
        } else if let first = firstClapTime, (now - first) <= doubleClapWindow {
            // Second clap within window — DOUBLE CLAP!
            firstClapTime = nil
            lastTriggerTime = now
            lastClapDetectedAt = Date()
            log("ClapDetector: DOUBLE CLAP detected! Triggering status briefing.")
            onDoubleClapDetected?()
        } else {
            // Too late — treat as new first clap
            firstClapTime = now
        }
    }
}
