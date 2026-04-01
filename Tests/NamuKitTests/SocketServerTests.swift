import XCTest
@testable import Namu

final class SocketServerTests: XCTestCase {

    // MARK: - Helpers

    private func makeServer(
        path: String? = nil,
        mode: AccessMode = .allowAll,
        password: String? = nil,
        register: ((CommandRegistry) -> Void)? = nil
    ) -> (SocketServer, String) {
        let socketPath = path ?? "/tmp/namu-test-\(UUID().uuidString).sock"
        let registry = CommandRegistry()
        register?(registry)
        let dispatcher = CommandDispatcher(registry: registry)
        let ac = AccessController(mode: mode, password: password)
        let bus = EventBus()
        let server = SocketServer(
            config: .init(socketPath: socketPath),
            dispatcher: dispatcher,
            accessController: ac,
            eventBus: bus
        )
        return (server, socketPath)
    }

    /// Connect to a Unix domain socket and return the client FD.
    private func connectClient(to path: String) -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return -1 }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let maxLen = MemoryLayout.size(ofValue: addr.sun_path) - 1
        _ = path.withCString { src in
            memcpy(&addr.sun_path, src, min(strlen(src), maxLen))
        }

        let result = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                connect(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else {
            close(fd)
            return -1
        }
        return fd
    }

    private func sendJSON(_ fd: Int32, _ string: String) {
        let data = Data((string + "\n").utf8)
        data.withUnsafeBytes { ptr in
            _ = Darwin.send(fd, ptr.baseAddress, ptr.count, 0)
        }
    }

    private func recvJSON(_ fd: Int32) -> [String: Any]? {
        var buf = [UInt8](repeating: 0, count: 4096)
        let n = recv(fd, &buf, buf.count, 0)
        guard n > 0 else { return nil }
        let data = Data(buf[0..<n])
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    // MARK: - Health

    func testHealthReportsNotRunningBeforeStart() {
        let (server, _) = makeServer()
        let h = server.health()
        XCTAssertFalse(h.isRunning)
        XCTAssertFalse(h.isHealthy)
    }

    func testHealthReportsRunningAfterStart() throws {
        let (server, _) = makeServer()
        defer { server.stop() }

        try server.start()
        Thread.sleep(forTimeInterval: 0.1)

        let h = server.health()
        XCTAssertTrue(h.isRunning)
        XCTAssertTrue(h.acceptLoopAlive)
        XCTAssertTrue(h.socketPathExists)
        XCTAssertTrue(h.isHealthy)
    }

    func testHealthAfterStop() throws {
        let (server, _) = makeServer()

        try server.start()
        Thread.sleep(forTimeInterval: 0.1)
        server.stop()
        Thread.sleep(forTimeInterval: 0.1)

        let h = server.health()
        XCTAssertFalse(h.isRunning)
        XCTAssertFalse(h.socketPathExists)
        XCTAssertFalse(h.isHealthy)
    }

    // MARK: - Start / Stop Lifecycle

    func testDoubleStartIsIdempotent() throws {
        let (server, _) = makeServer()
        defer { server.stop() }

        try server.start()
        try server.start()

        let h = server.health()
        XCTAssertTrue(h.isRunning)
    }

    func testDoubleStopIsIdempotent() throws {
        let (server, _) = makeServer()

        try server.start()
        server.stop()
        server.stop()
    }

    func testSocketPathCleanedUpOnStop() throws {
        let (server, path) = makeServer()

        try server.start()
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))

        server.stop()
        Thread.sleep(forTimeInterval: 0.05)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
    }

    // MARK: - Client Connection

    func testClientCanConnectAndReceiveResponse() throws {
        let (server, path) = makeServer { registry in
            registry.register("test.ping") { _ in
                return JSONRPCResponse.success(id: .number(1), result: .object(["pong": .bool(true)]))
            }
        }
        defer { server.stop() }
        try server.start()
        Thread.sleep(forTimeInterval: 0.1)

        let clientFD = connectClient(to: path)
        XCTAssertGreaterThanOrEqual(clientFD, 0, "Client should connect to server")
        defer { close(clientFD) }

        sendJSON(clientFD, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"test.ping\"}")
        Thread.sleep(forTimeInterval: 0.2)

        let json = recvJSON(clientFD)
        XCTAssertNotNil(json)
        let result = json?["result"] as? [String: Any]
        XCTAssertEqual(result?["pong"] as? Bool, true)
    }

    // MARK: - Password Auth Flow

    func testPasswordAuthFlow() throws {
        let (server, path) = makeServer(mode: .password, password: "secret") { registry in
            registry.register("test.ping") { _ in
                return JSONRPCResponse.success(id: .number(1))
            }
        }
        defer { server.stop() }
        try server.start()
        Thread.sleep(forTimeInterval: 0.1)

        let clientFD = connectClient(to: path)
        XCTAssertGreaterThanOrEqual(clientFD, 0)
        defer { close(clientFD) }

        // Authenticate
        sendJSON(clientFD, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"auth\",\"params\":{\"password\":\"secret\"}}")
        Thread.sleep(forTimeInterval: 0.2)

        let json = recvJSON(clientFD)
        XCTAssertNotNil(json)
        let result = json?["result"] as? [String: Any]
        XCTAssertEqual(result?["ok"] as? Bool, true)
    }

    // MARK: - Bind Error Handling

    func testPathTooLongThrows() {
        let longPath = "/tmp/" + String(repeating: "a", count: 200) + ".sock"
        let (server, _) = makeServer(path: longPath)

        XCTAssertThrowsError(try server.start()) { error in
            guard let socketError = error as? SocketServerError else {
                XCTFail("Expected SocketServerError, got \(error)")
                return
            }
            XCTAssertTrue(socketError.description.contains("too long"))
        }
    }
}
