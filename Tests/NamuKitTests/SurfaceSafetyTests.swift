import XCTest
@testable import Namu

// MARK: - SurfaceSafetyTests
//
// Tests for GhosttyBridge.Surface.appearsLive pointer safety checks.
//
// ghostty_surface_t is a non-optional C pointer (UnsafeMutableRawPointer).
// We cannot pass nil to appearsLive because the Swift type system disallows it.
// Instead we test two observable behaviors:
//   1. A dangling/stack pointer returns false (malloc_zone_from_ptr finds no zone).
//   2. A freshly malloc'd allocation returns true.
//
// We also exercise the TerminalSession path: liveSurface() returns nil when
// surface is nil (the common pre-start / post-destroy state).

final class SurfaceSafetyTests: XCTestCase {

    // MARK: - appearsLive with a stack pointer (not in any malloc zone)

    func test_appearsLive_withStackPointer_returnsFalse() {
        // A local variable lives on the stack, not in any malloc zone.
        // malloc_zone_from_ptr should return nil for it.
        var dummy: Int = 42
        let stackPtr = withUnsafeMutablePointer(to: &dummy) { UnsafeMutableRawPointer($0) }
        // appearsLive takes a non-optional ghostty_surface_t (UnsafeMutableRawPointer).
        let result = GhosttyBridge.Surface.appearsLive(stackPtr)
        XCTAssertFalse(result,
                       "A stack-allocated pointer must not appear live to malloc_zone_from_ptr")
    }

    // MARK: - appearsLive with a heap allocation

    func test_appearsLive_withHeapAllocation_returnsTrue() {
        // malloc returns a live heap pointer — should pass the zone check.
        let size = 64
        guard let heapPtr = malloc(size) else {
            return XCTFail("malloc failed — cannot test heap liveness")
        }
        defer { free(heapPtr) }

        let result = GhosttyBridge.Surface.appearsLive(heapPtr)
        XCTAssertTrue(result,
                      "A live heap-allocated pointer must appear live to malloc_zone_from_ptr")
    }

    func test_appearsLive_afterFree_returnsFalse() {
        // After free(), malloc_zone_from_ptr typically returns nil for the address.
        // Note: this is a best-effort check — the implementation notes that freed-then-
        // reallocated memory can pass; here we simply verify the function does not crash.
        let size = 64
        guard let heapPtr = malloc(size) else {
            return XCTFail("malloc failed")
        }
        free(heapPtr)
        // Must not crash. Result may be true or false depending on allocator internals.
        _ = GhosttyBridge.Surface.appearsLive(heapPtr)
    }

    // MARK: - TerminalSession surface nil guards

    func test_terminalSession_beforeStart_surfaceIsNil() {
        // A freshly created TerminalSession has no surface until start() is called.
        let session = TerminalSession(id: UUID())
        XCTAssertNil(session.surface,
                     "TerminalSession.surface must be nil before start() is called")
    }

    func test_terminalSession_beforeStart_isAliveIsFalse() {
        // isAlive delegates to state machine; initial state is .created which is not alive.
        let session = TerminalSession(id: UUID())
        XCTAssertFalse(session.isAlive,
                       "TerminalSession.isAlive must be false before start() is called")
    }

    func test_terminalSession_processExited_withNilSurface_returnsTrue() {
        // liveSurface() returns nil when surface is nil; processExited guard returns true.
        let session = TerminalSession(id: UUID())
        XCTAssertTrue(session.processExited,
                      "processExited must return true when surface is nil (no live process)")
    }

    func test_terminalSession_readSelection_withNilSurface_returnsNil() {
        let session = TerminalSession(id: UUID())
        XCTAssertNil(session.readSelection(),
                     "readSelection must return nil when there is no live surface")
    }

    func test_terminalSession_readVisibleText_withNilSurface_returnsNil() {
        let session = TerminalSession(id: UUID())
        XCTAssertNil(session.readVisibleText(),
                     "readVisibleText must return nil when there is no live surface")
    }

    func test_terminalSession_readScrollbackText_withNilSurface_returnsNil() {
        let session = TerminalSession(id: UUID())
        XCTAssertNil(session.readScrollbackText(charLimit: 1000),
                     "readScrollbackText must return nil when there is no live surface")
    }

    func test_terminalSession_currentFontSizePoints_withNilSurface_returnsNil() {
        let session = TerminalSession(id: UUID())
        XCTAssertNil(session.currentFontSizePoints(),
                     "currentFontSizePoints must return nil when there is no live surface")
    }

    func test_terminalSession_surfaceSize_withNilSurface_returnsNil() {
        let session = TerminalSession(id: UUID())
        XCTAssertNil(session.surfaceSize(),
                     "surfaceSize must return nil when there is no live surface")
    }
}
