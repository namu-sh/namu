import XCTest
@testable import Namu

// MARK: - EqualizeSplitsTests
//
// Tests for PaneTree.equalized() and the PanelManager proportional
// equalize logic (equalizeNode / leafCount).
//
// PaneTreeTests and ReviewFixTests already cover the basic 2-pane and
// nested-2-pane cases.  These tests add:
//   - A 4-leaf balanced tree to confirm all levels are set to 0.5
//   - Proportional ratio: tree where first subtree has 3 leaves and
//     second has 1 leaf → ratio = 3/(3+1) = 0.75
//   - PanelManager.equalizeSplits integration via the public API

// MARK: - PaneTree.equalized() additional cases

final class EqualizeSplitsTests: XCTestCase {

    // MARK: - equalized() on a 4-leaf balanced tree

    func test_equalized_fourLeafBalancedTree_allRatiosAreHalf() {
        // Build:  split( split(A,B), split(C,D) )
        let a = PaneLeaf(id: UUID())
        let b = PaneLeaf(id: UUID())
        let c = PaneLeaf(id: UUID())
        let d = PaneLeaf(id: UUID())

        let left  = PaneSplit(direction: .horizontal, ratio: 0.9,
                              first: .pane(a), second: .pane(b))
        let right = PaneSplit(direction: .horizontal, ratio: 0.1,
                              first: .pane(c), second: .pane(d))
        let root  = PaneSplit(direction: .vertical,   ratio: 0.3,
                              first: .split(left), second: .split(right))
        let tree  = PaneTree.split(root)

        let result = tree.equalized()

        guard case .split(let rootS) = result else {
            return XCTFail("Expected root split")
        }
        XCTAssertEqual(rootS.ratio, 0.5, "Root split ratio should be 0.5 after equalize")

        guard case .split(let leftS) = rootS.first else {
            return XCTFail("Expected left split")
        }
        XCTAssertEqual(leftS.ratio, 0.5, "Left split ratio should be 0.5 after equalize")

        guard case .split(let rightS) = rootS.second else {
            return XCTFail("Expected right split")
        }
        XCTAssertEqual(rightS.ratio, 0.5, "Right split ratio should be 0.5 after equalize")
    }

    // MARK: - equalized() preserves pane identities

    func test_equalized_preservesAllPaneIDs() {
        let a = PaneLeaf(id: UUID())
        let b = PaneLeaf(id: UUID())
        let c = PaneLeaf(id: UUID())

        let inner = PaneSplit(direction: .horizontal, ratio: 0.8,
                              first: .pane(a), second: .pane(b))
        let outer = PaneSplit(direction: .vertical,   ratio: 0.2,
                              first: .split(inner), second: .pane(c))
        let tree  = PaneTree.split(outer)

        let result = tree.equalized()

        XCTAssertNotNil(result.findPane(id: a.id), "Pane A must survive equalize")
        XCTAssertNotNil(result.findPane(id: b.id), "Pane B must survive equalize")
        XCTAssertNotNil(result.findPane(id: c.id), "Pane C must survive equalize")
        XCTAssertEqual(result.paneCount, 3)
    }

    // MARK: - equalized() on a single pane is identity

    func test_equalized_singlePane_isUnchanged() {
        let leaf  = PaneLeaf(id: UUID())
        let tree  = PaneTree.pane(leaf)
        let result = tree.equalized()
        XCTAssertEqual(result.paneCount, 1)
        guard case .pane(let l) = result else {
            return XCTFail("Expected .pane case")
        }
        XCTAssertEqual(l.id, leaf.id)
    }

    // MARK: - equalized() directionally-mixed tree

    func test_equalized_mixedDirections_allRatiosAreHalf() {
        // Horizontal outer, vertical inner
        let a = PaneLeaf(id: UUID())
        let b = PaneLeaf(id: UUID())
        let c = PaneLeaf(id: UUID())

        let inner = PaneSplit(direction: .vertical,   ratio: 0.6,
                              first: .pane(a), second: .pane(b))
        let outer = PaneSplit(direction: .horizontal, ratio: 0.7,
                              first: .split(inner), second: .pane(c))
        let tree  = PaneTree.split(outer)
        let result = tree.equalized()

        guard case .split(let outerS) = result else { return XCTFail("Expected outer split") }
        XCTAssertEqual(outerS.ratio, 0.5, accuracy: 0.0001)
        guard case .split(let innerS) = outerS.first else { return XCTFail("Expected inner split") }
        XCTAssertEqual(innerS.ratio, 0.5, accuracy: 0.0001)
    }

    // MARK: - PanelManager.equalizeSplits proportional ratio

    // The PanelManager uses leafCount to set proportional ratios, not 0.5.
    // For a split with 3 leaves on the left and 1 leaf on the right:
    //   ratio = 3 / (3 + 1) = 0.75
    //
    // We build this tree via the public API and verify equalizeSplits fires
    // without crashing (the ratio assertion requires Bonsplit access).

    @MainActor
    func test_equalizeSplits_doesNotCrashWithMultiplePanes() {
        let wm = WorkspaceManager()
        let pm = PanelManager(workspaceManager: wm)
        guard let wsID = wm.selectedWorkspaceID else {
            return XCTFail("Expected initial workspace")
        }

        // Add 2 more splits so there are 3 panes total.
        pm.splitActivePanel(direction: .horizontal)
        pm.splitActivePanel(direction: .vertical)
        XCTAssertEqual(pm.allPanelIDs(in: wsID).count, 3,
                       "Should have 3 panes before equalize")

        // equalizeSplits must complete without crashing.
        let changed = pm.equalizeSplits(in: wsID)
        // At least one split exists so the call should report a change.
        XCTAssertTrue(changed, "equalizeSplits should report at least one divider was moved")
    }

    @MainActor
    func test_equalizeSplits_singlePane_returnsNoChange() {
        let wm = WorkspaceManager()
        let pm = PanelManager(workspaceManager: wm)
        guard let wsID = wm.selectedWorkspaceID else {
            return XCTFail("Expected initial workspace")
        }

        // Single pane: no splits → nothing to equalize.
        let changed = pm.equalizeSplits(in: wsID)
        XCTAssertFalse(changed,
                       "equalizeSplits on a single-pane workspace should return false")
    }

    @MainActor
    func test_equalizeSplits_twoPanes_reportsChange() {
        let wm = WorkspaceManager()
        let pm = PanelManager(workspaceManager: wm)
        guard let wsID = wm.selectedWorkspaceID else {
            return XCTFail("Expected initial workspace")
        }

        pm.splitActivePanel(direction: .horizontal)
        XCTAssertEqual(pm.allPanelIDs(in: wsID).count, 2)

        let changed = pm.equalizeSplits(in: wsID)
        XCTAssertTrue(changed,
                      "equalizeSplits on a two-pane workspace should move the divider")
    }

    @MainActor
    func test_equalizeSplits_orientationFilter_verticalOnlyLeavesHorizontalUntouched() {
        let wm = WorkspaceManager()
        let pm = PanelManager(workspaceManager: wm)
        guard let wsID = wm.selectedWorkspaceID else {
            return XCTFail("Expected initial workspace")
        }

        // Create one horizontal split.
        pm.splitActivePanel(direction: .horizontal)

        // Equalize with orientation filter "vertical" — no vertical splits exist,
        // so no change should be reported.
        let changed = pm.equalizeSplits(in: wsID, orientation: "vertical")
        XCTAssertFalse(changed,
                       "equalizeSplits with orientation=vertical on a horizontal split should return false")
    }
}
