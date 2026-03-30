import Foundation
import IOKit
import AppKit

/// Manages Stripe subscription state — checkout, status polling, and local caching.
final class SubscriptionService {
    static let shared = SubscriptionService()

    private(set) var isActive = false
    private(set) var status = "none" // "active", "trialing", "past_due", "canceled", "none"
    private(set) var currentPeriodEnd: Date?

    private let backendUrl: String
    private let deviceId: String

    private init() {
        self.backendUrl = Self.env("FAZM_BACKEND_URL").trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        self.deviceId = Self.getDeviceId()
    }

    // MARK: - Open Checkout

    /// Creates a Stripe Checkout Session via the backend and opens it in the user's browser.
    func openCheckout() async throws {
        guard !backendUrl.isEmpty else {
            log("SubscriptionService: missing FAZM_BACKEND_URL")
            throw SubscriptionError.notConfigured
        }

        let token = try await AuthService.shared.getIdToken(forceRefresh: false)
        let url = URL(string: "\(backendUrl)/api/stripe/create-checkout-session")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(deviceId, forHTTPHeaderField: "X-Device-Id")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 15

        let body: [String: String] = [
            "success_url": "fazm://subscription/success",
            "cancel_url": "fazm://subscription/cancel",
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1

        guard statusCode == 200 else {
            let msg = String(data: data, encoding: .utf8) ?? ""
            log("SubscriptionService: checkout failed (\(statusCode)): \(msg)")
            throw SubscriptionError.serverError(msg)
        }

        struct CheckoutResponse: Decodable {
            let checkout_url: String
            let session_id: String
        }

        let checkout = try JSONDecoder().decode(CheckoutResponse.self, from: data)
        log("SubscriptionService: opening checkout \(checkout.session_id)")

        if let checkoutURL = URL(string: checkout.checkout_url) {
            await MainActor.run {
                NSWorkspace.shared.open(checkoutURL)
            }
        }
    }

    // MARK: - Check Status

    /// Fetches subscription status from the backend.
    @discardableResult
    func refreshStatus() async -> Bool {
        guard !backendUrl.isEmpty else { return false }

        do {
            let token = try await AuthService.shared.getIdToken(forceRefresh: false)
            let url = URL(string: "\(backendUrl)/api/stripe/subscription-status")!
            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue(deviceId, forHTTPHeaderField: "X-Device-Id")
            request.timeoutInterval = 10

            let (data, response) = try await URLSession.shared.data(for: request)
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1

            guard statusCode == 200 else {
                log("SubscriptionService: status check failed (\(statusCode))")
                return false
            }

            struct StatusResponse: Decodable {
                let active: Bool
                let status: String
                let current_period_end: Int64?
            }

            let result = try JSONDecoder().decode(StatusResponse.self, from: data)
            isActive = result.active
            status = result.status
            if let end = result.current_period_end {
                currentPeriodEnd = Date(timeIntervalSince1970: TimeInterval(end))
            }

            log("SubscriptionService: status=\(result.status) active=\(result.active)")
            return result.active
        } catch {
            log("SubscriptionService: status check error: \(error.localizedDescription)")
            return false
        }
    }

    // MARK: - Errors

    enum SubscriptionError: Error, LocalizedError {
        case notConfigured
        case serverError(String)

        var errorDescription: String? {
            switch self {
            case .notConfigured: return "Subscription service not configured"
            case .serverError(let msg): return "Server error: \(msg)"
            }
        }
    }

    // MARK: - Helpers

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
