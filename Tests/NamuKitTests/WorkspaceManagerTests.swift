import XCTest
@testable import Namu

@MainActor
final class WorkspaceManagerTests: XCTestCase {

    private func makeManager() -> WorkspaceManager {
        WorkspaceManager()
    }

    // MARK: - Init

    func testInitCreatesOneWorkspace() {
        let manager = makeManager()
        XCTAssertEqual(manager.workspaces.count, 1)
        XCTAssertNotNil(manager.selectedWorkspaceID)
    }

    func testInitialWorkspaceIsSelected() {
        let manager = makeManager()
        XCTAssertEqual(manager.selectedWorkspaceID, manager.workspaces.first?.id)
    }

    // MARK: - Create

    func testCreateWorkspaceAppends() {
        let manager = makeManager()
        let ws = manager.createWorkspace(title: "Second")
        XCTAssertEqual(manager.workspaces.count, 2)
        XCTAssertEqual(ws.title, "Second")
    }

    func testCreateWorkspaceOrderIncreases() {
        let manager = makeManager()
        let ws1 = manager.createWorkspace(title: "A")
        let ws2 = manager.createWorkspace(title: "B")
        XCTAssertGreaterThan(ws1.order, manager.workspaces.first!.order)
        XCTAssertGreaterThan(ws2.order, ws1.order)
    }

    // MARK: - Select

    func testSelectWorkspace() {
        let manager = makeManager()
        let ws = manager.createWorkspace(title: "Second")
        manager.selectWorkspace(id: ws.id)
        XCTAssertEqual(manager.selectedWorkspaceID, ws.id)
        XCTAssertEqual(manager.selectedWorkspace?.id, ws.id)
    }

    func testSelectNonexistentWorkspaceNoOp() {
        let manager = makeManager()
        let originalID = manager.selectedWorkspaceID
        manager.selectWorkspace(id: UUID())
        XCTAssertEqual(manager.selectedWorkspaceID, originalID)
    }

    // MARK: - Delete

    func testDeleteNonSelectedWorkspace() {
        let manager = makeManager()
        let ws = manager.createWorkspace(title: "To Delete")
        let originalSelected = manager.selectedWorkspaceID
        manager.deleteWorkspace(id: ws.id)
        XCTAssertEqual(manager.workspaces.count, 1)
        XCTAssertEqual(manager.selectedWorkspaceID, originalSelected)
    }

    func testDeleteSelectedWorkspaceSwitchesToAdjacent() {
        let manager = makeManager()
        let ws2 = manager.createWorkspace(title: "Second")
        manager.selectWorkspace(id: ws2.id)
        manager.deleteWorkspace(id: ws2.id)
        XCTAssertEqual(manager.workspaces.count, 1)
        XCTAssertNotNil(manager.selectedWorkspaceID)
        XCTAssertEqual(manager.selectedWorkspaceID, manager.workspaces.first?.id)
    }

    func testDeleteLastWorkspaceIsNoOp() {
        let manager = makeManager()
        XCTAssertEqual(manager.workspaces.count, 1)
        manager.deleteWorkspace(id: manager.workspaces.first!.id)
        XCTAssertEqual(manager.workspaces.count, 1)
    }

    // MARK: - Rename

    func testRenameWorkspace() {
        let manager = makeManager()
        guard let ws = manager.workspaces.first else { return XCTFail() }
        manager.renameWorkspace(id: ws.id, title: "Renamed")
        XCTAssertEqual(manager.workspaces.first?.title, "Renamed")
    }

    func testRenameNonexistentWorkspaceNoOp() {
        let manager = makeManager()
        let originalTitle = manager.workspaces.first?.title
        manager.renameWorkspace(id: UUID(), title: "X")
        XCTAssertEqual(manager.workspaces.first?.title, originalTitle)
    }

    // MARK: - Pin

    func testPinWorkspace() {
        let manager = makeManager()
        guard let ws = manager.workspaces.first else { return XCTFail() }
        XCTAssertFalse(ws.isPinned)
        manager.pinWorkspace(id: ws.id)
        XCTAssertTrue(manager.workspaces.first?.isPinned ?? false)
    }

    func testUnpinWorkspace() {
        let manager = makeManager()
        guard let ws = manager.workspaces.first else { return XCTFail() }
        manager.pinWorkspace(id: ws.id)
        manager.pinWorkspace(id: ws.id)
        XCTAssertFalse(manager.workspaces.first?.isPinned ?? true)
    }

    // MARK: - Reorder

    func testReorderWorkspaces() {
        let manager = makeManager()
        manager.createWorkspace(title: "B")
        manager.createWorkspace(title: "C")
        XCTAssertEqual(manager.workspaces.count, 3)
        let originalLast = manager.workspaces.last!.id
        manager.reorderWorkspace(from: IndexSet(integer: 2), to: 0)
        XCTAssertEqual(manager.workspaces.first?.id, originalLast)
    }

    // MARK: - Color

    func testSetWorkspaceColor() {
        let manager = makeManager()
        guard let id = manager.workspaces.first?.id else { return XCTFail() }
        manager.setWorkspaceColor(id: id, color: "#0088FF")
        XCTAssertEqual(manager.workspaces.first?.customColor, "#0088FF")
    }

    func testClearWorkspaceColor() {
        let manager = makeManager()
        guard let id = manager.workspaces.first?.id else { return XCTFail() }
        manager.setWorkspaceColor(id: id, color: "#FF0000")
        manager.setWorkspaceColor(id: id, color: nil)
        XCTAssertNil(manager.workspaces.first?.customColor)
    }
}
