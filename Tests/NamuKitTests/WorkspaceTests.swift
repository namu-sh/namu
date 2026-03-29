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
        let paneID = UUID()
        let snap = PaneSnapshot(
            id: paneID,
            panelType: .terminal
        )

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        let data = try encoder.encode(snap)
        let decoded = try decoder.decode(PaneSnapshot.self, from: data)

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

// MARK: - WorkspaceManager + PanelManager integration

@MainActor
final class WorkspaceManagerIntegrationTests: XCTestCase {

    private func makeStack() -> (WorkspaceManager, PanelManager) {
        let wm = WorkspaceManager()
        let pm = PanelManager(workspaceManager: wm)
        return (wm, pm)
    }

    func testInitialWorkspaceHasEngineAndTerminal() {
        let (wm, pm) = makeStack()
        guard let wsID = wm.selectedWorkspaceID else { return XCTFail("No selected workspace") }

        let panels = pm.allPanelIDs(in: wsID)
        XCTAssertEqual(panels.count, 1, "Initial workspace should have one terminal panel")
        XCTAssertNotNil(pm.panel(for: panels[0]))
    }

    func testCreateWorkspaceViaManagerAloneDoesNotBootstrap() {
        // This verifies that calling workspaceManager.createWorkspace() directly
        // does NOT create an engine — proving the structural constraint.
        let (wm, pm) = makeStack()
        let ws = wm.createWorkspace(title: "Raw")

        // Engine won't exist until someone calls pm.engine(for:)
        XCTAssertNil(pm.engines[ws.id], "Direct WM creation should not auto-bootstrap engine")
    }

    func testCreateWorkspaceViaPanelManagerBootstraps() {
        let (wm, pm) = makeStack()
        let ws = pm.createWorkspace(title: "Proper")

        XCTAssertNotNil(pm.engines[ws.id], "PM creation should bootstrap engine")
        XCTAssertEqual(pm.allPanelIDs(in: ws.id).count, 1)
        XCTAssertEqual(wm.selectedWorkspaceID, ws.id, "Should auto-select new workspace")
    }

    func testDeleteWorkspaceAfterCreate() {
        let (wm, pm) = makeStack()
        let ws = pm.createWorkspace(title: "Temp")
        XCTAssertEqual(wm.workspaces.count, 2)

        pm.onWorkspaceDeleted(workspaceID: ws.id)
        wm.deleteWorkspace(id: ws.id)

        XCTAssertEqual(wm.workspaces.count, 1)
        XCTAssertNil(pm.engines[ws.id])
        XCTAssertTrue(pm.allPanelIDs(in: ws.id).isEmpty)
    }

    func testSplitAndCloseReturnsToSinglePane() {
        let (wm, pm) = makeStack()
        guard let wsID = wm.selectedWorkspaceID else { return XCTFail() }

        pm.splitPane(in: wsID, direction: .horizontal)
        XCTAssertEqual(pm.allPanelIDs(in: wsID).count, 2)

        let panels = pm.allPanelIDs(in: wsID)
        pm.closePanel(id: panels[1])
        XCTAssertEqual(pm.allPanelIDs(in: wsID).count, 1)
    }

    func testWorkspacePaneTreeStaysInSync() {
        let (wm, pm) = makeStack()
        guard let wsID = wm.selectedWorkspaceID else { return XCTFail() }

        // Split and verify paneTree is synced
        pm.splitPane(in: wsID, direction: .vertical)
        guard let ws = wm.workspaces.first(where: { $0.id == wsID }) else { return XCTFail() }
        XCTAssertEqual(ws.paneTree.paneCount, 2, "paneTree should sync after split")
        XCTAssertNotNil(ws.activePanelID, "activePanelID should be synced")
    }
}
