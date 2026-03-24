import Foundation
import Network

/// Runs a local WebSocket server and a Cloudflare tunnel so that a phone/web
/// client can send chat queries to the desktop app remotely.
///
/// Flow:
/// 1. Start a NWListener on a random port
/// 2. Launch `cloudflared tunnel --url http://localhost:<port>` to expose it
/// 3. Register the tunnel URL with the backend (`/api/relay/register`)
/// 4. Accept WebSocket connections, validate Firebase token, relay messages
@MainActor
final class WebRelay: ObservableObject {

    // MARK: - State

    @Published private(set) var tunnelUrl: String?
    @Published private(set) var isPhoneConnected = false

    private var listener: NWListener?
    private var activeConnection: NWConnection?
    private var cloudflaredProcess: Process?
    private var localPort: UInt16 = 0

    /// Callback: a query arrived from the phone. Parameters: text, sessionKey
    var onQuery: ((String, String) async -> Void)?

    /// Callback: phone requested chat history
    var onHistoryRequest: (() async -> [[String: Any]])?

    // MARK: - Lifecycle

    func start() {
        startListener()
    }

    func stop() {
        unregisterTunnel()
        cloudflaredProcess?.terminate()
        cloudflaredProcess = nil
        listener?.cancel()
        listener = nil
        activeConnection?.cancel()
        activeConnection = nil
        tunnelUrl = nil
        isPhoneConnected = false
    }

    // MARK: - Local WebSocket Server

    private func startListener() {
        let params = NWParameters.tcp
        let wsOptions = NWProtocolWebSocket.Options()
        params.defaultProtocolStack.applicationProtocols.insert(wsOptions, at: 0)

        do {
            // Port 0 = system picks a random available port
            listener = try NWListener(using: params, on: .any)
        } catch {
            logError("WebRelay: failed to create listener", error: error)
            return
        }

        listener?.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                switch state {
                case .ready:
                    if let port = self?.listener?.port?.rawValue {
                        self?.localPort = port
                        log("WebRelay: listening on port \(port)")
                        self?.startCloudflared(port: port)
                    }
                case .failed(let error):
                    logError("WebRelay: listener failed", error: error)
                default:
                    break
                }
            }
        }

        listener?.newConnectionHandler = { [weak self] connection in
            Task { @MainActor in
                self?.handleNewConnection(connection)
            }
        }

        listener?.start(queue: .main)
    }

    private func handleNewConnection(_ connection: NWConnection) {
        // Only allow one connection at a time (latest wins)
        activeConnection?.cancel()
        activeConnection = connection
        isPhoneConnected = true
        log("WebRelay: phone connected")

        connection.stateUpdateHandler = { [weak self] state in
            if case .failed(_) = state {
                Task { @MainActor in
                    self?.connectionClosed(connection)
                }
            } else if case .cancelled = state {
                Task { @MainActor in
                    self?.connectionClosed(connection)
                }
            }
        }

        receiveMessage(on: connection)
    }

    private func connectionClosed(_ connection: NWConnection) {
        if activeConnection === connection {
            activeConnection = nil
            isPhoneConnected = false
            log("WebRelay: phone disconnected")
        }
    }

    private func receiveMessage(on connection: NWConnection) {
        connection.receiveMessage { [weak self] content, context, isComplete, error in
            guard let self else { return }
            if let error {
                log("WebRelay: receive error: \(error)")
                return
            }

            if let data = content,
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let type = json["type"] as? String {
                Task { @MainActor in
                    await self.handleIncomingMessage(type: type, json: json)
                }
            }

            // Keep receiving
            if connection.state == .ready {
                Task { @MainActor in
                    self.receiveMessage(on: connection)
                }
            }
        }
    }

    private func handleIncomingMessage(type: String, json: [String: Any]) async {
        switch type {
        case "send_message":
            let text = json["text"] as? String ?? ""
            let sessionKey = json["sessionKey"] as? String ?? "main"
            guard !text.isEmpty else { return }

            // Notify the phone that query started
            sendToPhone(["type": "query_started"])

            // Process through ChatProvider
            await onQuery?(text, sessionKey)

        case "request_history":
            if let history = await onHistoryRequest?() {
                sendToPhone(["type": "chat_history", "messages": history])
            }

        default:
            log("WebRelay: unknown message type: \(type)")
        }
    }

    // MARK: - Send to phone

    func sendToPhone(_ json: [String: Any]) {
        guard let connection = activeConnection, connection.state == .ready else { return }

        guard let data = try? JSONSerialization.data(withJSONObject: json) else { return }

        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "ws", metadata: [metadata])

        connection.send(content: data, contentContext: context, isComplete: true, completion: .contentProcessed { error in
            if let error {
                log("WebRelay: send error: \(error)")
            }
        })
    }

    // MARK: - Cloudflared Tunnel

    private func startCloudflared(port: UInt16) {
        // Look for cloudflared in common locations
        let paths = [
            "/opt/homebrew/bin/cloudflared",
            "/usr/local/bin/cloudflared",
            "/usr/bin/cloudflared",
        ]

        guard let binary = paths.first(where: { FileManager.default.fileExists(atPath: $0) }) else {
            log("WebRelay: cloudflared not found, skipping tunnel")
            return
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = ["tunnel", "--url", "http://localhost:\(port)"]

        let pipe = Pipe()
        process.standardError = pipe // cloudflared logs to stderr

        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let output = String(data: data, encoding: .utf8) else { return }

            // Parse tunnel URL from cloudflared output
            // It prints something like: "https://xxxxx.trycloudflare.com"
            if let range = output.range(of: "https://[a-z0-9-]+\\.trycloudflare\\.com", options: .regularExpression) {
                let url = String(output[range])
                Task { @MainActor in
                    self?.tunnelUrl = url
                    log("WebRelay: tunnel URL = \(url)")
                    self?.registerTunnel(url: url)
                }
            }
        }

        do {
            try process.run()
            cloudflaredProcess = process
            log("WebRelay: cloudflared started")
        } catch {
            logError("WebRelay: failed to start cloudflared", error: error)
        }
    }

    // MARK: - Backend Registration

    private func registerTunnel(url: String) {
        guard let backendUrl = ProcessInfo.processInfo.environment["FAZM_BACKEND_URL"],
              let token = AuthService.shared.idToken else {
            log("WebRelay: missing backend URL or auth token, skipping registration")
            return
        }

        let endpoint = "\(backendUrl)/api/relay/register"
        var request = URLRequest(url: URL(string: endpoint)!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: String] = ["tunnel_url": url]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        URLSession.shared.dataTask(with: request) { _, response, error in
            if let error {
                logError("WebRelay: register failed", error: error)
            } else if let http = response as? HTTPURLResponse, http.statusCode == 200 {
                log("WebRelay: tunnel registered with backend")
            } else {
                log("WebRelay: register got status \((response as? HTTPURLResponse)?.statusCode ?? 0)")
            }
        }.resume()
    }

    private func unregisterTunnel() {
        guard let backendUrl = ProcessInfo.processInfo.environment["FAZM_BACKEND_URL"],
              let token = AuthService.shared.idToken else { return }

        let endpoint = "\(backendUrl)/api/relay/unregister"
        var request = URLRequest(url: URL(string: endpoint)!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        URLSession.shared.dataTask(with: request) { _, _, _ in }.resume()
    }
}
