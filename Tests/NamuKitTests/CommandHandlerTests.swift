import XCTest
@testable import Namu

final class CommandHandlerTests: XCTestCase {

    // MARK: - Helpers

    private func makeRegistration(
        method: String,
        execution: ExecutionContext = .background,
        safety: SafetyLevel = .safe
    ) -> HandlerRegistration {
        HandlerRegistration(
            method: method,
            execution: execution,
            safety: safety,
            handler: { req in JSONRPCResponse.success(id: req.id) }
        )
    }

    // MARK: - Register and retrieve

    func testRegisterAndRetrieve() {
        let registry = CommandRegistry()
        let registration = makeRegistration(method: "workspace.list")
        registry.register(registration)

        let retrieved = registry.registration(for: "workspace.list")
        XCTAssertNotNil(retrieved)
        XCTAssertEqual(retrieved?.method, "workspace.list")
    }

    // MARK: - CQRS metadata

    func testCQRSMetadata() async throws {
        let registry = CommandRegistry()
        let registration = makeRegistration(
            method: "workspace.status",
            execution: .background,
            safety: .safe
        )
        registry.register(registration)

        let retrieved = registry.registration(for: "workspace.status")
        XCTAssertEqual(retrieved?.execution, .background)
        XCTAssertEqual(retrieved?.safety, .safe)

        // Verify handler executes
        let req = JSONRPCRequest(id: .string("1"), method: "workspace.status", params: nil)
        let response = try await retrieved!.handler(req)
        XCTAssertNil(response.error)
    }

    // MARK: - Multiple registrations

    func testMultipleRegistrations() {
        let registry = CommandRegistry()
        registry.register(makeRegistration(method: "workspace.list"))
        registry.register(makeRegistration(method: "workspace.create"))
        registry.register(makeRegistration(method: "workspace.delete"))

        XCTAssertNotNil(registry.registration(for: "workspace.list"))
        XCTAssertNotNil(registry.registration(for: "workspace.create"))
        XCTAssertNotNil(registry.registration(for: "workspace.delete"))
    }

    // MARK: - Overwrite registration

    func testOverwriteRegistration() async throws {
        let registry = CommandRegistry()

        let first = HandlerRegistration(
            method: "ping",
            execution: .background,
            safety: .safe,
            handler: { req in JSONRPCResponse.success(id: req.id, result: .string("first")) }
        )
        let second = HandlerRegistration(
            method: "ping",
            execution: .mainActor,
            safety: .normal,
            handler: { req in JSONRPCResponse.success(id: req.id, result: .string("second")) }
        )

        registry.register(first)
        registry.register(second)

        let retrieved = registry.registration(for: "ping")
        XCTAssertEqual(retrieved?.execution, .mainActor)
        XCTAssertEqual(retrieved?.safety, .normal)

        let req = JSONRPCRequest(id: .string("x"), method: "ping", params: nil)
        let response = try await retrieved!.handler(req)
        if case .string(let val) = response.result {
            XCTAssertEqual(val, "second")
        } else {
            XCTFail("Expected string result 'second'")
        }
    }

    // MARK: - Legacy closure registration

    func testLegacyClosureRegistration() async throws {
        let registry = CommandRegistry()

        // New-style registration
        registry.register(makeRegistration(method: "workspace.list"))

        // Old-style registration alongside it
        registry.register("ping") { req in
            JSONRPCResponse.success(id: req.id, result: .string("pong"))
        }

        // Both must be retrievable via handler(for:)
        XCTAssertNotNil(registry.handler(for: "workspace.list"))
        XCTAssertNotNil(registry.handler(for: "ping"))

        // Legacy handler executes correctly
        let req = JSONRPCRequest(id: .number(1), method: "ping", params: nil)
        let response = try await registry.handler(for: "ping")!(req)
        if case .string(let val) = response.result {
            XCTAssertEqual(val, "pong")
        } else {
            XCTFail("Expected string result 'pong'")
        }
    }
}
