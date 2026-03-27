import XCTest
@testable import Namu

final class CommandDispatcherTests: XCTestCase {

    private func makeDispatcher(method: String, handler: @escaping CommandRegistry.Handler) -> CommandDispatcher {
        let registry = CommandRegistry()
        registry.register(method, handler: handler)
        return CommandDispatcher(registry: registry)
    }

    private func jsonData(_ dict: [String: Any]) -> Data {
        try! JSONSerialization.data(withJSONObject: dict)
    }

    // MARK: - Parse error

    func testInvalidJSONReturnsParseError() async {
        let registry = CommandRegistry()
        let dispatcher = CommandDispatcher(registry: registry)
        let data = Data("not json".utf8)
        let response = await dispatcher.dispatch(data: data)
        XCTAssertNotNil(response)
        let decoded = try? JSONDecoder().decode(JSONRPCResponse.self, from: response!)
        XCTAssertEqual(decoded?.error?.code, -32700)
    }

    // MARK: - Invalid request

    func testWrongVersionReturnsInvalidRequest() async {
        let registry = CommandRegistry()
        let dispatcher = CommandDispatcher(registry: registry)
        let data = jsonData(["jsonrpc": "1.0", "id": 1, "method": "test"])
        let response = await dispatcher.dispatch(data: data)
        let decoded = try? JSONDecoder().decode(JSONRPCResponse.self, from: response!)
        XCTAssertEqual(decoded?.error?.code, -32600)
    }

    // MARK: - Method not found

    func testUnknownMethodReturnsMethodNotFound() async {
        let registry = CommandRegistry()
        let dispatcher = CommandDispatcher(registry: registry)
        let data = jsonData(["jsonrpc": "2.0", "id": 1, "method": "unknown.method"])
        let response = await dispatcher.dispatch(data: data)
        let decoded = try? JSONDecoder().decode(JSONRPCResponse.self, from: response!)
        XCTAssertEqual(decoded?.error?.code, -32601)
    }

    // MARK: - Successful dispatch

    func testRegisteredMethodReturnsSuccess() async {
        let dispatcher = makeDispatcher(method: "ping") { request in
            return JSONRPCResponse.success(id: request.id, result: .string("pong"))
        }
        let data = jsonData(["jsonrpc": "2.0", "id": 42, "method": "ping"])
        let response = await dispatcher.dispatch(data: data)
        XCTAssertNotNil(response)
        let decoded = try? JSONDecoder().decode(JSONRPCResponse.self, from: response!)
        XCTAssertNil(decoded?.error)
        XCTAssertNotNil(decoded?.result)
    }

    func testResponsePreservesID() async {
        let dispatcher = makeDispatcher(method: "echo") { request in
            return JSONRPCResponse.success(id: request.id)
        }
        let data = jsonData(["jsonrpc": "2.0", "id": 99, "method": "echo"])
        let response = await dispatcher.dispatch(data: data)
        let decoded = try? JSONDecoder().decode(JSONRPCResponse.self, from: response!)
        if case .number(let id) = decoded?.id {
            XCTAssertEqual(id, 99)
        } else {
            XCTFail("Expected integer id 99")
        }
    }

    // MARK: - Notification (no id)

    func testNotificationReturnsNil() async {
        var handlerCalled = false
        let dispatcher = makeDispatcher(method: "notify") { _ in
            handlerCalled = true
            return JSONRPCResponse.success(id: nil)
        }
        let data = jsonData(["jsonrpc": "2.0", "method": "notify"])
        let response = await dispatcher.dispatch(data: data)
        XCTAssertNil(response)
        XCTAssertTrue(handlerCalled)
    }

    // MARK: - Handler throwing JSONRPCError

    func testHandlerThrowingRPCErrorReturnsError() async {
        let dispatcher = makeDispatcher(method: "fail") { _ in
            throw JSONRPCError(code: -32000, message: "Custom error")
        }
        let data = jsonData(["jsonrpc": "2.0", "id": 1, "method": "fail"])
        let response = await dispatcher.dispatch(data: data)
        let decoded = try? JSONDecoder().decode(JSONRPCResponse.self, from: response!)
        XCTAssertEqual(decoded?.error?.code, -32000)
        XCTAssertEqual(decoded?.error?.message, "Custom error")
    }

    // MARK: - String ID

    func testStringIDPreserved() async {
        let dispatcher = makeDispatcher(method: "test") { request in
            return JSONRPCResponse.success(id: request.id)
        }
        let data = jsonData(["jsonrpc": "2.0", "id": "abc-123", "method": "test"])
        let response = await dispatcher.dispatch(data: data)
        let decoded = try? JSONDecoder().decode(JSONRPCResponse.self, from: response!)
        if case .string(let id) = decoded?.id {
            XCTAssertEqual(id, "abc-123")
        } else {
            XCTFail("Expected string id 'abc-123'")
        }
    }
}
