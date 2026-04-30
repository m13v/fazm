import Foundation
import Combine

/// Phase 3.2 — state holder for the Codex (OpenAI/ChatGPT) backend.
///
/// Owns:
///   - reachability + auth state reported by the bridge's `codex_probe_result`
///   - the list of models the adapter exposes (e.g. gpt-5.4/high, gpt-5.3-codex/medium)
///   - the user-facing `enableCodexBackend` toggle (AppStorage-backed)
///
/// Mirrors MCPServerManager's singleton + @Published pattern so the existing
/// SettingsPage subsection conventions apply unchanged.
@MainActor
final class CodexBackendManager: ObservableObject {
    static let shared = CodexBackendManager()

    /// User-facing on/off for the Codex backend. When disabled, the picker hides
    /// codex models, no probe is sent, and codex-acp is never spawned by the bridge.
    @Published var enabled: Bool {
        didSet {
            UserDefaults.standard.set(enabled, forKey: Self.enabledKey)
        }
    }

    /// Last probe outcome — nil until first probe completes.
    @Published private(set) var lastProbe: ProbeResult?
    /// True while a probe request is outstanding.
    @Published private(set) var probing: Bool = false
    /// Models reported by the adapter (full list, e.g. 20 entries with effort suffixes).
    @Published private(set) var availableModels: [CodexModel] = []
    /// Default model id reported by the adapter (e.g. "gpt-5.4/high").
    @Published private(set) var currentModelId: String?
    /// "chatgpt" | "api_key" | "none" — derived from ~/.codex/auth.json.
    @Published private(set) var authMode: String = "none"
    /// Last probe error (server-side message). nil on success.
    @Published private(set) var lastError: String?

    static let enabledKey = "fazm.codex.enabled"

    struct CodexModel: Identifiable, Equatable {
        var id: String { modelId }
        let modelId: String
        let name: String
        let description: String?
    }

    struct ProbeResult: Equatable {
        let ok: Bool
        let agent: String?
        let authMethods: [String]
        let authMode: String
        let probedAt: Date
        let error: String?
    }

    private init() {
        self.enabled = UserDefaults.standard.bool(forKey: Self.enabledKey)
    }

    /// Called from ACPBridge's onCodexProbeResult handler.
    func consumeProbeResult(
        ok: Bool,
        agent: String?,
        authMethods: [String],
        currentModelId: String?,
        availableModels rawModels: [[String: Any]],
        authMode: String,
        error: String?
    ) {
        let parsed = rawModels.compactMap { dict -> CodexModel? in
            guard let id = dict["modelId"] as? String,
                  let name = dict["name"] as? String else { return nil }
            return CodexModel(modelId: id, name: name, description: dict["description"] as? String)
        }
        self.availableModels = parsed
        self.currentModelId = currentModelId
        self.authMode = authMode
        self.lastError = error
        self.lastProbe = ProbeResult(
            ok: ok,
            agent: agent,
            authMethods: authMethods,
            authMode: authMode,
            probedAt: Date(),
            error: error
        )
        self.probing = false
    }

    /// Mark a probe as in-flight. Call before sending `codex_init_probe`.
    func markProbing() {
        self.probing = true
    }

    /// Convenience: only return models if the user has enabled the backend AND
    /// the last probe reported reachable. This is what the model picker reads.
    var modelsForPicker: [CodexModel] {
        guard enabled, lastProbe?.ok == true else { return [] }
        return availableModels
    }
}
