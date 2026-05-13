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
    /// True while a ChatGPT OAuth login flow is in progress.
    @Published private(set) var loginInProgress: Bool = false
    /// Error message from the last failed login attempt. nil on success or no attempt.
    @Published private(set) var loginError: String?
    /// Model id the user picked from the dropdown while unauthenticated. After
    /// OAuth completes, ChatProvider promotes this to the active model so the
    /// click-to-connect flow lands on the model the user wanted.
    @Published var pendingPickerModelId: String?
    /// Bumped whenever the user's picker-visibility set changes so SwiftUI views
    /// that read `isModelVisibleInPicker(_:)` re-render.
    @Published private(set) var visibleModelsRevision: Int = 0

    /// UserDefaults key storing the user-curated set of model ids that should
    /// appear in the picker. Absent = use the default `isPickerEligible` rule.
    private static let visibleModelsKey = "codexUserVisibleModelIds"

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

    private init() {}

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

    /// Mark that a Codex login flow has started.
    func markLoginInProgress() {
        self.loginInProgress = true
        self.loginError = nil
    }

    /// Call when the Codex login flow completes successfully.
    func loginCompleted() {
        self.loginInProgress = false
        self.loginError = nil
    }

    /// Call when the Codex login flow fails.
    func loginFailed(error: String) {
        self.loginInProgress = false
        self.loginError = error
    }

    /// Convenience: only return models if the user has enabled the backend AND
    /// the last probe reported reachable. This is what the model picker reads.
    /// Filters via `isModelVisibleInPicker(_:)` — the user can customize the
    /// visible set in Settings > Advanced > AI Chat. By default (no custom
    /// override) we hide older generations (< 5.5) so the picker stays focused
    /// on the current frontier; the raw `availableModels` list remains
    /// available for diagnostics and the Settings UI.
    ///
    /// codex-acp doesn't return a model list when unauthenticated, and the
    /// first probe right after OAuth often comes back with 0 models too while
    /// the adapter warms up. In either case we substitute a known fallback set
    /// so the picker stays populated; once a later probe brings real models,
    /// they take over. The fallback ignores user customization because we
    /// don't know the real catalog yet.
    var modelsForPicker: [CodexModel] {
        guard lastProbe?.ok == true else { return [] }
        if availableModels.isEmpty {
            return Self.fallbackUnauthedGptModels
        }
        return availableModels.filter { isModelVisibleInPicker(modelId: $0.modelId) }
    }

    /// True if the user has saved an explicit picker-visibility selection.
    /// When false, `isModelVisibleInPicker` falls back to the static rule.
    var hasCustomVisibility: Bool {
        UserDefaults.standard.object(forKey: Self.visibleModelsKey) != nil
    }

    /// The user's explicit visible-model set, or nil if they haven't customized.
    private var userVisibleModelIds: Set<String>? {
        guard let arr = UserDefaults.standard.array(forKey: Self.visibleModelsKey) as? [String] else { return nil }
        return Set(arr)
    }

    /// Whether a given model id should appear in the picker. Honors the user's
    /// override if present, otherwise applies the default frontier rule.
    func isModelVisibleInPicker(modelId: String) -> Bool {
        if let custom = userVisibleModelIds { return custom.contains(modelId) }
        return Self.isPickerEligible(modelId: modelId)
    }

    /// Toggle a model's visibility in the picker. Seeds the user set from the
    /// current eligible-by-default models on first use, so flipping one switch
    /// doesn't accidentally hide everything else. Triggers a refresh of the
    /// merged model list so the floating-bar picker updates immediately.
    func setModelVisible(_ modelId: String, visible: Bool) {
        var set = userVisibleModelIds ?? Set(availableModels.map(\.modelId).filter { Self.isPickerEligible(modelId: $0) })
        if visible { set.insert(modelId) } else { set.remove(modelId) }
        UserDefaults.standard.set(Array(set).sorted(), forKey: Self.visibleModelsKey)
        visibleModelsRevision &+= 1
        ShortcutSettings.shared.updateCodexModels(modelsForPicker)
    }

    /// Clear the user override so the default rule (gpt-5.5+) applies again.
    func resetVisibilityToDefault() {
        UserDefaults.standard.removeObject(forKey: Self.visibleModelsKey)
        visibleModelsRevision &+= 1
        ShortcutSettings.shared.updateCodexModels(modelsForPicker)
    }

    /// Stand-in GPT-5.5 list shown in the picker before the user connects their
    /// ChatGPT subscription. Mirrors the variants codex-acp returns post-auth.
    /// Update if codex-acp ships a newer frontier generation as the default.
    static let fallbackUnauthedGptModels: [CodexModel] = [
        CodexModel(modelId: "gpt-5.5/low", name: "GPT-5.5 (low)", description: nil),
        CodexModel(modelId: "gpt-5.5/medium", name: "GPT-5.5 (medium)", description: nil),
        CodexModel(modelId: "gpt-5.5/high", name: "GPT-5.5 (high)", description: nil),
        CodexModel(modelId: "gpt-5.5/xhigh", name: "GPT-5.5 (xhigh)", description: nil),
    ]

    /// Returns true when the modelId belongs to the current frontier generation
    /// the picker should expose (gpt-5.5 or newer). Older generations like
    /// gpt-5.4, gpt-5.3-codex, gpt-5.2 are hidden once a newer generation works.
    /// Inputs look like "gpt-5.5/high", "gpt-5.4-mini/low", "gpt-5.3-codex/high".
    static func isPickerEligible(modelId: String) -> Bool {
        let family = modelId.split(separator: "/").first.map(String.init) ?? modelId
        // Strip variant suffixes ("-mini", "-codex") so we only compare base version
        let base = family.split(separator: "-").prefix(2).joined(separator: "-")
        // base is "gpt-5.5", "gpt-5.4", etc. Extract major.minor.
        guard base.hasPrefix("gpt-") else { return false }
        let version = String(base.dropFirst("gpt-".count))
        let parts = version.split(separator: ".")
        guard parts.count == 2,
              let major = Int(parts[0]),
              let minor = Int(parts[1]) else { return false }
        // Keep gpt-5.5 and newer (e.g. 5.5, 5.6, 6.0)
        if major > 5 { return true }
        if major == 5 && minor >= 5 { return true }
        return false
    }
}
