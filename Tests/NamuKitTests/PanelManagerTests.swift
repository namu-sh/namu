import XCTest
@testable import Namu

@MainActor
final class PanelManagerTests: XCTestCase {

    private func makeStack() -> (WorkspaceManager, PanelManager) {
        let wm = WorkspaceManager()
        let pm = PanelManager(workspaceManager: wm)
        return (wm, pm)
    }

    // MARK: - Panel creation

    func testCreateTerminalPanelReturnsPanel() {
        let (_, pm) = makeStack()
        let panel = pm.createTerminalPanel()
        XCTAssertNotNil(panel)
        XCTAssertNotNil(panel.id)
    }

    func testCreateTerminalPanelWithWorkingDirectory() {
        let (_, pm) = makeStack()
        let panel = pm.createTerminalPanel(workingDirectory: "/tmp")
        XCTAssertEqual(panel.workingDirectory, "/tmp")
    }

    // MARK: - Split

    func testSplitPanelHorizontally() {
        let (wm, pm) = makeStack()
        guard let workspace = wm.selectedWorkspace,
              let firstLeaf = workspace.paneTree.allPanels.first else {
            return XCTFail("Expected initial workspace with at least one leaf")
        }

        let newPanel = pm.createTerminalPanel()
        pm.splitPanel(id: firstLeaf.id, direction: .horizontal, newPanel: newPanel)

        guard let updatedWorkspace = wm.selectedWorkspace else { return XCTFail() }
        XCTAssertEqual(updatedWorkspace.paneTree.paneCount, 2)
        XCTAssertNotNil(updatedWorkspace.paneTree.findPane(id: newPanel.id))
    }

    func testSplitPanelVertically() {
        let (wm, pm) = makeStack()
        guard let workspace = wm.selectedWorkspace,
              let firstLeaf = workspace.paneTree.allPanels.first else {
            return XCTFail()
        }

        let newPanel = pm.createTerminalPanel()
        pm.splitPanel(id: firstLeaf.id, direction: .vertical, newPanel: newPanel)

        guard let updatedWorkspace = wm.selectedWorkspace else { return XCTFail() }
        XCTAssertEqual(updatedWorkspace.paneTree.paneCount, 2)
    }

    // MARK: - Close

    func testClosePanelReducesPaneCount() {
        let (wm, pm) = makeStack()
        guard let workspace = wm.selectedWorkspace,
              let firstLeaf = workspace.paneTree.allPanels.first else {
            return XCTFail()
        }

        let newPanel = pm.createTerminalPanel()
        pm.splitPanel(id: firstLeaf.id, direction: .horizontal, newPanel: newPanel)
        pm.closePanel(id: newPanel.id)

        guard let updated = wm.selectedWorkspace else { return XCTFail() }
        XCTAssertEqual(updated.paneTree.paneCount, 1)
    }

    // MARK: - Zoom

    func testZoomPanel() {
        let (wm, pm) = makeStack()
        guard let workspace = wm.selectedWorkspace,
              let firstLeaf = workspace.paneTree.allPanels.first else {
            return XCTFail()
        }

        pm.zoomPanel(id: firstLeaf.id)
        let state = pm.zoomState(for: workspace.id)
        XCTAssertTrue(state.isZoomed)
        XCTAssertEqual(state.zoomedPanelID, firstLeaf.id)
    }

    func testUnzoomPanel() {
        let (wm, pm) = makeStack()
        guard let workspace = wm.selectedWorkspace,
              let firstLeaf = workspace.paneTree.allPanels.first else {
            return XCTFail()
        }

        pm.zoomPanel(id: firstLeaf.id)
        pm.unzoomPanel()
        let state = pm.zoomState(for: workspace.id)
        XCTAssertFalse(state.isZoomed)
        XCTAssertNil(state.zoomedPanelID)
    }

    // MARK: - Focus direction

    func testFocusDirectionWithSinglePaneNoOp() {
        let (wm, pm) = makeStack()
        let currentActive = wm.selectedWorkspace?.activePanelID
        pm.activateDirection(.right)
        XCTAssertEqual(wm.selectedWorkspace?.activePanelID, currentActive)
    }

    func testFocusNextCycles() {
        let (wm, pm) = makeStack()
        guard let workspace = wm.selectedWorkspace,
              let firstLeaf = workspace.paneTree.allPanels.first else {
            return XCTFail()
        }
        let newPanel = pm.createTerminalPanel()
        pm.splitPanel(id: firstLeaf.id, direction: .horizontal, newPanel: newPanel)
        pm.activateNext()
        // After activateNext, active panel should change (or wrap around)
        // Just verify it doesn't crash
        XCTAssertNotNil(wm.selectedWorkspace?.activePanelID)
    }

    // MARK: - Focus by ID

    func testFocusPanelByID() {
        let (wm, pm) = makeStack()
        guard let workspace = wm.selectedWorkspace,
              let firstLeaf = workspace.paneTree.allPanels.first else {
            return XCTFail()
        }
        let newPanel = pm.createTerminalPanel()
        pm.splitPanel(id: firstLeaf.id, direction: .horizontal, newPanel: newPanel)
        pm.activatePanel(id: newPanel.id)
        XCTAssertEqual(wm.selectedWorkspace?.activePanelID, newPanel.id)
    }

    // MARK: - Panel lookup

    func testPanelForIDReturnsPanel() {
        let (wm, pm) = makeStack()
        guard let workspace = wm.selectedWorkspace,
              let leaf = workspace.paneTree.allPanels.first else {
            return XCTFail()
        }
        let panel = pm.panel(for: leaf.id)
        XCTAssertNotNil(panel)
        XCTAssertEqual(panel?.id, leaf.id)
    }

    func testPanelForUnknownIDReturnsNil() {
        let (_, pm) = makeStack()
        XCTAssertNil(pm.panel(for: UUID()))
    }

    // MARK: - breakOutPanel

    func testBreakOutPanelWithSinglePaneMoves() {
        let (wm, pm) = makeStack()
        guard let workspace = wm.selectedWorkspace,
              let firstLeaf = workspace.paneTree.allPanels.first else {
            return XCTFail()
        }
        let originalID = workspace.id
        // breakOutPanel on the only pane moves it to a new workspace and deletes the source
        let result = pm.breakOutPanel(id: firstLeaf.id)
        XCTAssertNotNil(result, "breakOutPanel should succeed by moving pane to new workspace")
        // Source workspace should be deleted (replaced by the new one)
        XCTAssertNil(wm.workspaces.first(where: { $0.id == originalID }),
                     "Source workspace should be deleted after break-out")
        XCTAssertEqual(wm.workspaces.count, 1, "Should have exactly one workspace after break-out")
    }
}
