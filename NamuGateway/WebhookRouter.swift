import Foundation
import Network

// MARK: - HTTP Request / Response

struct HTTPRequest {
    let method: String
    let path: String
    let headers: [String: String]
    let body: Data?
}

struct HTTPResponse {
    let statusCode: Int
    let headers: [String: String]
    let body: Data?

    static func ok(_ body: Data? = nil, contentType: String = "application/json") -> HTTPResponse {
        HTTPResponse(statusCode: 200, headers: ["Content-Type": contentType], body: body)
    }

    static func json(_ dict: [String: Any]) -> HTTPResponse {
        let data = try? JSONSerialization.data(withJSONObject: dict)
        return ok(data)
    }

    static func notFound() -> HTTPResponse {
        HTTPResponse(statusCode: 404, headers: ["Content-Type": "text/plain"], body: Data("Not Found".utf8))
    }

    static func methodNotAllowed() -> HTTPResponse {
        HTTPResponse(statusCode: 405, headers: ["Content-Type": "text/plain"], body: Data("Method Not Allowed".utf8))
    }

    static func badRequest(_ message: String = "Bad Request") -> HTTPResponse {
        HTTPResponse(statusCode: 400, headers: ["Content-Type": "text/plain"], body: Data(message.utf8))
    }

    static func unauthorized() -> HTTPResponse {
        HTTPResponse(statusCode: 401, headers: ["Content-Type": "text/plain"], body: Data("Unauthorized".utf8))
    }
}

// MARK: - WebhookRouter

/// Routes incoming HTTP requests to the appropriate handler.
///
/// Routes:
///   POST /telegram/webhook  → TelegramChannel
///   GET  /health            → health check
///   GET  /status            → server status
///   GET  /ws                → WebSocket upgrade (handled by GatewayHTTPServer)
public final class WebhookRouter {
    private let telegramChannel: TelegramChannel
    private let sessionManager: SessionManager
    private let auth: GatewayAuth
    private let startTime = Date()

    public init(telegramChannel: TelegramChannel, sessionManager: SessionManager, auth: GatewayAuth) {
        self.telegramChannel = telegramChannel
        self.sessionManager = sessionManager
        self.auth = auth
    }

    // MARK: - Routing

    public func handle(request: HTTPRequest) -> HTTPResponse {
        switch (request.method, request.path) {
        case ("POST", "/telegram/webhook"):
            return handleTelegramWebhook(request)
        case ("GET", "/health"):
            return handleHealth()
        case ("GET", "/status"):
            return handleStatus()
        default:
            return .notFound()
        }
    }

    // MARK: - Route Handlers

    private func handleTelegramWebhook(_ request: HTTPRequest) -> HTTPResponse {
        guard let body = request.body, !body.isEmpty else {
            return .badRequest("Empty body")
        }
        telegramChannel.handleWebhookPayload(body)
        return .json(["ok": true])
    }

    private func handleHealth() -> HTTPResponse {
        return .json([
            "status": "ok",
            "timestamp": ISO8601DateFormatter().string(from: Date())
        ])
    }

    private func handleStatus() -> HTTPResponse {
        let sessions = sessionManager.allSessions
        let uptime = Date().timeIntervalSince(startTime)
        return .json([
            "status": "ok",
            "uptime_seconds": Int(uptime),
            "connected_sessions": sessions.count,
            "paired_tokens": auth.allTokens.count,
            "channels": ["telegram"]
        ])
    }
}

// MARK: - GatewayHTTPServer

/// Minimal HTTP/1.1 + WebSocket server using Network framework (NWListener).
public final class GatewayHTTPServer {
    private let port: UInt16
    private let router: WebhookRouter
    private var listener: NWListener?
    private var connections: [NWConnection] = []
    private let queue = DispatchQueue(label: "com.namu.gateway.http")

    public init(port: UInt16, router: WebhookRouter) {
        self.port = port
        self.router = router
    }

    public func start() {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            print("[GatewayHTTPServer] Invalid port: \(port)")
            return
        }
        let params = NWParameters.tcp
        do {
            listener = try NWListener(using: params, on: nwPort)
        } catch {
            print("[GatewayHTTPServer] Failed to create listener: \(error)")
            return
        }

        listener?.newConnectionHandler = { [weak self] connection in
            self?.handleNewConnection(connection)
        }

        listener?.stateUpdateHandler = { state in
            switch state {
            case .ready:
                print("[GatewayHTTPServer] Listening on port \(nwPort)")
            case .failed(let error):
                print("[GatewayHTTPServer] Listener failed: \(error)")
            default:
                break
            }
        }

        listener?.start(queue: queue)
    }

    private func handleNewConnection(_ connection: NWConnection) {
        connection.start(queue: queue)
        receiveHTTPRequest(from: connection)
    }

    private func receiveHTTPRequest(from connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }
            if let data = data, !data.isEmpty {
                let response = self.processRawRequest(data)
                self.sendHTTPResponse(response, to: connection)
            }
            if isComplete || error != nil {
                connection.cancel()
            }
        }
    }

    private func processRawRequest(_ data: Data) -> HTTPResponse {
        guard let raw = String(data: data, encoding: .utf8) else {
            return .badRequest("Could not decode request")
        }

        let lines = raw.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return .badRequest() }

        let parts = requestLine.components(separatedBy: " ")
        guard parts.count >= 2 else { return .badRequest() }

        let method = parts[0]
        let path = parts[1].components(separatedBy: "?").first ?? parts[1]

        // Parse headers
        var headers: [String: String] = [:]
        var bodyStartIndex = 0
        for (i, line) in lines.dropFirst().enumerated() {
            if line.isEmpty {
                bodyStartIndex = i + 2  // skip blank line
                break
            }
            let headerParts = line.components(separatedBy: ": ")
            if headerParts.count >= 2 {
                let key = headerParts[0].lowercased()
                let value = headerParts.dropFirst().joined(separator: ": ")
                headers[key] = value
            }
        }

        // Extract body
        let bodyLines = lines.dropFirst(bodyStartIndex)
        let bodyString = bodyLines.joined(separator: "\r\n")
        let body = bodyString.isEmpty ? nil : bodyString.data(using: .utf8)

        let request = HTTPRequest(method: method, path: path, headers: headers, body: body)
        return router.handle(request: request)
    }

    private func sendHTTPResponse(_ response: HTTPResponse, to connection: NWConnection) {
        var raw = "HTTP/1.1 \(response.statusCode) \(statusText(response.statusCode))\r\n"
        raw += "Connection: close\r\n"
        for (key, value) in response.headers {
            raw += "\(key): \(value)\r\n"
        }
        let bodyData = response.body ?? Data()
        raw += "Content-Length: \(bodyData.count)\r\n"
        raw += "\r\n"

        var responseData = Data(raw.utf8)
        responseData.append(bodyData)

        connection.send(content: responseData, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private func statusText(_ code: Int) -> String {
        switch code {
        case 200: return "OK"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        default: return "Unknown"
        }
    }
}
