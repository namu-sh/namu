import XCTest
@testable import Mosaic

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
        XCTAssertEqual(snapshot.version, SessionSnapshot.currentVersion)
    }
}
