import Foundation

/// Unix domain socket server that accepts client connections and dispatches JSON-RPC commands.
final class SocketServer: @unchecked Sendable {

    // MARK: - Configuration

    struct Config: Sendable {
        /// Path for the Unix domain socket.
        let socketPath: String
        /// Backlog for listen(2).
        var listenBacklog: Int32 = 128
        /// Per-client read/write timeout.
        var clientTimeout: TimeInterval = 30

        static func defaultPath(tag: String? = nil) -> Config {
            if let tag {
                return Config(socketPath: "/tmp/namu-\(tag).sock")
            }
            return Config(socketPath: "/tmp/namu.sock")
        }
    }

    // MARK: - Dependencies

    private let config: Config
    private let dispatcher: CommandDispatcher
    private let accessController: AccessController
    private let eventBus: EventBus

    // MARK: - State (protected by stateLock)

    private let stateLock = NSLock()
    private var serverFD: Int32 = -1
    private var isRunning = false
    private var acceptLoopGeneration: UInt64 = 0

    // Active client sockets — for clean shutdown
    private let clientsLock = NSLock()
    private var clientFDs: Set<Int32> = []

    // MARK: - Init

    init(
        config: Config = .defaultPath(),
        dispatcher: CommandDispatcher,
        accessController: AccessController,
        eventBus: EventBus
    ) {
        self.config = config
        self.dispatcher = dispatcher
        self.accessController = accessController
        self.eventBus = eventBus
    }

    // MARK: - Start / Stop

    /// Start listening. Spawns a background accept loop.
    func start() throws {
        signal(SIGPIPE, SIG_IGN)
        try stateLock.withLock {
            guard !isRunning else { return }

            let fd = socket(AF_UNIX, SOCK_STREAM, 0)
            guard fd >= 0 else {
                throw SocketServerError.socketCreate(errno)
            }

            // Bind
            switch Self.bind(fd: fd, path: config.socketPath) {
            case .success: break
            case .pathTooLong:
                Darwin.close(fd)
                throw SocketServerError.pathTooLong(config.socketPath)
            case .failure(let stage, let code):
                Darwin.close(fd)
                throw SocketServerError.bind(stage: stage, errno: code)
            }

            guard Darwin.listen(fd, config.listenBacklog) == 0 else {
                let code = errno
                Darwin.close(fd)
                throw SocketServerError.listen(code)
            }

            serverFD = fd
            isRunning = true
            acceptLoopGeneration += 1
            let generation = acceptLoopGeneration

            DispatchQueue(label: "com.namu.socket-accept", qos: .utility).async { [weak self] in
                self?.runAcceptLoop(generation: generation)
            }
        }
    }

    /// Stop the server and close all client connections.
    func stop() {
        let fd: Int32 = stateLock.withLock {
            guard isRunning else { return -1 }
            isRunning = false
            acceptLoopGeneration += 1  // invalidate current loop
            let fd = serverFD
            serverFD = -1
            return fd
        }

        if fd >= 0 {
            Darwin.close(fd)
            unlink(config.socketPath)
        }

        // Close active clients
        let clients: Set<Int32> = clientsLock.withLock {
            let copy = clientFDs
            clientFDs.removeAll()
            return copy
        }
        for clientFD in clients {
            Darwin.close(clientFD)
        }
    }

    var socketPath: String { config.socketPath }

    // MARK: - Accept Loop

    private func runAcceptLoop(generation: UInt64) {
        while shouldContinue(generation: generation) {
            let serverFD = stateLock.withLock { self.serverFD }
            guard serverFD >= 0 else { break }

            let clientFD = accept(serverFD, nil, nil)
            guard shouldContinue(generation: generation) else {
                if clientFD >= 0 { Darwin.close(clientFD) }
                break
            }

            if clientFD < 0 {
                let code = errno
                switch code {
                case EINTR, ECONNABORTED, EAGAIN:
                    continue
                default:
                    // Brief back-off then retry
                    Thread.sleep(forTimeInterval: 0.05)
                    continue
                }
            }

            // Configure timeouts
            Self.configureTimeout(fd: clientFD, timeout: config.clientTimeout)

            // Evaluate access
            let accessState = accessController.evaluateNewConnection(clientSocket: clientFD)
            if case .denied = accessState {
                Darwin.close(clientFD)
                continue
            }

            clientsLock.withLock { clientFDs.insert(clientFD) }

            let capturedAccessState = accessState
            DispatchQueue(label: "com.namu.socket-client.\(clientFD)", qos: .utility).async { [weak self] in
                self?.handleClient(fd: clientFD, accessState: capturedAccessState)
            }
        }
    }

    // MARK: - Client Handler

    private func handleClient(fd: Int32, accessState: AccessState) {
        defer {
            clientsLock.withLock { clientFDs.remove(fd) }
            Darwin.close(fd)
        }

        let clientSemaphore = DispatchSemaphore(value: 16)
        var currentAccessState = accessState
        var eventSubscriptionId: UUID?

        // Writer closure used by EventBus subscriptions
        let writer: EventBus.NotificationWriter = { [weak self] data in
            self?.send(fd: fd, data: data)
        }

        // Read loop: newline-delimited JSON messages
        var buffer = Data()
        let readBuf = UnsafeMutablePointer<UInt8>.allocate(capacity: 4096)
        defer { readBuf.deallocate() }

        while true {
            let n = recv(fd, readBuf, 4096, 0)
            if n <= 0 { break }

            buffer.append(readBuf, count: n)

            // Process all complete newline-delimited messages
            while let newlineIdx = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                let messageData = buffer[buffer.startIndex...newlineIdx]
                buffer = buffer[buffer.index(after: newlineIdx)...]

                let trimmed = messageData.trimmingNewlines()
                guard !trimmed.isEmpty else { continue }

                // Handle password authentication for pending state
                if case .pending = currentAccessState {
                    currentAccessState = handleAuth(fd: fd, data: trimmed)
                    continue
                }

                guard case .authenticated = currentAccessState else { break }

                // Intercept subscription management commands before dispatching
                if let (method, id) = peekMethod(data: trimmed) {
                    if method == "events.subscribe" {
                        eventSubscriptionId = handleSubscribe(
                            fd: fd, id: id, data: trimmed,
                            currentId: eventSubscriptionId, writer: writer
                        )
                        continue
                    } else if method == "events.unsubscribe" {
                        if let subId = eventSubscriptionId {
                            eventBus.unsubscribe(subId)
                            eventSubscriptionId = nil
                        }
                        sendSuccess(fd: fd, id: id)
                        continue
                    }
                }

                clientSemaphore.wait()
                Task {
                    defer { clientSemaphore.signal() }
                    if let responseData = await dispatcher.dispatch(data: trimmed) {
                        self.send(fd: fd, data: responseData)
                    }
                }
            }
        }

        // Clean up subscription on disconnect
        if let subId = eventSubscriptionId {
            eventBus.unsubscribe(subId)
        }
    }

    // MARK: - Auth

    private func handleAuth(fd: Int32, data: Data) -> AccessState {
        // Expect {"jsonrpc":"2.0","id":...,"method":"auth","params":{"password":"..."}}
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let params = obj["params"] as? [String: Any],
              let pw = params["password"] as? String else {
            let id = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]).flatMap { $0["id"] }
            sendError(fd: fd, id: id, error: .invalidParams)
            return .pending
        }
        let newState = accessController.authenticate(password: pw)
        let idVal = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]).flatMap { $0["id"] }
        if case .authenticated = newState {
            sendRaw(fd: fd, json: ["jsonrpc": "2.0", "id": idVal as Any, "result": ["ok": true]])
        } else {
            sendError(fd: fd, id: idVal, error: .accessDenied())
        }
        return newState
    }

    // MARK: - Subscription Helpers

    private func handleSubscribe(
        fd: Int32,
        id: JSONRPCId?,
        data: Data,
        currentId: UUID?,
        writer: @escaping EventBus.NotificationWriter
    ) -> UUID {
        // Unsubscribe previous if any
        if let existing = currentId { eventBus.unsubscribe(existing) }

        var eventSet: Set<NamuEvent> = Set(NamuEvent.allCases)
        if let obj = try? JSONDecoder().decode(JSONRPCRequest.self, from: data),
           let params = obj.params?.object,
           case .array(let arr) = params["events"] {
            let names = arr.compactMap { if case .string(let s) = $0 { return s } else { return nil } }
            let parsed = names.compactMap { NamuEvent(rawValue: $0) }
            if !parsed.isEmpty { eventSet = Set(parsed) }
        }

        let subId = eventBus.subscribe(events: eventSet, writer: writer)
        sendSuccess(fd: fd, id: id)
        return subId
    }

    // MARK: - Send Helpers

    private func send(fd: Int32, data: Data) {
        var toSend = data
        if toSend.last != UInt8(ascii: "\n") {
            toSend.append(UInt8(ascii: "\n"))
        }
        toSend.withUnsafeBytes { ptr in
            _ = Darwin.send(fd, ptr.baseAddress, ptr.count, 0)
        }
    }

    private func sendSuccess(fd: Int32, id: JSONRPCId?) {
        let response = JSONRPCResponse.success(id: id)
        if let data = try? JSONEncoder().encode(response) {
            send(fd: fd, data: data)
        }
    }

    private func sendError(fd: Int32, id: Any?, error: JSONRPCError) {
        // Lightweight: build raw dict to avoid double-encoding the id type
        var dict: [String: Any] = [
            "jsonrpc": "2.0",
            "error": ["code": error.code, "message": error.message]
        ]
        if let id { dict["id"] = id }
        sendRaw(fd: fd, json: dict)
    }

    private func sendRaw(fd: Int32, json: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: json) else { return }
        send(fd: fd, data: data)
    }

    private func peekMethod(data: Data) -> (method: String, id: JSONRPCId?)? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let method = obj["method"] as? String else { return nil }
        var id: JSONRPCId?
        if let rawId = obj["id"] as? String { id = .string(rawId) }
        else if let rawId = obj["id"] as? Int { id = .number(rawId) }
        return (method, id)
    }

    // MARK: - Helpers

    private func shouldContinue(generation: UInt64) -> Bool {
        stateLock.withLock { isRunning && generation == acceptLoopGeneration }
    }

    // MARK: - Static Socket Utilities

    private enum BindResult {
        case success
        case pathTooLong
        case failure(stage: String, errno: Int32)
    }

    private static func bind(fd: Int32, path: String) -> BindResult {
        // Remove stale socket file
        if unlink(path) != 0, errno != ENOENT {
            return .failure(stage: "unlink", errno: errno)
        }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)

        var didFit = false
        path.withCString { src in
            let maxLen = MemoryLayout.size(ofValue: addr.sun_path) - 1
            guard strlen(src) <= maxLen else { return }
            _ = withUnsafeMutablePointer(to: &addr.sun_path) { dst in
                strncpy(UnsafeMutableRawPointer(dst).assumingMemoryBound(to: CChar.self), src, maxLen)
            }
            didFit = true
        }
        guard didFit else { return .pathTooLong }

        let result = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                Darwin.bind(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else { return .failure(stage: "bind", errno: errno) }
        return .success
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

enum SocketServerError: Error, CustomStringConvertible {
    case socketCreate(Int32)
    case pathTooLong(String)
    case bind(stage: String, errno: Int32)
    case listen(Int32)

    var description: String {
        switch self {
        case .socketCreate(let code): return "socket() failed: \(errnoString(code))"
        case .pathTooLong(let p): return "Socket path too long: \(p)"
        case .bind(let stage, let code): return "bind failed at \(stage): \(errnoString(code))"
        case .listen(let code): return "listen() failed: \(errnoString(code))"
        }
    }

    private func errnoString(_ code: Int32) -> String {
        String(cString: strerror(code))
    }
}

// MARK: - Data helpers

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

private extension NSLock {
    @discardableResult
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
