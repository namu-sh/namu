import XCTest
@testable import Namu

final class WorkspaceTests: XCTestCase {
    func testWorkspaceCreation() {
        let workspace = Workspace(title: "Test")
        XCTAssertEqual(workspace.title, "Test")
        XCTAssertEqual(workspace.order, 0)
        XCTAssertFalse(workspace.isPinned)
    }

    func testPaneTreeSinglePane() {
        let leaf = PaneLeaf(panelType: .terminal)
        let tree = PaneTree.pane(leaf)
        XCTAssertEqual(tree.paneCount, 1)
        XCTAssertNotNil(tree.findPane(id: leaf.id))
    }

    func testPaneTreeSplit() {
        let left = PaneLeaf(panelType: .terminal)
        let right = PaneLeaf(panelType: .terminal)
        let tree = PaneTree.split(PaneSplit(
            direction: .horizontal,
            first: .pane(left),
            second: .pane(right)
        ))
        XCTAssertEqual(tree.paneCount, 2)
        XCTAssertNotNil(tree.findPane(id: left.id))
        XCTAssertNotNil(tree.findPane(id: right.id))
    }

    func testSessionSnapshotVersion() {
        let snapshot = SessionSnapshot()
        XCTAssertEqual(snapshot.version, 3)
    }

    // MARK: - HandlerRegistration CQRS

    func testHandlerRegistrationMetadata() {
        let registry = CommandRegistry()
        let reg = HandlerRegistration(
            method: "test.query",
            execution: .background,
            safety: .safe,
            handler: { req in .success(id: req.id, result: .null) }
        )
        registry.register(reg)

        XCTAssertNotNil(registry.handler(for: "test.query"))

        let retrieved = registry.registration(for: "test.query")
        XCTAssertNotNil(retrieved)
        XCTAssertEqual(retrieved?.method, "test.query")
        XCTAssertEqual(retrieved?.safety, .safe)
    }

    // MARK: - PaneSnapshot v3 panelIds

    func testPaneSnapshotV3PanelIds() throws {
        let paneID = UUID()
        let panelID1 = UUID()
        let panelID2 = UUID()
        let snap = PaneSnapshot(
            id: paneID,
            panelType: .terminal,
            panelIds: [panelID1, panelID2],
            selectedPanelId: panelID1
        )

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        let data = try encoder.encode(snap)
        let decoded = try decoder.decode(PaneSnapshot.self, from: data)

        XCTAssertEqual(decoded.panelIds?.count, 2)
        XCTAssertEqual(decoded.panelIds?[0], panelID1)
        XCTAssertEqual(decoded.selectedPanelId, panelID1)
    }

    func testPaneSnapshotV2MigrationNilPanelIds() throws {
        // Simulates a v2 snapshot where panelIds is absent
        let paneID = UUID()
        let snap = PaneSnapshot(
            id: paneID,
            panelType: .terminal
        )

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        let data = try encoder.encode(snap)
        let decoded = try decoder.decode(PaneSnapshot.self, from: data)

        // panelIds should be nil for v2 snapshots; callers default to [id]
        XCTAssertNil(decoded.panelIds)
        XCTAssertNil(decoded.selectedPanelId)
    }

    // MARK: - SessionState

    func testSessionStateTransitions() throws {
        var state = SessionState.created
        XCTAssertTrue(state.isAlive)
        XCTAssertFalse(state.isInteractive)

        try state.handle(.start)
        XCTAssertEqual(state, .starting)

        try state.handle(.surfaceReady)
        XCTAssertEqual(state, .running)
        XCTAssertTrue(state.isInteractive)

        try state.handle(.childExited(0))
        XCTAssertEqual(state, .exited(code: 0))
        XCTAssertFalse(state.isAlive)

        try state.handle(.destroy)
        XCTAssertEqual(state, .destroyed)
    }

    func testSessionStateInvalidTransition() {
        var state = SessionState.destroyed
        XCTAssertThrowsError(try state.handle(.start))
    }
}
