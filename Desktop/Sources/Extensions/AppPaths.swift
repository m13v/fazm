import Foundation

/// Resolved directory names and URLs that depend on the running bundle.
/// Dev (`com.fazm.desktop-dev`) uses a separate parent so it never shares
/// `~/Library/Application Support/Fazm/` with prod — preventing the
/// migration logic from confusing one build's user dir for another.
enum AppPaths {
    /// "Fazm" for prod, "Fazm-Dev" for the dev bundle. Defaults to "Fazm"
    /// for any unknown/missing bundle ID so prod is the safe fallback.
    static var supportDirName: String {
        Bundle.main.bundleIdentifier == "com.fazm.desktop-dev" ? "Fazm-Dev" : "Fazm"
    }

    /// `~/Library/Application Support/<Fazm or Fazm-Dev>/`
    static var supportRoot: URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!
            .appendingPathComponent(supportDirName, isDirectory: true)
    }
}
