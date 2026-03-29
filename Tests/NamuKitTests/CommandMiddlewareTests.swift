import XCTest
@testable import Namu

final class CommandMiddlewareTests: XCTestCase {

    // MARK: - Helpers

    private func makeRequest(method: String, id: JSONRPCId = .string("test")) -> JSONRPCRequest {
        JSONRPCRequest(id: id, method: method, params: nil)
    }

    private func makeContext(source: MiddlewareCommandSource = .local) -> CommandContext {
        CommandContext(clientID: UUID(), accessMode: .allowAll, source: source)
    }

    private func okHandler(_ req: JSONRPCRequest, _ ctx: CommandContext) async throws -> JSONRPCResponse {
        JSONRPCResponse.success(id: req.id)
    }

    // MARK: - Chain construction

    func testEmptyMiddlewareChain() async throws {
        var handlerCalled = false
        let chain = chainMiddleware([]) { req, ctx in
            handlerCalled = true
            return JSONRPCResponse.success(id: req.id)
        }
        _ = try await chain(makeRequest(method: "ping"), makeContext())
        XCTAssertTrue(handlerCalled)
    }

    func testSingleMiddleware() async throws {
        var middlewareCalled = false
        var handlerCalled = false

        let middleware: CommandMiddleware = { req, ctx, next in
            middlewareCalled = true
            return try await next(req, ctx)
        }

        let chain = chainMiddleware([middleware]) { req, ctx in
            handlerCalled = true
            return JSONRPCResponse.success(id: req.id)
        }

        _ = try await chain(makeRequest(method: "ping"), makeContext())
        XCTAssertTrue(middlewareCalled)
        XCTAssertTrue(handlerCalled)
    }

    func testMiddlewareExecutionOrder() async throws {
        var order: [String] = []

        let middlewareA: CommandMiddleware = { req, ctx, next in
            order.append("A")
            let result = try await next(req, ctx)
            return result
        }
        let middlewareB: CommandMiddleware = { req, ctx, next in
            order.append("B")
            let result = try await next(req, ctx)
            return result
        }

        let chain = chainMiddleware([middlewareA, middlewareB]) { req, ctx in
            order.append("handler")
            return JSONRPCResponse.success(id: req.id)
        }

        _ = try await chain(makeRequest(method: "ping"), makeContext())
        XCTAssertEqual(order, ["A", "B", "handler"])
    }

    func testMiddlewareCanShortCircuit() async throws {
        var handlerCalled = false

        let blockingMiddleware: CommandMiddleware = { req, ctx, next in
            throw JSONRPCError(code: -32000, message: "Blocked")
        }

        let chain = chainMiddleware([blockingMiddleware]) { req, ctx in
            handlerCalled = true
            return JSONRPCResponse.success(id: req.id)
        }

        do {
            _ = try await chain(makeRequest(method: "ping"), makeContext())
            XCTFail("Expected error to be thrown")
        } catch {
            XCTAssertFalse(handlerCalled)
        }
    }

    // MARK: - Rate limiter

    func testRateLimiterAllowsUnderLimit() async throws {
        let limiter = RateLimiter(limit: 20, window: .seconds(60))
        let middleware = makeRateLimitMiddleware(limiter: limiter)
        let chain = chainMiddleware([middleware], handler: okHandler)

        for _ in 0..<20 {
            let response = try await chain(makeRequest(method: "ping"), makeContext(source: .gateway))
            XCTAssertNil(response.error)
        }
    }

    func testRateLimiterBlocksOverLimit() async throws {
        let limiter = RateLimiter(limit: 20, window: .seconds(60))
        let middleware = makeRateLimitMiddleware(limiter: limiter)
        let chain = chainMiddleware([middleware], handler: okHandler)
        let ctx = makeContext(source: .gateway)

        for _ in 0..<20 {
            _ = try await chain(makeRequest(method: "ping"), ctx)
        }

        do {
            _ = try await chain(makeRequest(method: "ping"), ctx)
            XCTFail("Expected rate limit error on 21st call")
        } catch let error as JSONRPCError {
            XCTAssertEqual(error.code, -32000)
        }
    }

    func testRateLimiterLocalBypass() async throws {
        let limiter = RateLimiter(limit: 20, window: .seconds(60))
        let middleware = makeRateLimitMiddleware(limiter: limiter)
        let chain = chainMiddleware([middleware], handler: okHandler)
        let ctx = makeContext(source: .local)

        // 25 calls from local should all succeed (limit only applies to gateway/ai)
        for _ in 0..<25 {
            let response = try await chain(makeRequest(method: "ping"), ctx)
            XCTAssertNil(response.error)
        }
    }

    // MARK: - Safety middleware

    func testSafetyMiddlewareBlocksDangerous() async throws {
        let safety = CommandSafety()
        let middleware = makeSafetyMiddleware(safety: safety)
        let chain = chainMiddleware([middleware], handler: okHandler)

        // "send_keys" is dangerous; gateway source should throw
        do {
            _ = try await chain(
                makeRequest(method: "send_keys"),
                makeContext(source: .gateway)
            )
            XCTFail("Expected dangerous command to throw for gateway source")
        } catch let error as JSONRPCError {
            XCTAssertEqual(error.code, -32003)
        }
    }

    func testSafetyMiddlewareAllowsLocal() async throws {
        let safety = CommandSafety()
        let middleware = makeSafetyMiddleware(safety: safety)
        let chain = chainMiddleware([middleware], handler: okHandler)

        // "send_keys" is dangerous but local source should pass through
        let response = try await chain(
            makeRequest(method: "send_keys"),
            makeContext(source: .local)
        )
        XCTAssertNil(response.error)
    }

    // MARK: - CommandContext fields

    func testCommandContextFields() {
        let clientID = UUID()
        let ctx = CommandContext(
            clientID: clientID,
            accessMode: .allowAll,
            source: .ai,
            metadata: ["key": "value"]
        )
        XCTAssertEqual(ctx.clientID, clientID)
        XCTAssertEqual(ctx.accessMode, .allowAll)
        XCTAssertEqual(ctx.source, .ai)
        XCTAssertEqual(ctx.metadata["key"], "value")
    }
}
