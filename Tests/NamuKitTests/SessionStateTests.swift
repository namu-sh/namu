import XCTest
@testable import Namu

final class SessionStateTests: XCTestCase {

    // MARK: - Initial state

    func testCreatedState() {
        let state = SessionState.created
        XCTAssertTrue(state.isAlive)
        XCTAssertFalse(state.isInteractive)
    }

    // MARK: - Full lifecycle

    func testFullLifecycle() throws {
        var state = SessionState.created
        try state.handle(.start)
        XCTAssertEqual(state, .starting)
        try state.handle(.surfaceReady)
        XCTAssertEqual(state, .running)
        try state.handle(.childExited(0))
        XCTAssertEqual(state, .exited(code: 0))
        try state.handle(.destroy)
        XCTAssertEqual(state, .destroyed)
    }

    // MARK: - Non-zero exit code

    func testNonZeroExitCode() throws {
        var state = SessionState.running
        try state.handle(.childExited(42))
        if case .exited(let code) = state {
            XCTAssertEqual(code, 42)
        } else {
            XCTFail("Expected .exited(code:), got \(state)")
        }
    }

    // MARK: - Destroy shortcuts

    func testDestroyFromRunning() throws {
        var state = SessionState.running
        try state.handle(.destroy)
        XCTAssertEqual(state, .destroyed)
    }

    func testDestroyFromCreated() throws {
        var state = SessionState.created
        try state.handle(.destroy)
        XCTAssertEqual(state, .destroyed)
    }

    // MARK: - Invalid transitions

    func testInvalidTransitions() {
        var destroyed = SessionState.destroyed
        XCTAssertThrowsError(try destroyed.handle(.start))

        var starting = SessionState.starting
        XCTAssertThrowsError(try starting.handle(.childExited(0)))

        var exited = SessionState.exited(code: 0)
        XCTAssertThrowsError(try exited.handle(.surfaceReady))

        var running = SessionState.running
        XCTAssertThrowsError(try running.handle(.start))
    }

    // MARK: - isInteractive

    func testIsInteractiveOnlyWhenRunning() {
        XCTAssertFalse(SessionState.created.isInteractive)
        XCTAssertFalse(SessionState.starting.isInteractive)
        XCTAssertTrue(SessionState.running.isInteractive)
        XCTAssertFalse(SessionState.exited(code: 0).isInteractive)
        XCTAssertFalse(SessionState.destroyed.isInteractive)
    }

    // MARK: - isAlive

    func testIsAliveStates() {
        XCTAssertTrue(SessionState.created.isAlive)
        XCTAssertTrue(SessionState.starting.isAlive)
        XCTAssertTrue(SessionState.running.isAlive)
        XCTAssertFalse(SessionState.exited(code: 0).isAlive)
        XCTAssertFalse(SessionState.destroyed.isAlive)
    }
}
