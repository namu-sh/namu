import XCTest
import Bonsplit
@testable import Namu

final class NamuLayoutSnapshotTests: XCTestCase {

    // MARK: - Pane node round-trip

    func testPaneNodeRoundTrip() throws {
        let id = UUID()
        let snapshot = NamuLayoutSnapshot.pane(id: id, panelType: "terminal")

        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(NamuLayoutSnapshot.self, from: data)

        XCTAssertEqual(decoded.type, .pane)
        XCTAssertEqual(decoded.id, id)
        XCTAssertEqual(decoded.panelType, "terminal")
        XCTAssertNil(decoded.orientation)
        XCTAssertNil(decoded.ratio)
        XCTAssertNil(decoded.first)
        XCTAssertNil(decoded.second)
    }

    // MARK: - Split node round-trip

    func testSplitNodeRoundTrip() throws {
        let paneAID = UUID()
        let paneBID = UUID()
        let splitID = UUID()

        let paneA = NamuLayoutSnapshot.pane(id: paneAID, panelType: "terminal")
        let paneB = NamuLayoutSnapshot.pane(id: paneBID, panelType: "browser")
        let split = NamuLayoutSnapshot.split(
            id: splitID,
            orientation: .horizontal,
            ratio: 0.6,
            first: paneA,
            second: paneB
        )

        let data = try JSONEncoder().encode(split)
        let decoded = try JSONDecoder().decode(NamuLayoutSnapshot.self, from: data)

        XCTAssertEqual(decoded.type, .split)
        XCTAssertEqual(decoded.id, splitID)
        XCTAssertEqual(decoded.orientation, .horizontal)
        XCTAssertEqual(decoded.ratio, 0.6)
        XCTAssertNotNil(decoded.first)
        XCTAssertNotNil(decoded.second)
        XCTAssertEqual(decoded.first?.id, paneAID)
        XCTAssertEqual(decoded.second?.id, paneBID)
    }

    // MARK: - Nested split round-trip

    func testNestedSplitRoundTrip() throws {
        let idA = UUID()
        let idB = UUID()
        let idC = UUID()
        let innerSplitID = UUID()
        let outerSplitID = UUID()

        let paneA = NamuLayoutSnapshot.pane(id: idA, panelType: "terminal")
        let paneB = NamuLayoutSnapshot.pane(id: idB, panelType: "terminal")
        let paneC = NamuLayoutSnapshot.pane(id: idC, panelType: "terminal")

        let innerSplit = NamuLayoutSnapshot.split(
            id: innerSplitID,
            orientation: .horizontal,
            ratio: 0.5,
            first: paneA,
            second: paneB
        )
        let outerSplit = NamuLayoutSnapshot.split(
            id: outerSplitID,
            orientation: .vertical,
            ratio: 0.4,
            first: innerSplit,
            second: paneC
        )

        let data = try JSONEncoder().encode(outerSplit)
        let decoded = try JSONDecoder().decode(NamuLayoutSnapshot.self, from: data)

        // Outer
        XCTAssertEqual(decoded.type, .split)
        XCTAssertEqual(decoded.id, outerSplitID)
        XCTAssertEqual(decoded.orientation, .vertical)

        // Inner (first child of outer)
        guard let inner = decoded.first else { return XCTFail("Missing first child") }
        XCTAssertEqual(inner.type, .split)
        XCTAssertEqual(inner.id, innerSplitID)
        XCTAssertEqual(inner.orientation, .horizontal)

        // Leaves under inner split
        XCTAssertEqual(inner.first?.id, idA)
        XCTAssertEqual(inner.second?.id, idB)

        // Outer second child
        XCTAssertEqual(decoded.second?.id, idC)
        XCTAssertEqual(decoded.second?.type, .pane)
    }

    // MARK: - Pane node properties preserved

    func testPaneNodeProperties() throws {
        let id = UUID()
        let snapshot = NamuLayoutSnapshot.pane(id: id, panelType: "browser")

        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(NamuLayoutSnapshot.self, from: data)

        XCTAssertEqual(decoded.panelType, "browser")
        XCTAssertEqual(decoded.id, id)
        XCTAssertEqual(decoded.type, .pane)
    }

    // MARK: - Split node properties preserved

    func testSplitNodeProperties() throws {
        let firstID = UUID()
        let secondID = UUID()
        let splitID = UUID()

        let split = NamuLayoutSnapshot.split(
            id: splitID,
            orientation: .vertical,
            ratio: 0.7,
            first: NamuLayoutSnapshot.pane(id: firstID),
            second: NamuLayoutSnapshot.pane(id: secondID)
        )

        let data = try JSONEncoder().encode(split)
        let decoded = try JSONDecoder().decode(NamuLayoutSnapshot.self, from: data)

        XCTAssertEqual(decoded.orientation, .vertical)
        XCTAssertEqual(decoded.ratio, 0.7)
        XCTAssertEqual(decoded.first?.id, firstID)
        XCTAssertEqual(decoded.second?.id, secondID)
        XCTAssertNil(decoded.panelType, "Split nodes should not have panelType")
    }
}
