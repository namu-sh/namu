import XCTest
@testable import Namu

final class AccessControlTests: XCTestCase {

    // MARK: - Off Mode

    func testOffModeRejectAll() {
        let ac = AccessController(mode: .off)
        // Cannot test real sockets, but evaluateNewConnection with mode .off returns denied
        // regardless of the socket FD.
        let state = ac.evaluateNewConnection(clientSocket: -1)
        XCTAssertEqual(state, .denied)
    }

    // MARK: - AllowAll Mode

    func testAllowAllModeAuthenticatesImmediately() {
        let ac = AccessController(mode: .allowAll)
        let state = ac.evaluateNewConnection(clientSocket: -1)
        XCTAssertEqual(state, .authenticated)
    }

    // MARK: - Automation Mode

    func testAutomationModeAuthenticatesImmediately() {
        let ac = AccessController(mode: .automation)
        let state = ac.evaluateNewConnection(clientSocket: -1)
        XCTAssertEqual(state, .authenticated)
    }

    // MARK: - Password Mode

    func testPasswordModePendingOnConnect() {
        let ac = AccessController(mode: .password, password: "secret123")
        let state = ac.evaluateNewConnection(clientSocket: -1)
        XCTAssertEqual(state, .pending)
    }

    func testPasswordAuthenticateCorrect() {
        let ac = AccessController(mode: .password, password: "correct-horse")
        let state = ac.authenticate(password: "correct-horse")
        XCTAssertEqual(state, .authenticated)
    }

    func testPasswordAuthenticateWrong() {
        let ac = AccessController(mode: .password, password: "correct-horse")
        let state = ac.authenticate(password: "wrong-password")
        XCTAssertEqual(state, .denied)
    }

    func testPasswordAuthenticateEmptyStored() {
        let ac = AccessController(mode: .password, password: nil)
        let state = ac.authenticate(password: "anything")
        XCTAssertEqual(state, .denied)
    }

    func testPasswordLengthMismatchDenied() {
        let ac = AccessController(mode: .password, password: "short")
        let state = ac.authenticate(password: "much-longer-password")
        XCTAssertEqual(state, .denied)
    }

    func testPasswordAuthenticateOnNonPasswordMode() {
        let ac = AccessController(mode: .allowAll)
        // Calling authenticate in a non-password mode should still succeed
        let state = ac.authenticate(password: "ignored")
        XCTAssertEqual(state, .authenticated)
    }

    func testPasswordAuthenticateOnOffMode() {
        let ac = AccessController(mode: .off)
        let state = ac.authenticate(password: "anything")
        XCTAssertEqual(state, .denied)
    }

    // MARK: - LocalOnly Mode (limited without real sockets)

    func testLocalOnlyModeWithInvalidSocket() {
        let ac = AccessController(mode: .localOnly)
        // Invalid socket FD — getsockopt will fail, should fall through to UID check or deny
        let state = ac.evaluateNewConnection(clientSocket: -1)
        // With an invalid FD, getPeerPid returns nil, then peerHasSameUID also fails → denied
        XCTAssertEqual(state, .denied)
    }

    // MARK: - Mode Updates

    func testUpdateMode() {
        let ac = AccessController(mode: .off)
        XCTAssertEqual(ac.evaluateNewConnection(clientSocket: -1), .denied)

        ac.update(mode: .allowAll)
        XCTAssertEqual(ac.evaluateNewConnection(clientSocket: -1), .authenticated)

        ac.update(mode: .password, password: "new-pass")
        XCTAssertEqual(ac.evaluateNewConnection(clientSocket: -1), .pending)
        XCTAssertEqual(ac.authenticate(password: "new-pass"), .authenticated)
    }

    // MARK: - Constant-Time Comparison

    func testConstantTimeComparisonCorrectness() {
        // This tests correctness, not timing (timing attack resistance
        // is a property of the implementation, verified by code review).
        let ac = AccessController(mode: .password, password: "abc")
        XCTAssertEqual(ac.authenticate(password: "abc"), .authenticated)
        XCTAssertEqual(ac.authenticate(password: "abd"), .denied)
        XCTAssertEqual(ac.authenticate(password: "ab"), .denied)
        XCTAssertEqual(ac.authenticate(password: "abcd"), .denied)
        XCTAssertEqual(ac.authenticate(password: ""), .denied)
    }

    // MARK: - Thread Safety

    func testConcurrentAccessDoesNotCrash() {
        let ac = AccessController(mode: .password, password: "safe")
        let group = DispatchGroup()

        for _ in 0..<100 {
            group.enter()
            DispatchQueue.global().async {
                _ = ac.evaluateNewConnection(clientSocket: -1)
                _ = ac.authenticate(password: "safe")
                _ = ac.authenticate(password: "wrong")
                ac.update(mode: .allowAll)
                ac.update(mode: .password, password: "safe")
                group.leave()
            }
        }

        let result = group.wait(timeout: .now() + 5)
        XCTAssertEqual(result, .success)
    }
}

// MARK: - AccessState Equatable

extension AccessState: @retroactive Equatable {
    public static func == (lhs: AccessState, rhs: AccessState) -> Bool {
        switch (lhs, rhs) {
        case (.pending, .pending): return true
        case (.authenticated, .authenticated): return true
        case (.denied, .denied): return true
        default: return false
        }
    }
}
