import XCTest
@testable import Namu

final class WorkspacePlacementTests: XCTestCase {

    // MARK: - insertionIndex

    func test_top_insertsAfterPinnedWorkspaces() {
        // 2 pinned, 3 total → insert at index 2
        let idx = WorkspacePlacementSettings.insertionIndex(
            placement: .top,
            selectedIndex: 4,
            pinnedCount: 2,
            totalCount: 5
        )
        XCTAssertEqual(idx, 2)
    }

    func test_top_noPinned_insertsAtZero() {
        let idx = WorkspacePlacementSettings.insertionIndex(
            placement: .top,
            selectedIndex: 2,
            pinnedCount: 0,
            totalCount: 3
        )
        XCTAssertEqual(idx, 0)
    }

    func test_top_allPinned_insertsAtEnd() {
        let idx = WorkspacePlacementSettings.insertionIndex(
            placement: .top,
            selectedIndex: 1,
            pinnedCount: 3,
            totalCount: 3
        )
        XCTAssertEqual(idx, 3)
    }

    func test_end_appendsAtEnd() {
        let idx = WorkspacePlacementSettings.insertionIndex(
            placement: .end,
            selectedIndex: 0,
            pinnedCount: 1,
            totalCount: 4
        )
        XCTAssertEqual(idx, 4)
    }

    func test_end_emptyList_insertsAtZero() {
        let idx = WorkspacePlacementSettings.insertionIndex(
            placement: .end,
            selectedIndex: nil,
            pinnedCount: 0,
            totalCount: 0
        )
        XCTAssertEqual(idx, 0)
    }

    func test_afterCurrent_insertsAfterSelected() {
        let idx = WorkspacePlacementSettings.insertionIndex(
            placement: .afterCurrent,
            selectedIndex: 2,
            pinnedCount: 0,
            totalCount: 5
        )
        XCTAssertEqual(idx, 3)
    }

    func test_afterCurrent_lastItem_clampsToEnd() {
        let idx = WorkspacePlacementSettings.insertionIndex(
            placement: .afterCurrent,
            selectedIndex: 4,
            pinnedCount: 0,
            totalCount: 5
        )
        XCTAssertEqual(idx, 5)
    }

    func test_afterCurrent_noSelection_appendsAtEnd() {
        let idx = WorkspacePlacementSettings.insertionIndex(
            placement: .afterCurrent,
            selectedIndex: nil,
            pinnedCount: 1,
            totalCount: 3
        )
        XCTAssertEqual(idx, 3)
    }

    func test_afterCurrent_emptyList_insertsAtZero() {
        let idx = WorkspacePlacementSettings.insertionIndex(
            placement: .afterCurrent,
            selectedIndex: nil,
            pinnedCount: 0,
            totalCount: 0
        )
        XCTAssertEqual(idx, 0)
    }

    // MARK: - WorkspaceManager integration

    @MainActor func test_createWorkspace_placementEnd() {
        let manager = WorkspaceManager()
        // Initial workspace already exists at index 0
        manager.createWorkspace(placement: .end)
        XCTAssertEqual(manager.workspaces.count, 2)
        XCTAssertEqual(manager.workspaces[1].order, 1)
    }

    @MainActor func test_createWorkspace_placementTop_noPinned() {
        let manager = WorkspaceManager()
        manager.createWorkspace(placement: .top)
        XCTAssertEqual(manager.workspaces.count, 2)
        // With no pinned items, new workspace goes to index 0
        XCTAssertEqual(manager.workspaces[0].order, 0)
    }

    @MainActor func test_createWorkspace_placementTop_withPinned() {
        let manager = WorkspaceManager()
        // Pin the initial workspace
        manager.pinWorkspace(id: manager.workspaces[0].id)
        _ = manager.createWorkspace(title: "B")
        // Add a third at .top — should go after the 1 pinned item, at index 1
        let ws = manager.createWorkspace(title: "C", placement: .top)
        XCTAssertEqual(manager.workspaces.firstIndex(where: { $0.id == ws.id }), 1)
    }

    @MainActor func test_createWorkspace_placementAfterCurrent() {
        let manager = WorkspaceManager()
        let first = manager.workspaces[0]
        manager.selectWorkspace(id: first.id)
        _ = manager.createWorkspace(title: "B")
        // Select the first workspace and add afterCurrent
        manager.selectWorkspace(id: first.id)
        let ws = manager.createWorkspace(title: "C", placement: .afterCurrent)
        // "C" should be at index 1 (right after "first" which is at 0)
        XCTAssertEqual(manager.workspaces.firstIndex(where: { $0.id == ws.id }), 1)
    }

    @MainActor func test_reindexAfterInsertion() {
        let manager = WorkspaceManager()
        _ = manager.createWorkspace(title: "B", placement: .top)
        // After reindex, order values should match positions
        for (i, ws) in manager.workspaces.enumerated() {
            XCTAssertEqual(ws.order, i, "Workspace at index \(i) should have order \(i)")
        }
    }
}
