import XCTest
@testable import Namu
import Bonsplit

@MainActor
final class PanelManagerTests: XCTestCase {

    private func makeStack() -> (WorkspaceManager, PanelManager) {
        let wm = WorkspaceManager()
        let pm = PanelManager(workspaceManager: wm)
        return (wm, pm)
    }

    // MARK: - Workspace creation is single entry point

    func testCreateWorkspaceBootstrapsEngine() {
        let (_, pm) = makeStack()
        let ws = pm.createWorkspace(title: "Test")

        // Engine should exist
        let eng = pm.engine(for: ws.id)
        XCTAssertFalse(eng.allPaneIDs.isEmpty, "Engine should have at least one pane")
    }

    func testCreateWorkspaceHasTerminalTab() {
        let (_, pm) = makeStack()
        let ws = pm.createWorkspace(title: "Test")
        let eng = pm.engine(for: ws.id)

        // Should have exactly one pane with one terminal tab (no Welcome tab)
        let paneIDs = eng.allPaneIDs
        XCTAssertEqual(paneIDs.count, 1)

        let tabs = eng.controller.tabs(inPane: paneIDs[0])
        XCTAssertEqual(tabs.count, 1, "Should have exactly one tab (terminal, not Welcome)")

        // Tab should be mapped to a panel
        let panelID = eng.panelID(for: tabs[0].id)
        XCTAssertNotNil(panelID, "Tab should be mapped to a panel")
        XCTAssertNotNil(pm.panel(for: panelID!), "Panel should exist in registry")
    }

    func testCreateWorkspaceNoWelcomeTab() {
        let (_, pm) = makeStack()
        let ws = pm.createWorkspace(title: "Test")
        let eng = pm.engine(for: ws.id)

        // Verify no tab is named "Welcome"
        for paneID in eng.allPaneIDs {
            for tab in eng.controller.tabs(inPane: paneID) {
                XCTAssertNotEqual(tab.title, "Welcome", "Welcome tab should be removed")
            }
        }
    }

    func testCreateWorkspaceSelectsNewWorkspace() {
        let (wm, pm) = makeStack()
        let originalID = wm.selectedWorkspaceID

        let ws = pm.createWorkspace(title: "New")
        XCTAssertEqual(wm.selectedWorkspaceID, ws.id, "New workspace should be selected")
        XCTAssertNotEqual(wm.selectedWorkspaceID, originalID)
    }

    // MARK: - Bootstrap restored workspace

    func testBootstrapRestoredWorkspaceMapsExistingPanels() {
        let (wm, pm) = makeStack()

        // Simulate session restore: create a workspace with a panel manually
        let panelID = UUID()
        let leaf = PaneLeaf(id: panelID, panelType: .terminal)
        let ws = Workspace(
            id: UUID(),
            title: "Restored",
            paneTree: .pane(leaf)
        )
        // Create the panel in PanelManager's registry (as SessionPersistence would)
        pm.restoreTerminalPanel(id: panelID, workingDirectory: nil, scrollbackFile: nil)

        // Now bootstrap it
        pm.bootstrapRestoredWorkspace(ws)

        let eng = pm.engine(for: ws.id)
        let allTabs = eng.allPaneIDs.flatMap { eng.controller.tabs(inPane: $0) }

        // Should have a tab mapped to our restored panel
        let mappedIDs = allTabs.compactMap { eng.panelID(for: $0.id) }
        XCTAssertTrue(mappedIDs.contains(panelID), "Restored panel should be mapped to a tab")

        // No Welcome tab
        XCTAssertFalse(allTabs.contains { $0.title == "Welcome" })
    }

    // MARK: - Split pane

    func testSplitPaneCreatesNewTerminal() {
        let (wm, pm) = makeStack()
        guard let wsID = wm.selectedWorkspaceID else { return XCTFail() }

        let panelsBefore = pm.allPanelIDs(in: wsID)
        XCTAssertEqual(panelsBefore.count, 1)

        pm.splitPane(in: wsID, direction: .horizontal)

        let panelsAfter = pm.allPanelIDs(in: wsID)
        XCTAssertEqual(panelsAfter.count, 2, "Split should create a second panel")
    }

    func testSplitPaneSyncsWorkspace() {
        let (wm, pm) = makeStack()
        guard let wsID = wm.selectedWorkspaceID else { return XCTFail() }

        pm.splitPane(in: wsID, direction: .vertical)

        // Workspace's paneTree should be synced from engine
        guard let ws = wm.selectedWorkspace else { return XCTFail() }
        XCTAssertEqual(ws.paneTree.paneCount, 2, "Workspace paneTree should reflect split")
    }

    // MARK: - Close panel

    func testClosePanelRemovesFromEngine() {
        let (wm, pm) = makeStack()
        guard let wsID = wm.selectedWorkspaceID else { return XCTFail() }

        pm.splitPane(in: wsID, direction: .horizontal)
        let panels = pm.allPanelIDs(in: wsID)
        XCTAssertEqual(panels.count, 2)

        pm.closePanel(id: panels[1])
        XCTAssertEqual(pm.allPanelIDs(in: wsID).count, 1)
        XCTAssertNil(pm.panel(for: panels[1]), "Closed panel should be removed from registry")
    }

    // MARK: - Focus / activation

    func testActivatePanelChangesFocus() {
        let (wm, pm) = makeStack()
        guard let wsID = wm.selectedWorkspaceID else { return XCTFail() }

        pm.splitPane(in: wsID, direction: .horizontal)
        let panels = pm.allPanelIDs(in: wsID)
        XCTAssertEqual(panels.count, 2)

        // After split, the new panel should be focused
        let focusedAfterSplit = pm.focusedPanelID(in: wsID)
        XCTAssertEqual(focusedAfterSplit, panels[1])

        // Activate the first panel
        pm.activatePanel(id: panels[0])
        XCTAssertEqual(pm.focusedPanelID(in: wsID), panels[0])
    }

    func testActivatePanelTracksPreviousFocus() {
        let (wm, pm) = makeStack()
        guard let wsID = wm.selectedWorkspaceID else { return XCTFail() }

        pm.splitPane(in: wsID, direction: .horizontal)
        let panels = pm.allPanelIDs(in: wsID)

        let firstFocused = panels[1] // after split, new panel is focused
        pm.activatePanel(id: panels[0])

        XCTAssertEqual(pm.previousFocusedPanelID, firstFocused)
    }

    func testFocusedPanelIDSyncsToWorkspace() {
        let (wm, pm) = makeStack()
        guard let wsID = wm.selectedWorkspaceID else { return XCTFail() }

        pm.splitPane(in: wsID, direction: .horizontal)
        let panels = pm.allPanelIDs(in: wsID)
        pm.activatePanel(id: panels[0])

        // Workspace.activePanelID should be synced
        guard let ws = wm.selectedWorkspace else { return XCTFail() }
        XCTAssertEqual(ws.activePanelID, panels[0], "Workspace activePanelID should match focused panel")
    }

    // MARK: - Workspace lifecycle

    func testOnWorkspaceDeletedCleansUpEngine() {
        let (wm, pm) = makeStack()
        let ws = pm.createWorkspace(title: "ToDelete")
        let wsID = ws.id

        XCTAssertNotNil(pm.engines[wsID])

        pm.onWorkspaceDeleted(workspaceID: wsID)
        wm.deleteWorkspace(id: wsID)

        XCTAssertNil(pm.engines[wsID], "Engine should be removed on workspace deletion")
    }

    // MARK: - Panel lookup

    func testPanelForUnknownIDReturnsNil() {
        let (_, pm) = makeStack()
        XCTAssertNil(pm.panel(for: UUID()))
    }

    func testWorkspaceIDForPanel() {
        let (_, pm) = makeStack()
        let ws = pm.createWorkspace(title: "Test")
        let panels = pm.allPanelIDs(in: ws.id)
        XCTAssertFalse(panels.isEmpty)

        let foundWSID = pm.workspaceIDForPanel(panels[0])
        XCTAssertEqual(foundWSID, ws.id)
    }

    func testWorkspaceIDForUnknownPanelReturnsNil() {
        let (_, pm) = makeStack()
        XCTAssertNil(pm.workspaceIDForPanel(UUID()))
    }

    // MARK: - Multiple workspaces isolation

    func testMultipleWorkspacesHaveIndependentEngines() {
        let (_, pm) = makeStack()
        let ws1 = pm.createWorkspace(title: "WS1")
        let ws2 = pm.createWorkspace(title: "WS2")

        let panels1 = pm.allPanelIDs(in: ws1.id)
        let panels2 = pm.allPanelIDs(in: ws2.id)

        // Each workspace should have its own panel
        XCTAssertEqual(panels1.count, 1)
        XCTAssertEqual(panels2.count, 1)
        XCTAssertNotEqual(panels1[0], panels2[0], "Different workspaces should have different panels")
    }

    // MARK: - Process running check

    func testIsProcessRunningForUnknownPanel() {
        let (_, pm) = makeStack()
        XCTAssertFalse(pm.isProcessRunning(id: UUID()))
    }
}
