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

    // MARK: - equalized()

    func testEqualizedSinglePane() {
        let leaf = PaneLeaf(id: UUID(), panelType: .terminal)
        let tree = PaneTree.pane(leaf)
        let result = tree.equalized()
        // Single pane — tree is unchanged, still a .pane case
        XCTAssertEqual(result.paneCount, 1)
        XCTAssertNotNil(result.findPane(id: leaf.id))
    }

    func testEqualizedSplitSetsRatioToHalf() {
        let left = PaneLeaf(id: UUID())
        let right = PaneLeaf(id: UUID())
        let split = PaneSplit(direction: .horizontal, ratio: 0.7, first: .pane(left), second: .pane(right))
        let tree = PaneTree.split(split)
        let result = tree.equalized()
        // Verify ratio reset to 0.5
        guard case .split(let s) = result else { return XCTFail("Expected split") }
        XCTAssertEqual(s.ratio, 0.5)
    }

    func testEqualizedNestedSplits() {
        let a = PaneLeaf(id: UUID())
        let b = PaneLeaf(id: UUID())
        let c = PaneLeaf(id: UUID())
        // Build: split(split(a, b, ratio:0.8), c, ratio:0.3)
        let inner = PaneSplit(direction: .horizontal, ratio: 0.8, first: .pane(a), second: .pane(b))
        let outer = PaneSplit(direction: .vertical, ratio: 0.3, first: .split(inner), second: .pane(c))
        let tree = PaneTree.split(outer)
        let result = tree.equalized()
        guard case .split(let outerS) = result else { return XCTFail("Expected outer split") }
        XCTAssertEqual(outerS.ratio, 0.5, "outer ratio should be 0.5")
        guard case .split(let innerS) = outerS.first else { return XCTFail("Expected inner split") }
        XCTAssertEqual(innerS.ratio, 0.5, "inner ratio should be 0.5")
    }

    // MARK: - adjustSplitRatio()

    func testAdjustSplitRatioHorizontal() {
        let left = PaneLeaf(id: UUID())
        let right = PaneLeaf(id: UUID())
        let split = PaneSplit(id: UUID(), direction: .horizontal, ratio: 0.5, first: .pane(left), second: .pane(right))
        let tree = PaneTree.split(split)
        // Grow left pane rightward — ratio should increase
        let result = tree.adjustSplitRatio(containing: left.id, direction: GHOSTTY_RESIZE_SPLIT_RIGHT, delta: 0.1)
        XCTAssertNotNil(result)
        if let (splitID, newRatio) = result {
            XCTAssertEqual(splitID, split.id)
            XCTAssertGreaterThan(newRatio, 0.5)
        }
    }

    func testAdjustSplitRatioVertical() {
        let top = PaneLeaf(id: UUID())
        let bottom = PaneLeaf(id: UUID())
        let split = PaneSplit(id: UUID(), direction: .vertical, ratio: 0.5, first: .pane(top), second: .pane(bottom))
        let tree = PaneTree.split(split)
        // Grow top pane downward — ratio should increase
        let result = tree.adjustSplitRatio(containing: top.id, direction: GHOSTTY_RESIZE_SPLIT_DOWN, delta: 0.1)
        XCTAssertNotNil(result)
        if let (splitID, newRatio) = result {
            XCTAssertEqual(splitID, split.id)
            XCTAssertGreaterThan(newRatio, 0.5)
        }
    }

    func testAdjustSplitRatioClamps() {
        let left = PaneLeaf(id: UUID())
        let right = PaneLeaf(id: UUID())
        let split = PaneSplit(id: UUID(), direction: .horizontal, ratio: 0.92, first: .pane(left), second: .pane(right))
        let tree = PaneTree.split(split)
        // Delta that would push ratio beyond 1.0 — must be clamped to 0.95
        let result = tree.adjustSplitRatio(containing: left.id, direction: GHOSTTY_RESIZE_SPLIT_RIGHT, delta: 0.1)
        XCTAssertNotNil(result)
        if let (_, newRatio) = result {
            XCTAssertLessThanOrEqual(newRatio, 0.95)
            XCTAssertGreaterThanOrEqual(newRatio, 0.05)
        }
    }

    func testAdjustSplitRatioWrongAxis() {
        let left = PaneLeaf(id: UUID())
        let right = PaneLeaf(id: UUID())
        // Horizontal split — vertical direction should not match
        let split = PaneSplit(id: UUID(), direction: .horizontal, ratio: 0.5, first: .pane(left), second: .pane(right))
        let tree = PaneTree.split(split)
        let result = tree.adjustSplitRatio(containing: left.id, direction: GHOSTTY_RESIZE_SPLIT_DOWN, delta: 0.1)
        XCTAssertNil(result, "Vertical direction on a horizontal split should return nil")
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
