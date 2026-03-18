import SwiftUI

struct InstallerView: View {
    @StateObject private var installer = InstallerViewModel()

    var body: some View {
        VStack(spacing: 20) {
            Spacer()

            // App icon
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .frame(width: 80, height: 80)

            // Status text
            Text(installer.statusText)
                .font(.title3)
                .fontWeight(.medium)
                .multilineTextAlignment(.center)

            // Progress section
            VStack(spacing: 8) {
                ProgressView(value: installer.progress)
                    .progressViewStyle(.linear)

                HStack {
                    Text(installer.detailText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(installer.progressPercent)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            .padding(.horizontal, 40)

            // Error / Cancel
            if let error = installer.error {
                VStack(spacing: 8) {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 40)

                    Button("Retry") {
                        installer.start()
                    }
                    .buttonStyle(.borderedProminent)
                }
            } else if installer.phase != .done {
                Button("Cancel") {
                    installer.cancel()
                    NSApplication.shared.terminate(nil)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding()
        .onAppear {
            installer.start()
        }
    }
}

enum InstallPhase {
    case fetchingManifest
    case downloading
    case verifying
    case installing
    case launching
    case done
}

@MainActor
class InstallerViewModel: ObservableObject {
    @Published var phase: InstallPhase = .fetchingManifest
    @Published var progress: Double = 0
    @Published var downloadSpeed: String = ""
    @Published var error: String?

    private var downloadManager: DownloadManager?
    private var cancelled = false

    var statusText: String {
        switch phase {
        case .fetchingManifest: return "Preparing installation..."
        case .downloading: return "Downloading Fazm..."
        case .verifying: return "Verifying download..."
        case .installing: return "Installing Fazm..."
        case .launching: return "Launching Fazm..."
        case .done: return "Done!"
        }
    }

    var detailText: String {
        switch phase {
        case .downloading: return downloadSpeed
        default: return ""
        }
    }

    var progressPercent: String {
        "\(Int(progress * 100))%"
    }

    func start() {
        error = nil
        cancelled = false
        phase = .fetchingManifest
        progress = 0

        Task {
            do {
                // 1. Fetch manifest
                let manifest = try await ManifestLoader.fetchManifest()

                if cancelled { return }

                // 2. Pick arch-specific payload
                let arch = ProcessInfo.processInfo.machineArchitecture
                guard let payload = manifest.payload(for: arch) else {
                    throw InstallerError.unsupportedArchitecture(arch)
                }

                // 3. Download
                phase = .downloading
                let dm = DownloadManager()
                self.downloadManager = dm

                let zipURL = try await dm.download(
                    from: payload.url,
                    expectedSize: payload.size
                ) { [weak self] fractionCompleted, speed in
                    Task { @MainActor in
                        self?.progress = fractionCompleted
                        self?.downloadSpeed = speed
                    }
                }

                if cancelled { return }

                // 4. Verify SHA256
                phase = .verifying
                progress = 0.95
                try InstallManager.verifySHA256(fileURL: zipURL, expected: payload.sha256)

                if cancelled { return }

                // 5. Install
                phase = .installing
                progress = 0.97
                let appURL = try InstallManager.install(zipURL: zipURL)

                // 6. Launch
                phase = .launching
                progress = 1.0
                InstallManager.launch(appURL: appURL)

                phase = .done

                // Quit after a short delay
                try? await Task.sleep(for: .seconds(1))
                NSApplication.shared.terminate(nil)

            } catch {
                if !cancelled {
                    self.error = error.localizedDescription
                }
            }
        }
    }

    func cancel() {
        cancelled = true
        downloadManager?.cancel()
    }
}

enum InstallerError: LocalizedError {
    case unsupportedArchitecture(String)
    case sha256Mismatch
    case extractionFailed
    case appNotFound
    case installFailed(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedArchitecture(let arch):
            return "Unsupported architecture: \(arch)"
        case .sha256Mismatch:
            return "Download verification failed. The file may be corrupted. Please try again."
        case .extractionFailed:
            return "Failed to extract the application."
        case .appNotFound:
            return "Application not found in downloaded archive."
        case .installFailed(let reason):
            return "Installation failed: \(reason)"
        }
    }
}

extension ProcessInfo {
    var machineArchitecture: String {
        var sysinfo = utsname()
        uname(&sysinfo)
        let machine = withUnsafePointer(to: &sysinfo.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) {
                String(cString: $0)
            }
        }
        // Map arm64e to arm64 for download purposes
        if machine.hasPrefix("arm64") { return "arm64" }
        return "x86_64"
    }
}
