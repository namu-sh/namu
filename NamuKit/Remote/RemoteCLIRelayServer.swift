import Foundation
import Network
import CryptoKit

/// HMAC-SHA256 authenticated TCP relay server that forwards CLI commands
/// arriving over TCP to the local namu IPC Unix domain socket.
///
/// ## Protocol
/// 1. Server listens on loopback TCP (port auto-assigned by default).
/// 2. On connect, server sends a JSON challenge line.
/// 3. Client responds with a JSON auth line containing an HMAC-SHA256 MAC.
/// 4. After successful auth, client sends one JSON command line.
/// 5. Server forwards the command to the local namu socket, returns the
///    response, then closes the connection.
final class RemoteCLIRelayServer {

    // MARK: - Session

    private final class Session {
        private enum Phase {
            case awaitingAuth
            case awaitingCommand
            case forwarding
            case closed
        }

        private let connection: NWConnection
        private let localSocketPath: String
        private let relayID: String
        private let relayToken: Data
        private let queue: DispatchQueue
        private let onClose: () -> Void
        private let challengeProtocol = "namu-relay-auth"
        private let challengeVersion = 1
        private let minimumFailureDelay: TimeInterval = 0.05
        private let maximumFrameBytes = 64 * 1024

        private var buffer = Data()
        private var phase: Phase = .awaitingAuth
        private var challengeNonce = ""
        private var challengeSentAt = Date()
        private var isClosed = false

        init(
            connection: NWConnection,
            localSocketPath: String,
            relayID: String,
            relayToken: Data,
            queue: DispatchQueue,
            onClose: @escaping () -> Void
        ) {
            self.connection = connection
            self.localSocketPath = localSocketPath
            self.relayID = relayID
            self.relayToken = relayToken
            self.queue = queue
            self.onClose = onClose
        }

        func start() {
            connection.stateUpdateHandler = { [weak self] state in
                self?.queue.async {
                    self?.handleState(state)
                }
            }
            connection.start(queue: queue)
        }

        func stop() {
            close()
        }

        // MARK: - State handling

        private func handleState(_ state: NWConnection.State) {
            guard !isClosed else { return }
            switch state {
            case .ready:
                sendChallenge()
                receive()
            case .failed, .cancelled:
                close()
            default:
                break
            }
        }

        // MARK: - Challenge

        private func sendChallenge() {
            challengeSentAt = Date()
            guard let nonce = try? Self.randomHex(16) else {
                sendFailureAndClose()
                return
            }
            challengeNonce = nonce
            let challenge: [String: Any] = [
                "protocol": challengeProtocol,
                "version": challengeVersion,
                "relay_id": relayID,
                "nonce": challengeNonce,
            ]
            sendJSONLine(challenge) { _ in }
        }

        // MARK: - Receive loop

        private func receive() {
            guard !isClosed else { return }
            connection.receive(minimumIncompleteLength: 1, maximumLength: maximumFrameBytes) { [weak self] data, _, isComplete, error in
                guard let self else { return }
                self.queue.async {
                    if error != nil {
                        self.close()
                        return
                    }
                    if let data, !data.isEmpty {
                        self.buffer.append(data)
                        if self.buffer.count > self.maximumFrameBytes {
                            self.sendFailureAndClose()
                            return
                        }
                        self.processBufferedLines()
                    }
                    if isComplete {
                        self.close()
                        return
                    }
                    if !self.isClosed {
                        self.receive()
                    }
                }
            }
        }

        // MARK: - Line processing

        private func processBufferedLines() {
            while let newlineIndex = buffer.firstIndex(of: 0x0A), !isClosed {
                let lineData = buffer.prefix(upTo: newlineIndex)
                buffer.removeSubrange(...newlineIndex)
                let line = String(data: lineData, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                switch phase {
                case .awaitingAuth:
                    handleAuthLine(line)
                case .awaitingCommand:
                    handleCommandLine(Data(lineData) + Data([0x0A]))
                case .forwarding, .closed:
                    return
                }
            }
        }

        // MARK: - Auth

        private func handleAuthLine(_ line: String) {
            guard let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let receivedRelayID = object["relay_id"] as? String,
                  receivedRelayID == relayID,
                  let macHex = object["mac"] as? String,
                  let receivedMAC = Self.hexToData(macHex)
            else {
                sendFailureAndClose()
                return
            }

            let message = Self.authMessage(relayID: relayID, nonce: challengeNonce, version: challengeVersion)
            guard Self.verifyMAC(receivedMAC: receivedMAC, message: message, token: relayToken) else {
                sendFailureAndClose()
                return
            }

            phase = .awaitingCommand
            sendJSONLine(["ok": true]) { [weak self] _ in
                self?.queue.async {
                    self?.processBufferedLines()
                }
            }
        }

        // MARK: - Command forwarding

        private func handleCommandLine(_ commandLine: Data) {
            guard !commandLine.isEmpty else {
                sendFailureAndClose()
                return
            }
            phase = .forwarding
            DispatchQueue.global(qos: .utility).async { [localSocketPath, commandLine, queue] in
                let result = Result { try Self.roundTripUnixSocket(socketPath: localSocketPath, request: commandLine) }
                queue.async { [weak self] in
                    guard let self else { return }
                    switch result {
                    case .success(let response):
                        self.connection.send(content: response, completion: .contentProcessed { [weak self] _ in
                            self?.queue.async {
                                self?.close()
                            }
                        })
                    case .failure:
                        self.sendFailureAndClose()
                    }
                }
            }
        }

        // MARK: - Failure / close

        private func sendFailureAndClose() {
            let elapsed = Date().timeIntervalSince(challengeSentAt)
            let delay = max(0, minimumFailureDelay - elapsed)
            phase = .closed
            queue.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.sendJSONLine(["ok": false]) { [weak self] _ in
                    self?.queue.async {
                        self?.close()
                    }
                }
            }
        }

        private func sendJSONLine(_ object: [String: Any], completion: @escaping (NWError?) -> Void) {
            guard !isClosed else {
                completion(nil)
                return
            }
            guard let payload = try? JSONSerialization.data(withJSONObject: object) else {
                completion(nil)
                return
            }
            connection.send(content: payload + Data([0x0A]), completion: .contentProcessed(completion))
        }

        private func close() {
            guard !isClosed else { return }
            isClosed = true
            phase = .closed
            connection.stateUpdateHandler = nil
            connection.cancel()
            onClose()
        }

        // MARK: - Crypto helpers

        private static func authMessage(relayID: String, nonce: String, version: Int) -> Data {
            Data("relay_id=\(relayID)\nnonce=\(nonce)\nversion=\(version)".utf8)
        }

        private static func verifyMAC(receivedMAC: Data, message: Data, token: Data) -> Bool {
            let key = SymmetricKey(data: token)
            return HMAC<SHA256>.isValidAuthenticationCode(receivedMAC, authenticating: message, using: key)
        }

        // MARK: - Hex / random helpers

        fileprivate static func hexToData(_ hex: String) -> Data? {
            let normalized = hex.trimmingCharacters(in: .whitespacesAndNewlines)
            guard normalized.count.isMultiple(of: 2), !normalized.isEmpty else { return nil }
            var data = Data(capacity: normalized.count / 2)
            var cursor = normalized.startIndex
            while cursor < normalized.endIndex {
                let next = normalized.index(cursor, offsetBy: 2)
                guard let byte = UInt8(normalized[cursor..<next], radix: 16) else { return nil }
                data.append(byte)
                cursor = next
            }
            return data
        }

        fileprivate static func randomHex(_ byteCount: Int) throws -> String {
            var bytes = [UInt8](repeating: 0, count: byteCount)
            guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
                throw NSError(domain: "namu.remote.relay", code: 31, userInfo: [
                    NSLocalizedDescriptionKey: "System random number generator failed",
                ])
            }
            return bytes.map { String(format: "%02x", $0) }.joined()
        }

        // MARK: - Unix socket round-trip

        private static let maximumResponseBytes = 1024 * 1024  // 1 MB

        private static func roundTripUnixSocket(socketPath: String, request: Data) throws -> Data {
            let fd = socket(AF_UNIX, SOCK_STREAM, 0)
            guard fd >= 0 else {
                throw NSError(domain: "namu.remote.relay", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: "failed to create local relay socket",
                ])
            }
            defer { Darwin.close(fd) }

            var timeout = timeval(tv_sec: 15, tv_usec: 0)
            withUnsafePointer(to: &timeout) { pointer in
                _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, pointer, socklen_t(MemoryLayout<timeval>.size))
                _ = setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, pointer, socklen_t(MemoryLayout<timeval>.size))
            }

            var address = sockaddr_un()
            address.sun_family = sa_family_t(AF_UNIX)
            let pathBytes = Array(socketPath.utf8CString)
            guard pathBytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
                throw NSError(domain: "namu.remote.relay", code: 2, userInfo: [
                    NSLocalizedDescriptionKey: "local relay socket path is too long",
                ])
            }
            let sunPathOffset = MemoryLayout<sockaddr_un>.offset(of: \.sun_path) ?? 0
            withUnsafeMutableBytes(of: &address) { rawBuffer in
                let destination = rawBuffer.baseAddress!.advanced(by: sunPathOffset)
                pathBytes.withUnsafeBytes { pathBuffer in
                    destination.copyMemory(from: pathBuffer.baseAddress!, byteCount: pathBytes.count)
                }
            }

            let addressLength = socklen_t(MemoryLayout.size(ofValue: address.sun_family) + pathBytes.count)
            let connectResult = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(fd, $0, addressLength)
                }
            }
            guard connectResult == 0 else {
                throw NSError(domain: "namu.remote.relay", code: 3, userInfo: [
                    NSLocalizedDescriptionKey: "failed to connect to local namu socket",
                ])
            }

            try request.withUnsafeBytes { rawBuffer in
                guard let baseAddress = rawBuffer.bindMemory(to: UInt8.self).baseAddress else { return }
                var bytesRemaining = rawBuffer.count
                var pointer = baseAddress
                while bytesRemaining > 0 {
                    let written = Darwin.write(fd, pointer, bytesRemaining)
                    if written <= 0 {
                        throw NSError(domain: "namu.remote.relay", code: 4, userInfo: [
                            NSLocalizedDescriptionKey: "failed to write relay request",
                        ])
                    }
                    bytesRemaining -= written
                    pointer = pointer.advanced(by: written)
                }
            }
            _ = shutdown(fd, SHUT_WR)

            var response = Data()
            var scratch = [UInt8](repeating: 0, count: 4096)
            while true {
                let count = Darwin.read(fd, &scratch, scratch.count)
                if count > 0 {
                    response.append(contentsOf: scratch.prefix(count))
                    if response.count > Self.maximumResponseBytes {
                        throw NSError(domain: "namu.remote.relay", code: 7, userInfo: [
                            NSLocalizedDescriptionKey: "local namu response exceeded maximum size",
                        ])
                    }
                    continue
                }
                if count == 0 {
                    break
                }
                if errno == EAGAIN || errno == EWOULDBLOCK {
                    if !response.isEmpty {
                        break
                    }
                    throw NSError(domain: "namu.remote.relay", code: 5, userInfo: [
                        NSLocalizedDescriptionKey: "timed out waiting for local namu response",
                    ])
                }
                throw NSError(domain: "namu.remote.relay", code: 6, userInfo: [
                    NSLocalizedDescriptionKey: "failed to read local namu response",
                ])
            }
            return response
        }
    }

    // MARK: - Public API

    /// Hex-encoded relay identifier, stable for the lifetime of this server instance.
    let relayID: String

    /// Hex-encoded shared secret used to authenticate relay clients.
    let relayToken: String

    private let localSocketPath: String
    private let relayTokenData: Data
    private let queue = DispatchQueue(
        label: "com.namu.remote-ssh.relay-server.\(UUID().uuidString)",
        qos: .utility
    )

    private var listener: NWListener?
    private var sessions: [UUID: Session] = [:]
    private var isStopped = false
    private var localPort: Int?

    init(localSocketPath: String, relayID: String, relayTokenHex: String) throws {
        guard let tokenData = Session.hexToData(relayTokenHex) else {
            throw NSError(domain: "namu.remote.relay", code: 30, userInfo: [
                NSLocalizedDescriptionKey: "Invalid relay token hex: must be even-length hex string",
            ])
        }
        self.localSocketPath = localSocketPath
        self.relayID = relayID
        self.relayToken = relayTokenHex
        self.relayTokenData = tokenData
    }

    /// Starts the listener and returns the allocated TCP port.
    ///
    /// - Parameter port: Port to bind. Pass `0` (default) for auto-assignment.
    /// - Returns: The bound port number.
    @discardableResult
    func start(port: Int = 0) throws -> Int {
        if let existingPort = queue.sync(execute: { localPort }) {
            return existingPort
        }

        let listener = try Self.makeLoopbackListener(port: port)
        let readySemaphore = DispatchSemaphore(value: 0)
        let stateLock = NSLock()
        var capturedError: Error?
        var boundPort: Int?

        listener.newConnectionHandler = { [weak self] connection in
            self?.queue.async {
                self?.acceptConnection(connection)
            }
        }
        listener.stateUpdateHandler = { listenerState in
            switch listenerState {
            case .ready:
                stateLock.lock()
                boundPort = listener.port.map { Int($0.rawValue) }
                stateLock.unlock()
                readySemaphore.signal()
            case .failed(let error):
                stateLock.lock()
                capturedError = error
                stateLock.unlock()
                readySemaphore.signal()
            default:
                break
            }
        }
        listener.start(queue: queue)

        let waitResult = readySemaphore.wait(timeout: .now() + 5.0)
        stateLock.lock()
        let startupError = capturedError
        let startupPortValue = boundPort
        stateLock.unlock()

        if waitResult != .success {
            listener.newConnectionHandler = nil
            listener.stateUpdateHandler = nil
            listener.cancel()
            throw NSError(domain: "namu.remote.relay", code: 8, userInfo: [
                NSLocalizedDescriptionKey: "timed out waiting for local relay listener",
            ])
        }
        if let startupError {
            listener.newConnectionHandler = nil
            listener.stateUpdateHandler = nil
            listener.cancel()
            throw startupError
        }
        guard let startupPortValue, startupPortValue > 0 else {
            listener.newConnectionHandler = nil
            listener.stateUpdateHandler = nil
            listener.cancel()
            throw NSError(domain: "namu.remote.relay", code: 8, userInfo: [
                NSLocalizedDescriptionKey: "failed to bind local relay listener",
            ])
        }

        return queue.sync {
            if let localPort {
                listener.newConnectionHandler = nil
                listener.stateUpdateHandler = nil
                listener.cancel()
                return localPort
            }
            self.listener = listener
            self.localPort = startupPortValue
            return startupPortValue
        }
    }

    func stop() {
        queue.sync {
            guard !isStopped else { return }
            isStopped = true
            listener?.newConnectionHandler = nil
            listener?.stateUpdateHandler = nil
            listener?.cancel()
            listener = nil
            localPort = nil
            let activeSessions = sessions.values
            sessions.removeAll()
            for session in activeSessions {
                session.stop()
            }
        }
    }

    // MARK: - Connection acceptance

    private func acceptConnection(_ connection: NWConnection) {
        guard !isStopped else {
            connection.cancel()
            return
        }
        let sessionID = UUID()
        let session = Session(
            connection: connection,
            localSocketPath: localSocketPath,
            relayID: relayID,
            relayToken: relayTokenData,
            queue: queue
        ) { [weak self] in
            self?.sessions.removeValue(forKey: sessionID)
        }
        sessions[sessionID] = session
        session.start()
    }

    // MARK: - Listener factory

    private static func makeLoopbackListener(port: Int) throws -> NWListener {
        let tcpOptions = NWProtocolTCP.Options()
        tcpOptions.noDelay = true
        let parameters = NWParameters(tls: nil, tcp: tcpOptions)
        parameters.allowLocalEndpointReuse = true
        let nwPort: NWEndpoint.Port = port == 0 ? .any : NWEndpoint.Port(rawValue: UInt16(port)) ?? .any
        parameters.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host("127.0.0.1"), port: nwPort)
        return try NWListener(using: parameters)
    }
}
