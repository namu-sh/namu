import Foundation
import CommonCrypto

/// TCP relay server with HMAC-SHA256 challenge-response authentication.
/// Proxies authenticated JSON-RPC requests to the local CommandDispatcher.
final class RelayServer: @unchecked Sendable {

    // MARK: - Configuration

    struct Config: Sendable {
        /// TCP port to listen on. 0 = auto-assign.
        var port: UInt16 = 0
        /// Backlog for listen(2).
        var listenBacklog: Int32 = 32
        /// Per-client read/write timeout.
        var clientTimeout: TimeInterval = 30
        /// Path to the shared secret file.
        var secretPath: String = {
            let appSupport = FileManager.default.urls(
                for: .applicationSupportDirectory, in: .userDomainMask
            ).first?.path ?? NSHomeDirectory()
            return (appSupport as NSString).appendingPathComponent("Namu/relay-secret")
        }()
    }

    // MARK: - Dependencies

    private let config: Config
    private let dispatcher: CommandDispatcher

    // MARK: - State

    private let stateLock = NSLock()
    private var serverFD: Int32 = -1
    private var isRunning = false
    private var boundPort: UInt16 = 0
    private var acceptLoopGeneration: UInt64 = 0

    private let clientsLock = NSLock()
    private var clientFDs: Set<Int32> = []

    // MARK: - Init

    init(config: Config = Config(), dispatcher: CommandDispatcher) {
        self.config = config
        self.dispatcher = dispatcher
    }

    // MARK: - Start / Stop

    func start() throws {
        signal(SIGPIPE, SIG_IGN)
        try stateLock.withLock {
            guard !isRunning else { return }

            let fd = socket(AF_INET, SOCK_STREAM, 0)
            guard fd >= 0 else {
                throw RelayServerError.socketCreate(errno)
            }

            // SO_REUSEADDR
            var one: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))

            var addr = sockaddr_in()
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = in_port_t(config.port).bigEndian
            addr.sin_addr = in_addr(s_addr: INADDR_ANY)

            let bindResult = withUnsafePointer(to: &addr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            guard bindResult == 0 else {
                let code = errno
                Darwin.close(fd)
                throw RelayServerError.bind(errno: code)
            }

            guard Darwin.listen(fd, config.listenBacklog) == 0 else {
                let code = errno
                Darwin.close(fd)
                throw RelayServerError.listen(code)
            }

            // Read back the assigned port
            var assignedAddr = sockaddr_in()
            var addrLen = socklen_t(MemoryLayout<sockaddr_in>.size)
            withUnsafeMutablePointer(to: &assignedAddr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                    _ = getsockname(fd, sockPtr, &addrLen)
                }
            }
            boundPort = UInt16(bigEndian: assignedAddr.sin_port)

            serverFD = fd
            isRunning = true
            acceptLoopGeneration += 1
            let generation = acceptLoopGeneration

            DispatchQueue(label: "com.namu.relay-accept", qos: .utility).async { [weak self] in
                self?.runAcceptLoop(generation: generation)
            }
        }
    }

    func stop() {
        let fd: Int32 = stateLock.withLock {
            guard isRunning else { return -1 }
            isRunning = false
            acceptLoopGeneration += 1
            let fd = serverFD
            serverFD = -1
            boundPort = 0
            return fd
        }
        if fd >= 0 { Darwin.close(fd) }

        let clients: Set<Int32> = clientsLock.withLock {
            let copy = clientFDs
            clientFDs.removeAll()
            return copy
        }
        for clientFD in clients { Darwin.close(clientFD) }
    }

    /// The TCP port the server is listening on, or 0 if not running.
    var port: UInt16 { stateLock.withLock { boundPort } }

    var running: Bool { stateLock.withLock { isRunning } }

    // MARK: - Accept Loop

    private func runAcceptLoop(generation: UInt64) {
        while shouldContinue(generation: generation) {
            let fd = stateLock.withLock { serverFD }
            guard fd >= 0 else { break }

            let clientFD = accept(fd, nil, nil)
            guard shouldContinue(generation: generation) else {
                if clientFD >= 0 { Darwin.close(clientFD) }
                break
            }

            if clientFD < 0 {
                switch errno {
                case EINTR, ECONNABORTED, EAGAIN:
                    continue
                default:
                    Thread.sleep(forTimeInterval: 0.05)
                    continue
                }
            }

            Self.configureTimeout(fd: clientFD, timeout: config.clientTimeout)
            clientsLock.withLock { clientFDs.insert(clientFD) }

            DispatchQueue(label: "com.namu.relay-client.\(clientFD)", qos: .utility).async { [weak self] in
                self?.handleClient(fd: clientFD)
            }
        }
    }

    // MARK: - Client Handler

    private func handleClient(fd: Int32) {
        defer {
            clientsLock.withLock { clientFDs.remove(fd) }
            Darwin.close(fd)
        }

        // Load secret
        guard let secret = loadSecret() else {
            sendRaw(fd: fd, json: ["error": "relay secret not configured"])
            return
        }

        // Step 1: send challenge
        let challenge = randomHex(bytes: 32)
        sendRaw(fd: fd, json: ["challenge": challenge])

        // Step 2: read response
        guard let line = readLine(fd: fd),
              let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
              let response = obj["response"] as? String else {
            Darwin.close(fd)
            return
        }

        // Step 3: verify HMAC
        let expected = hmacSHA256(message: challenge, key: secret)
        guard response == expected else {
            sendRaw(fd: fd, json: ["authenticated": false])
            return
        }
        sendRaw(fd: fd, json: ["authenticated": true])

        // Step 4: proxy JSON-RPC
        let clientSemaphore = DispatchSemaphore(value: 16)
        var buffer = Data()
        let readBuf = UnsafeMutablePointer<UInt8>.allocate(capacity: 4096)
        defer { readBuf.deallocate() }

        while true {
            let n = recv(fd, readBuf, 4096, 0)
            if n <= 0 { break }
            buffer.append(readBuf, count: n)

            while let idx = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                let messageData = buffer[buffer.startIndex...idx]
                buffer = buffer[buffer.index(after: idx)...]
                let trimmed = messageData.trimmingNewlines()
                guard !trimmed.isEmpty else { continue }

                clientSemaphore.wait()
                Task {
                    defer { clientSemaphore.signal() }
                    if let responseData = await self.dispatcher.dispatch(data: trimmed) {
                        self.send(fd: fd, data: responseData)
                    }
                }
            }
        }
    }

    // MARK: - Secret Management

    private func loadSecret() -> String? {
        let url = URL(fileURLWithPath: config.secretPath)
        if let data = try? Data(contentsOf: url),
           let str = String(data: data, encoding: .utf8) {
            return str.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // Auto-generate and save if missing
        let newSecret = randomHex(bytes: 32)
        try? createSecretFile(secret: newSecret)
        return newSecret
    }

    private func createSecretFile(secret: String) throws {
        let url = URL(fileURLWithPath: config.secretPath)
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: nil)
        try secret.write(to: url, atomically: true, encoding: .utf8)
        // chmod 600
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    // MARK: - HMAC-SHA256

    private func hmacSHA256(message: String, key: String) -> String {
        let msgData = Data(message.utf8)
        let keyData = Data(key.utf8)
        var result = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        keyData.withUnsafeBytes { keyBytes in
            msgData.withUnsafeBytes { msgBytes in
                CCHmac(
                    CCHmacAlgorithm(kCCHmacAlgSHA256),
                    keyBytes.baseAddress, keyBytes.count,
                    msgBytes.baseAddress, msgBytes.count,
                    &result
                )
            }
        }
        return result.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Helpers

    private func randomHex(bytes: Int) -> String {
        var buf = [UInt8](repeating: 0, count: bytes)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes, &buf)
        return buf.map { String(format: "%02x", $0) }.joined()
    }

    private func readLine(fd: Int32) -> String? {
        var result = Data()
        var byte = [UInt8](repeating: 0, count: 1)
        while result.count < 65536 {
            let n = recv(fd, &byte, 1, 0)
            if n <= 0 { break }
            if byte[0] == UInt8(ascii: "\n") { break }
            result.append(byte[0])
        }
        return result.isEmpty ? nil : String(data: result, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func send(fd: Int32, data: Data) {
        var toSend = data
        if toSend.last != UInt8(ascii: "\n") {
            toSend.append(UInt8(ascii: "\n"))
        }
        toSend.withUnsafeBytes { ptr in
            _ = Darwin.send(fd, ptr.baseAddress, ptr.count, 0)
        }
    }

    private func sendRaw(fd: Int32, json: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: json) else { return }
        send(fd: fd, data: data)
    }

    private func shouldContinue(generation: UInt64) -> Bool {
        stateLock.withLock { isRunning && generation == acceptLoopGeneration }
    }

    private static func configureTimeout(fd: Int32, timeout: TimeInterval) {
        let secs = floor(max(timeout, 0))
        let usecs = (max(timeout, 0) - secs) * 1_000_000
        var tv = timeval(tv_sec: Int(secs), tv_usec: __darwin_suseconds_t(usecs.rounded()))
        withUnsafePointer(to: &tv) { ptr in
            _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, ptr, socklen_t(MemoryLayout<timeval>.size))
            _ = setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, ptr, socklen_t(MemoryLayout<timeval>.size))
        }
    }
}

// MARK: - Errors

enum RelayServerError: Error, CustomStringConvertible {
    case socketCreate(Int32)
    case bind(errno: Int32)
    case listen(Int32)

    var description: String {
        switch self {
        case .socketCreate(let c): return "socket() failed: \(String(cString: strerror(c)))"
        case .bind(let c):         return "bind() failed: \(String(cString: strerror(c)))"
        case .listen(let c):       return "listen() failed: \(String(cString: strerror(c)))"
        }
    }
}

// MARK: - Data helper (reuse pattern from SocketServer)

private extension Data {
    func trimmingNewlines() -> Data {
        var start = startIndex
        var end = endIndex
        while start < end, self[start] == UInt8(ascii: "\n") || self[start] == UInt8(ascii: "\r") {
            start = index(after: start)
        }
        while end > start {
            let prev = index(before: end)
            guard self[prev] == UInt8(ascii: "\n") || self[prev] == UInt8(ascii: "\r") else { break }
            end = prev
        }
        return self[start..<end]
    }
}
