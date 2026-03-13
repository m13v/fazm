import Foundation
import IOKit

/// Fetches and caches API keys from the backend for authenticated users.
/// Keys are held in memory only — fetched fresh each app launch.
final class KeyService {
    static let shared = KeyService()

    private(set) var anthropicAPIKey: String?
    private(set) var deepgramAPIKey: String?
    private var hasFetched = false

    private let backendUrl: String
    private let backendSecret: String
    private let deviceId: String

    private init() {
        self.backendUrl = Self.env("FAZM_BACKEND_URL").trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        self.backendSecret = Self.env("FAZM_BACKEND_SECRET")
        self.deviceId = Self.getDeviceId()
    }

    /// Fetch keys from the backend. Safe to call multiple times — only fetches once per launch.
    func fetchKeys() async {
        guard !hasFetched else { return }
        guard !backendUrl.isEmpty, !backendSecret.isEmpty else {
            log("KeyService: missing FAZM_BACKEND_URL or FAZM_BACKEND_SECRET, skipping key fetch")
            return
        }

        do {
            let url = URL(string: "\(backendUrl)/v1/keys")!
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("Bearer \(backendSecret)", forHTTPHeaderField: "Authorization")
            request.setValue(deviceId, forHTTPHeaderField: "X-Device-Id")
            request.timeoutInterval = 15

            let (data, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                let status = (response as? HTTPURLResponse)?.statusCode ?? -1
                let body = String(data: data, encoding: .utf8) ?? ""
                log("KeyService: fetch failed with status \(status): \(body)")
                return
            }

            struct KeysResponse: Decodable {
                let anthropic_api_key: String
                let deepgram_api_key: String
            }

            let keys = try JSONDecoder().decode(KeysResponse.self, from: data)
            if !keys.anthropic_api_key.isEmpty {
                anthropicAPIKey = keys.anthropic_api_key
            }
            if !keys.deepgram_api_key.isEmpty {
                deepgramAPIKey = keys.deepgram_api_key
            }
            hasFetched = true
            log("KeyService: fetched keys (anthropic=\(anthropicAPIKey != nil), deepgram=\(deepgramAPIKey != nil))")
        } catch {
            log("KeyService: fetch error: \(error.localizedDescription)")
        }
    }

    // MARK: - Private Helpers

    private static func env(_ key: String) -> String {
        if let ptr = getenv(key) { return String(cString: ptr) }
        return ""
    }

    private static func getDeviceId() -> String {
        let platformExpert = IOServiceGetMatchingService(
            kIOMainPortDefault,
            IOServiceMatching("IOPlatformExpertDevice")
        )
        guard platformExpert != 0 else { return UUID().uuidString }
        defer { IOObjectRelease(platformExpert) }

        if let uuidCF = IORegistryEntryCreateCFProperty(
            platformExpert, "IOPlatformUUID" as CFString, kCFAllocatorDefault, 0
        )?.takeRetainedValue() as? String {
            return uuidCF
        }
        return UUID().uuidString
    }
}
