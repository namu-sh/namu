import XCTest
@testable import Namu

final class PaneTreeTests: XCTestCase {

    // MARK: - Single pane

    func testSinglePaneCount() {
        let leaf = PaneLeaf(id: UUID(), panelType: .terminal)
        let tree = PaneTree.pane(leaf)
        XCTAssertEqual(tree.paneCount, 1)
    }

    func testSinglePaneFindPane() {
        let leaf = PaneLeaf(id: UUID(), panelType: .terminal)
        let tree = PaneTree.pane(leaf)
        XCTAssertNotNil(tree.findPane(id: leaf.id))
        XCTAssertNil(tree.findPane(id: UUID()))
    }

    func testSinglePaneAllPanels() {
        let leaf = PaneLeaf(id: UUID(), panelType: .terminal)
        let tree = PaneTree.pane(leaf)
        XCTAssertEqual(tree.allPanels.count, 1)
        XCTAssertEqual(tree.allPanels.first?.id, leaf.id)
    }

    // MARK: - insertSplit

    func testInsertSplitHorizontal() {
        let left = PaneLeaf(id: UUID())
        var tree = PaneTree.pane(left)
        let right = PaneLeaf(id: UUID())
        tree = tree.insertSplit(at: left.id, direction: .horizontal, newPanel: PaneLeaf(id: right.id))
        XCTAssertEqual(tree.paneCount, 2)
        XCTAssertNotNil(tree.findPane(id: left.id))
        XCTAssertNotNil(tree.findPane(id: right.id))
    }

    func testInsertSplitVertical() {
        let top = PaneLeaf(id: UUID())
        var tree = PaneTree.pane(top)
        let bottom = PaneLeaf(id: UUID())
        tree = tree.insertSplit(at: top.id, direction: .vertical, newPanel: PaneLeaf(id: bottom.id))
        XCTAssertEqual(tree.paneCount, 2)
    }

    func testInsertSplitNested() {
        let a = PaneLeaf(id: UUID())
        let b = PaneLeaf(id: UUID())
        let c = PaneLeaf(id: UUID())
        var tree = PaneTree.pane(a)
        tree = tree.insertSplit(at: a.id, direction: .horizontal, newPanel: PaneLeaf(id: b.id))
        tree = tree.insertSplit(at: b.id, direction: .vertical, newPanel: PaneLeaf(id: c.id))
        XCTAssertEqual(tree.paneCount, 3)
        XCTAssertNotNil(tree.findPane(id: a.id))
        XCTAssertNotNil(tree.findPane(id: b.id))
        XCTAssertNotNil(tree.findPane(id: c.id))
    }

    func testInsertSplitUnknownIdNoOp() {
        let leaf = PaneLeaf(id: UUID(), panelType: .terminal)
        let tree = PaneTree.pane(leaf)
        let result = tree.insertSplit(at: UUID(), direction: .horizontal, newPanel: PaneLeaf(id: UUID()))
        // Unknown ID — tree should be unchanged
        XCTAssertEqual(result.paneCount, tree.paneCount)
    }

    // MARK: - removePane

    func testRemovePaneFromSplit() {
        let left = PaneLeaf(id: UUID())
        let right = PaneLeaf(id: UUID())
        var tree = PaneTree.pane(left)
        tree = tree.insertSplit(at: left.id, direction: .horizontal, newPanel: PaneLeaf(id: right.id))
        let reduced = tree.removePane(id: right.id)
        XCTAssertNotNil(reduced)
        XCTAssertEqual(reduced?.paneCount, 1)
        XCTAssertNotNil(reduced?.findPane(id: left.id))
    }

    func testRemoveSinglePaneReturnsNil() {
        let leaf = PaneLeaf(id: UUID(), panelType: .terminal)
        let tree = PaneTree.pane(leaf)
        let result = tree.removePane(id: leaf.id)
        XCTAssertNil(result)
    }

    func testRemoveNonExistentPaneNoOp() {
        let a = PaneLeaf(id: UUID())
        let b = PaneLeaf(id: UUID())
        var tree = PaneTree.pane(a)
        tree = tree.insertSplit(at: a.id, direction: .horizontal, newPanel: PaneLeaf(id: b.id))
        let result = tree.removePane(id: UUID())
        XCTAssertEqual(result?.paneCount, 2)
    }

    // MARK: - allPanels ordering

    func testAllPanelsOrderIsDepthFirstLeftToRight() {
        let a = PaneLeaf(id: UUID())
        let b = PaneLeaf(id: UUID())
        let c = PaneLeaf(id: UUID())
        var tree = PaneTree.pane(a)
        tree = tree.insertSplit(at: a.id, direction: .horizontal, newPanel: PaneLeaf(id: b.id))
        tree = tree.insertSplit(at: b.id, direction: .horizontal, newPanel: PaneLeaf(id: c.id))
        let ids = tree.allPanels.map(\.id)
        XCTAssertEqual(ids.count, 3)
        XCTAssertTrue(ids.contains(a.id))
        XCTAssertTrue(ids.contains(b.id))
        XCTAssertTrue(ids.contains(c.id))
    }

    // MARK: - Codable round-trip

    func testCodableRoundTrip() throws {
        let a = PaneLeaf(id: UUID())
        let b = PaneLeaf(id: UUID())
        var tree = PaneTree.pane(a)
        tree = tree.insertSplit(at: a.id, direction: .vertical, newPanel: PaneLeaf(id: b.id))

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        let data = try encoder.encode(tree)
        let decoded = try decoder.decode(PaneTree.self, from: data)

        XCTAssertEqual(decoded.paneCount, 2)
        XCTAssertNotNil(decoded.findPane(id: a.id))
        XCTAssertNotNil(decoded.findPane(id: b.id))
    }
}
