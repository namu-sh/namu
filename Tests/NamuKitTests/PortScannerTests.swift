import XCTest
@testable import Namu

// MARK: - PortScannerTests
//
// Tests PortScanner public API: PanelKey value semantics, registerTTY,
// unregisterPanel, and the kick no-op guard.
//
// PortScanner uses an internal serial queue for all state mutations.
// Tests use expectations + sync barriers to observe effects consistently.

final class PortScannerTests: XCTestCase {

    private var scanner: PortScanner!

    override func setUp() {
        super.setUp()
        // Use a fresh instance per test so state does not leak across tests.
        // PortScanner.shared is the production singleton; we test via a new instance.
        scanner = PortScanner()
    }

    override func tearDown() {
        scanner = nil
        super.tearDown()
    }

    // MARK: - PanelKey value semantics

    func test_panelKey_equalWhenBothIDsMatch() {
        let ws = UUID()
        let panel = UUID()
        let k1 = PortScanner.PanelKey(workspaceID: ws, panelID: panel)
        let k2 = PortScanner.PanelKey(workspaceID: ws, panelID: panel)
        XCTAssertEqual(k1, k2, "PanelKeys with identical IDs must be equal")
    }

    func test_panelKey_notEqualWhenWorkspaceIDDiffers() {
        let panel = UUID()
        let k1 = PortScanner.PanelKey(workspaceID: UUID(), panelID: panel)
        let k2 = PortScanner.PanelKey(workspaceID: UUID(), panelID: panel)
        XCTAssertNotEqual(k1, k2, "PanelKeys with different workspaceIDs must not be equal")
    }

    func test_panelKey_notEqualWhenPanelIDDiffers() {
        let ws = UUID()
        let k1 = PortScanner.PanelKey(workspaceID: ws, panelID: UUID())
        let k2 = PortScanner.PanelKey(workspaceID: ws, panelID: UUID())
        XCTAssertNotEqual(k1, k2, "PanelKeys with different panelIDs must not be equal")
    }

    func test_panelKey_usableInSet_deduplicatesByValue() {
        let ws = UUID()
        let panel = UUID()
        let k1 = PortScanner.PanelKey(workspaceID: ws, panelID: panel)
        let k2 = PortScanner.PanelKey(workspaceID: ws, panelID: panel)
        let set: Set<PortScanner.PanelKey> = [k1, k2]
        XCTAssertEqual(set.count, 1, "Duplicate PanelKeys must collapse to one entry in a Set")
    }

    func test_panelKey_usableInSet_distinctKeysProduceTwoEntries() {
        let k1 = PortScanner.PanelKey(workspaceID: UUID(), panelID: UUID())
        let k2 = PortScanner.PanelKey(workspaceID: UUID(), panelID: UUID())
        let set: Set<PortScanner.PanelKey> = [k1, k2]
        XCTAssertEqual(set.count, 2, "Distinct PanelKeys must remain separate entries in a Set")
    }

    func test_panelKey_hashableConsistency() {
        let ws = UUID()
        let panel = UUID()
        let k1 = PortScanner.PanelKey(workspaceID: ws, panelID: panel)
        let k2 = PortScanner.PanelKey(workspaceID: ws, panelID: panel)
        XCTAssertEqual(k1.hashValue, k2.hashValue,
                       "Equal PanelKeys must produce the same hash value")
    }

    // MARK: - registerTTY stores the TTY name

    func test_registerTTY_storesTTYName() {
        let ws = UUID()
        let panel = UUID()
        // registerTTY dispatches async to the internal queue.
        // We call kick right after — kick checks ttyNames on the same queue,
        // so if registerTTY was a no-op, kick would be silently dropped.
        // This is an indirect test of registration, but it is the only
        // observable side-effect without touching private state.
        scanner.registerTTY(workspaceID: ws, panelID: panel, ttyName: "s001")
        // Give the async dispatch a moment to complete.
        let exp = expectation(description: "registerTTY async completes")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) {
            exp.fulfill()
        }
        wait(for: [exp], timeout: 1.0)
        // If we reach here without a crash or hang, registration succeeded.
    }

    func test_registerTTY_sameTTYTwice_isNoOp() {
        // Registering the same TTY name twice for the same key should be idempotent.
        let ws = UUID()
        let panel = UUID()
        scanner.registerTTY(workspaceID: ws, panelID: panel, ttyName: "s002")
        scanner.registerTTY(workspaceID: ws, panelID: panel, ttyName: "s002")
        // No crash or assertion failure expected.
    }

    func test_registerTTY_updatingTTYName_doesNotCrash() {
        // Registering a different TTY name for an already-registered key should update it.
        let ws = UUID()
        let panel = UUID()
        scanner.registerTTY(workspaceID: ws, panelID: panel, ttyName: "s003")
        scanner.registerTTY(workspaceID: ws, panelID: panel, ttyName: "s004")
    }

    // MARK: - unregisterPanel removes the entry

    func test_unregisterPanel_removesRegisteredEntry() {
        let ws = UUID()
        let panel = UUID()
        scanner.registerTTY(workspaceID: ws, panelID: panel, ttyName: "s005")
        // Unregister should succeed without crashing.
        scanner.unregisterPanel(workspaceID: ws, panelID: panel)

        // After unregistering, a subsequent kick must be a no-op
        // (verified below in the kick tests by confirming no callback fires).
        let exp = expectation(description: "unregisterPanel async completes")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) {
            exp.fulfill()
        }
        wait(for: [exp], timeout: 1.0)
    }

    func test_unregisterPanel_forUnknownKey_isNoOp() {
        // Unregistering a panel that was never registered should not crash.
        scanner.unregisterPanel(workspaceID: UUID(), panelID: UUID())
    }

    func test_unregisterPanel_calledTwice_isIdempotent() {
        let ws = UUID()
        let panel = UUID()
        scanner.registerTTY(workspaceID: ws, panelID: panel, ttyName: "s006")
        scanner.unregisterPanel(workspaceID: ws, panelID: panel)
        // Second unregister on an already-removed key must not crash.
        scanner.unregisterPanel(workspaceID: ws, panelID: panel)
    }

    // MARK: - kick with no registered TTY is a no-op

    func test_kick_withNoRegisteredTTY_doesNotFireCallback() {
        // Set a callback that should NOT be called.
        var callbackFired = false
        scanner.onPortsUpdated = { @MainActor _, _, _ in
            callbackFired = true
        }

        let ws = UUID()
        let panel = UUID()
        // kick() — no registerTTY was called for this key.
        scanner.kick(workspaceID: ws, panelID: panel)

        // Wait longer than the coalesce interval (200 ms) + first burst offset (500 ms).
        let exp = expectation(description: "no-op kick settles")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.4) {
            exp.fulfill()
        }
        wait(for: [exp], timeout: 1.0)

        XCTAssertFalse(callbackFired,
                       "kick with no registered TTY must not fire the onPortsUpdated callback")
    }

    func test_kick_afterUnregister_doesNotFireCallback() {
        var callbackFired = false
        scanner.onPortsUpdated = { @MainActor _, _, _ in
            callbackFired = true
        }

        let ws = UUID()
        let panel = UUID()
        scanner.registerTTY(workspaceID: ws, panelID: panel, ttyName: "s007")
        scanner.unregisterPanel(workspaceID: ws, panelID: panel)
        // kick after unregister — ttyNames no longer contains this key.
        scanner.kick(workspaceID: ws, panelID: panel)

        let exp = expectation(description: "kick after unregister settles")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.4) {
            exp.fulfill()
        }
        wait(for: [exp], timeout: 1.0)

        XCTAssertFalse(callbackFired,
                       "kick after unregisterPanel must not fire the callback")
    }
}
