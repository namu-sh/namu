import XCTest
@testable import Namu

@MainActor
final class PanelManagerTests: XCTestCase {

    private var wm: WorkspaceManager!
    private var pm: PanelManager!
    /// The workspace ID created by WorkspaceManager.init()
    private var initialWSID: UUID!

    override func setUp() {
        super.setUp()
        wm = WorkspaceManager()
        pm = PanelManager(workspaceManager: wm)
        initialWSID = wm.selectedWorkspaceID
    }

    override func tearDown() {
        // Clean up all engines and panels to avoid leaked state
        for wsID in Array(pm.engines.keys) {
            pm.deleteWorkspace(id: wsID)
        }
        pm = nil
        wm = nil
        initialWSID = nil
        super.tearDown()
    }

    // MARK: - Initial state

    func testInitialWorkspaceHasOneTerminal() {
        let panels = pm.allPanelIDs(in: initialWSID)
        XCTAssertEqual(panels.count, 1, "Initial workspace should have exactly one terminal")
        XCTAssertNotNil(pm.panel(for: panels[0]))
    }

    func testInitialWorkspaceHasNoWelcomeTab() {
        let eng = pm.engine(for: initialWSID)
        for paneID in eng.allPaneIDs {
            for tab in eng.controller.tabs(inPane: paneID) {
                XCTAssertNotEqual(tab.title, "Welcome")
            }
        }
    }

    // MARK: - Workspace creation (single entry point)

    func testCreateWorkspaceBootstrapsEngine() {
        let ws = pm.createWorkspace(title: "Test")
        XCTAssertNotNil(pm.engines[ws.id], "Engine should exist after creation")
        XCTAssertFalse(pm.engine(for: ws.id).allPaneIDs.isEmpty)
    }

    func testCreateWorkspaceHasOneTerminalTab() {
        let ws = pm.createWorkspace(title: "Test")
        let eng = pm.engine(for: ws.id)
        let paneIDs = eng.allPaneIDs

        XCTAssertEqual(paneIDs.count, 1, "Should have exactly one pane")
        let tabs = eng.controller.tabs(inPane: paneIDs[0])
        XCTAssertEqual(tabs.count, 1, "Should have exactly one tab")
        XCTAssertNotNil(eng.panelID(for: tabs[0].id), "Tab should be mapped to a panel")
    }

    func testCreateWorkspaceNoWelcomeTab() {
        let ws = pm.createWorkspace(title: "Test")
        let eng = pm.engine(for: ws.id)
        for paneID in eng.allPaneIDs {
            for tab in eng.controller.tabs(inPane: paneID) {
                XCTAssertNotEqual(tab.title, "Welcome", "Welcome tab must be removed")
            }
        }
    }

    func testCreateWorkspaceAutoSelects() {
        let ws = pm.createWorkspace(title: "New")
        XCTAssertEqual(wm.selectedWorkspaceID, ws.id, "New workspace should be auto-selected")
    }

    func testCreateWorkspaceDoesNotCorruptInitial() {
        let initialPanels = pm.allPanelIDs(in: initialWSID)
        _ = pm.createWorkspace(title: "Extra")
        let panelsAfter = pm.allPanelIDs(in: initialWSID)
        XCTAssertEqual(initialPanels, panelsAfter, "Creating a new workspace should not affect the initial one")
    }

    // MARK: - Structural constraint

    func testDirectWMCreationDoesNotBootstrap() {
        let ws = wm.createWorkspace(title: "Raw")
        XCTAssertNil(pm.engines[ws.id], "Direct WM creation must not auto-bootstrap engine")
    }

    // MARK: - Bootstrap restored workspace

    func testBootstrapRestoredWorkspaceMapsExistingPanels() {
        let panelID = UUID()
        let ws = Workspace(id: UUID(), title: "Restored")

        pm.restoreTerminalPanel(id: panelID, workingDirectory: nil, scrollbackFile: nil)
        pm.bootstrapRestoredWorkspace(ws, panelIDs: [panelID], activePanelID: panelID)

        let eng = pm.engine(for: ws.id)
        let allTabs = eng.allPaneIDs.flatMap { eng.controller.tabs(inPane: $0) }
        let mappedIDs = allTabs.compactMap { eng.panelID(for: $0.id) }

        XCTAssertTrue(mappedIDs.contains(panelID), "Restored panel should be mapped to a tab")
        XCTAssertFalse(allTabs.contains { $0.title == "Welcome" }, "No Welcome tab after restore")
    }

    func testBootstrapRestoredMultiplePanels() {
        let id1 = UUID(), id2 = UUID()
        let ws = Workspace(id: UUID(), title: "Multi")

        pm.restoreTerminalPanel(id: id1, workingDirectory: nil, scrollbackFile: nil)
        pm.restoreTerminalPanel(id: id2, workingDirectory: nil, scrollbackFile: nil)
        pm.bootstrapRestoredWorkspace(ws, panelIDs: [id1, id2], activePanelID: id1)

        let panelIDs = pm.allPanelIDs(in: ws.id)
        XCTAssertTrue(panelIDs.contains(id1))
        XCTAssertTrue(panelIDs.contains(id2))
    }

    // MARK: - Split pane

    func testSplitPaneCreatesSecondPanel() {
        pm.splitPane(in: initialWSID, direction: .horizontal)
        XCTAssertEqual(pm.allPanelIDs(in: initialWSID).count, 2)
    }

    func testSplitPaneSyncsWorkspacePaneTree() {
        pm.splitPane(in: initialWSID, direction: .vertical)
        guard let ws = wm.selectedWorkspace else { return XCTFail() }
        XCTAssertEqual(pm.allPanelIDs(in: initialWSID).count, 2, "Workspace paneTree should reflect the split")
    }

    func testSplitPaneFocusesNewPanel() {
        let panelsBefore = pm.allPanelIDs(in: initialWSID)
        pm.splitPane(in: initialWSID, direction: .horizontal)
        let panelsAfter = pm.allPanelIDs(in: initialWSID)
        let newPanel = panelsAfter.first { !panelsBefore.contains($0) }

        XCTAssertNotNil(newPanel)
        XCTAssertEqual(pm.focusedPanelID(in: initialWSID), newPanel, "New split panel should be focused")
    }

    // MARK: - Close panel

    func testClosePanelRemovesFromEngine() {
        pm.splitPane(in: initialWSID, direction: .horizontal)
        let panels = pm.allPanelIDs(in: initialWSID)
        XCTAssertEqual(panels.count, 2)

        pm.closePanel(id: panels[1])
        XCTAssertEqual(pm.allPanelIDs(in: initialWSID).count, 1)
        XCTAssertNil(pm.panel(for: panels[1]))
    }

    func testClosePanelSyncsWorkspace() {
        pm.splitPane(in: initialWSID, direction: .horizontal)
        let panels = pm.allPanelIDs(in: initialWSID)
        pm.closePanel(id: panels[1])

        guard let ws = wm.selectedWorkspace else { return XCTFail() }
        XCTAssertEqual(pm.allPanelIDs(in: initialWSID).count, 1, "paneTree should sync after close")
    }

    // MARK: - Focus / activation

    func testActivatePanelChangesFocus() {
        pm.splitPane(in: initialWSID, direction: .horizontal)
        let panels = pm.allPanelIDs(in: initialWSID)

        pm.activatePanel(id: panels[0])
        XCTAssertEqual(pm.focusedPanelID(in: initialWSID), panels[0])

        pm.activatePanel(id: panels[1])
        XCTAssertEqual(pm.focusedPanelID(in: initialWSID), panels[1])
    }

    func testActivatePanelTracksPreviousFocus() {
        pm.splitPane(in: initialWSID, direction: .horizontal)
        let panels = pm.allPanelIDs(in: initialWSID)
        let focusedAfterSplit = pm.focusedPanelID(in: initialWSID)

        pm.activatePanel(id: panels[0])
        XCTAssertEqual(pm.previousFocusedPanelID, focusedAfterSplit)
    }

    func testFocusedPanelIDSyncsToWorkspace() {
        pm.splitPane(in: initialWSID, direction: .horizontal)
        let panels = pm.allPanelIDs(in: initialWSID)
        pm.activatePanel(id: panels[0])

        guard let ws = wm.selectedWorkspace else { return XCTFail() }
        XCTAssertEqual(pm.focusedPanelID(in: initialWSID), panels[0])
    }

    // MARK: - Workspace deletion

    func testDeleteWorkspaceCleansUpEngine() {
        let ws = pm.createWorkspace(title: "Temp")
        XCTAssertNotNil(pm.engines[ws.id])

        pm.deleteWorkspace(id: ws.id)

        XCTAssertNil(pm.engines[ws.id])
        XCTAssertTrue(pm.allPanelIDs(in: ws.id).isEmpty)
    }

    func testDeleteWorkspaceDoesNotAffectOthers() {
        let ws = pm.createWorkspace(title: "Temp")
        let initialPanels = pm.allPanelIDs(in: initialWSID)

        pm.deleteWorkspace(id: ws.id)

        XCTAssertEqual(pm.allPanelIDs(in: initialWSID), initialPanels)
    }

    // MARK: - Panel lookup

    func testPanelForUnknownIDReturnsNil() {
        XCTAssertNil(pm.panel(for: UUID()))
    }

    func testWorkspaceIDForPanel() {
        let panels = pm.allPanelIDs(in: initialWSID)
        XCTAssertEqual(pm.workspaceIDForPanel(panels[0]), initialWSID)
    }

    func testWorkspaceIDForUnknownPanelReturnsNil() {
        XCTAssertNil(pm.workspaceIDForPanel(UUID()))
    }

    // MARK: - Multi-workspace isolation

    func testMultipleWorkspacesHaveIndependentPanels() {
        let ws1 = pm.createWorkspace(title: "WS1")
        let ws2 = pm.createWorkspace(title: "WS2")

        let panels1 = pm.allPanelIDs(in: ws1.id)
        let panels2 = pm.allPanelIDs(in: ws2.id)

        XCTAssertEqual(panels1.count, 1)
        XCTAssertEqual(panels2.count, 1)
        XCTAssertNotEqual(panels1[0], panels2[0])
    }

    func testSplitInOneWorkspaceDoesNotAffectAnother() {
        let ws2 = pm.createWorkspace(title: "WS2")
        pm.splitPane(in: initialWSID, direction: .horizontal)

        XCTAssertEqual(pm.allPanelIDs(in: initialWSID).count, 2)
        XCTAssertEqual(pm.allPanelIDs(in: ws2.id).count, 1, "Other workspace should be unaffected")
    }

    // MARK: - Process running check

    func testIsProcessRunningForUnknownPanel() {
        XCTAssertFalse(pm.isProcessRunning(id: UUID()))
    }

    // MARK: - Split + close cycle (no leaked tabs)

    func testSplitAndCloseReturnsToSinglePane() {
        pm.splitPane(in: initialWSID, direction: .horizontal)
        pm.splitPane(in: initialWSID, direction: .vertical)
        XCTAssertEqual(pm.allPanelIDs(in: initialWSID).count, 3)

        let panels = pm.allPanelIDs(in: initialWSID)
        pm.closePanel(id: panels[2])
        pm.closePanel(id: panels[1])
        XCTAssertEqual(pm.allPanelIDs(in: initialWSID).count, 1, "Should return to single pane")
    }

    func testRepeatedCreateDeleteDoesNotLeak() {
        for i in 0..<5 {
            let ws = pm.createWorkspace(title: "Temp\(i)")
            XCTAssertEqual(pm.allPanelIDs(in: ws.id).count, 1)
            pm.onWorkspaceDeleted(workspaceID: ws.id)
            wm.deleteWorkspace(id: ws.id)
        }
        // Only the initial workspace should remain
        XCTAssertEqual(wm.workspaces.count, 1)
        XCTAssertEqual(pm.engines.count, 1)
    }
}
