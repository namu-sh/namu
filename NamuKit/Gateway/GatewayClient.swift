import Foundation
import Combine
import CryptoKit

// MARK: - GatewayClientState

enum GatewayClientState: Equatable, Sendable {
    case disconnected
    case connecting
    case connected
    case reconnecting(attempt: Int)
}

// MARK: - GatewayClientDelegate

protocol GatewayClientDelegate: AnyObject, Sendable {
    func gatewayClient(_ client: GatewayClient, didReceive message: InboundMessage)
    func gatewayClient(_ client: GatewayClient, didChangeState state: GatewayClientState)
}

// MARK: - GatewayClient

/// WebSocket client that connects to the Namu Gateway server.
///
/// Responsibilities:
///   - Authenticate with a pairing token on connect
///   - Validate inbound message signatures with HMAC-SHA256
///   - Auto-reconnect with exponential backoff (1 s → 60 s)
///   - Send `AlertMessage` payloads to the gateway
///   - Deliver inbound commands to the registered delegate
@MainActor
final class GatewayClient: ObservableObject {

    // MARK: - Published state

    @Published private(set) var connectionState: GatewayClientState = .disconnected

    // MARK: - Configuration

    struct Configuration: Sendable {
        let serverURL: URL
        let pairingToken: String
        let hmacSecret: String
        var reconnectBaseInterval: TimeInterval = 1
        var reconnectMaxInterval: TimeInterval = 60
    }

    // MARK: - Dependencies

    private let config: Configuration
    weak var delegate: (any GatewayClientDelegate)?

    // MARK: - WebSocket state

    private var webSocketTask: URLSessionWebSocketTask?
    private var urlSession: URLSession?
    private var reconnectAttempt = 0
    private var reconnectTask: Task<Void, Never>?
    private var receiveTask: Task<Void, Never>?
    private var isIntentionallyStopped = false

    // MARK: - JSON coder

    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    // MARK: - Init

    init(configuration: Configuration) {
        self.config = configuration
    }

    // MARK: - Lifecycle

    func connect() {
        isIntentionallyStopped = false
        reconnectAttempt = 0
        openConnection()
    }

    func disconnect() {
        isIntentionallyStopped = true
        cancelReconnect()
        closeConnection(code: .normalClosure)
        connectionState = .disconnected
    }

    // MARK: - Send alert

    /// Encode and send a `FiredAlert` to the gateway as an `AlertMessage`.
    func send(alert: FiredAlert) {
        let msg = AlertMessage(
            ruleName: alert.rule.name,
            event: alert.event.rawValue,
            summary: "\(alert.rule.name) fired for \(alert.event.rawValue)",
            workspaceID: alert.rule.workspaceID?.uuidString,
            firedAt: alert.firedAt,
            source: .telegram
        )

        guard let data = try? encoder.encode(msg) else {
            print("[GatewayClient] Failed to encode AlertMessage")
            return
        }

        sendRaw(data)
    }

    // MARK: - Private: Connection management

    private func openConnection() {
        connectionState = .connecting

        var request = URLRequest(url: config.serverURL)
        request.setValue("Bearer \(config.pairingToken)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 10

        let session = URLSession(configuration: .default)
        urlSession = session
        let task = session.webSocketTask(with: request)
        webSocketTask = task
        task.resume()

        reconnectAttempt = 0

        startReceiving()
    }

    private func closeConnection(code: URLSessionWebSocketTask.CloseCode) {
        receiveTask?.cancel()
        receiveTask = nil
        webSocketTask?.cancel(with: code, reason: nil)
        webSocketTask = nil
        urlSession?.invalidateAndCancel()
        urlSession = nil
    }

    private func startReceiving() {
        receiveTask?.cancel()
        receiveTask = Task { [weak self] in
            guard let self else { return }
            await self.receiveLoop()
        }
    }

    private func receiveLoop() async {
        var firstReceive = true
        while !Task.isCancelled {
            guard let task = webSocketTask else { break }
            do {
                let message = try await task.receive()
                if firstReceive {
                    firstReceive = false
                    connectionState = .connected
                    delegate?.gatewayClient(self, didChangeState: .connected)
                }
                handleReceived(message)
            } catch {
                guard !isIntentionallyStopped else { break }
                print("[GatewayClient] Receive error: \(error.localizedDescription)")
                scheduleReconnect()
                break
            }
        }
    }

    // MARK: - Private: Message handling

    private func handleReceived(_ message: URLSessionWebSocketTask.Message) {
        let data: Data
        switch message {
        case .data(let d):   data = d
        case .string(let s): data = Data(s.utf8)
        @unknown default:    return
        }

        // Validate HMAC signature before processing.
        guard validateSignature(for: data) else {
            print("[GatewayClient] HMAC validation failed — dropping message")
            return
        }

        do {
            let inbound = try decoder.decode(InboundMessage.self, from: data)

            // Respond to ping with pong immediately.
            if inbound.type == .ping {
                sendPong()
                return
            }

            delegate?.gatewayClient(self, didReceive: inbound)
        } catch {
            print("[GatewayClient] Failed to decode InboundMessage: \(error)")
        }
    }

    // MARK: - Private: HMAC signature validation

    /// Validates X-Namu-Signature header against the message body.
    /// The gateway server must include `X-Namu-Signature: <hex-HMAC-SHA256>` as a
    /// JSON field `"signature"` in the envelope, or as a wrapper object.
    ///
    private func validateSignature(for data: Data) -> Bool {
        guard let secret = config.hmacSecret.data(using: .utf8) else { return false }

        // Try to extract a wrapped envelope with "signature" and "body".
        if let envelope = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let signatureHex = envelope["signature"] as? String,
           let bodyString = envelope["body"] as? String,
           let bodyData = bodyString.data(using: .utf8) {
            let key = SymmetricKey(data: secret)
            let mac = HMAC<SHA256>.authenticationCode(for: bodyData, using: key)
            let expected = Data(mac).map { String(format: "%02x", $0) }.joined()
            return expected == signatureHex
        }

        // If no signature envelope is present, reject the message — signatures are required.
        return false
    }

    // MARK: - Private: Sending

    private func sendRaw(_ data: Data) {
        guard let task = webSocketTask, connectionState == .connected else {
            print("[GatewayClient] Cannot send — not connected")
            return
        }
        task.send(.data(data)) { error in
            if let error {
                print("[GatewayClient] Send error: \(error.localizedDescription)")
            }
        }
    }

    private func sendPong() {
        let pong = ["type": "pong", "timestamp": ISO8601DateFormatter().string(from: Date())]
        guard let data = try? JSONSerialization.data(withJSONObject: pong) else { return }
        sendRaw(data)
    }

    // MARK: - Private: Reconnect with exponential backoff

    private func scheduleReconnect() {
        guard !isIntentionallyStopped else { return }

        reconnectAttempt += 1
        let delay = min(
            config.reconnectBaseInterval * pow(2.0, Double(reconnectAttempt - 1)),
            config.reconnectMaxInterval
        )

        connectionState = .reconnecting(attempt: reconnectAttempt)
        delegate?.gatewayClient(self, didChangeState: .reconnecting(attempt: reconnectAttempt))

        print("[GatewayClient] Reconnecting in \(delay)s (attempt \(reconnectAttempt))")

        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled, !self.isIntentionallyStopped else { return }
            await MainActor.run {
                self.closeConnection(code: .abnormalClosure)
                self.openConnection()
            }
        }
    }

    private func cancelReconnect() {
        reconnectTask?.cancel()
        reconnectTask = nil
    }
}
