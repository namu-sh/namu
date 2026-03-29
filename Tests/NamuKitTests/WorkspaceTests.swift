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

    private var wm: WorkspaceManager!
    private var pm: PanelManager!

    override func setUp() {
        super.setUp()
        wm = WorkspaceManager()
        pm = PanelManager(workspaceManager: wm)
    }

    override func tearDown() {
        for wsID in Array(pm.engines.keys) {
            pm.deleteWorkspace(id: wsID)
        }
        pm = nil
        wm = nil
        super.tearDown()
    }

    func testInitialWorkspaceHasEngineAndTerminal() {
        guard let wsID = wm.selectedWorkspaceID else { return XCTFail() }
        let panels = pm.allPanelIDs(in: wsID)
        XCTAssertEqual(panels.count, 1)
        XCTAssertNotNil(pm.panel(for: panels[0]))
    }

    func testDirectWMCreationDoesNotBootstrap() {
        let ws = wm.createWorkspace(title: "Raw")
        XCTAssertNil(pm.engines[ws.id])
    }

    func testPMCreationBootstrapsAndSelects() {
        let ws = pm.createWorkspace(title: "Proper")
        XCTAssertNotNil(pm.engines[ws.id])
        XCTAssertEqual(pm.allPanelIDs(in: ws.id).count, 1)
        XCTAssertEqual(wm.selectedWorkspaceID, ws.id)
    }

    func testDeleteWorkspaceCleansUp() {
        let ws = pm.createWorkspace(title: "Temp")
        pm.deleteWorkspace(id: ws.id)

        XCTAssertEqual(wm.workspaces.count, 1)
        XCTAssertNil(pm.engines[ws.id])
    }

    func testSplitAndCloseReturnsToSinglePane() {
        guard let wsID = wm.selectedWorkspaceID else { return XCTFail() }
        pm.splitPane(in: wsID, direction: .horizontal)
        let panels = pm.allPanelIDs(in: wsID)
        pm.closePanel(id: panels[1])
        XCTAssertEqual(pm.allPanelIDs(in: wsID).count, 1)
    }

    func testWorkspacePaneTreeStaysInSync() {
        guard let wsID = wm.selectedWorkspaceID else { return XCTFail() }
        pm.splitPane(in: wsID, direction: .vertical)
        XCTAssertEqual(pm.allPanelIDs(in: wsID).count, 2)
        XCTAssertNotNil(pm.focusedPanelID(in: wsID))
    }
}
