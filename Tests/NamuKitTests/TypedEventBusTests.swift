import XCTest
@testable import Namu

final class TypedEventBusTests: XCTestCase {

    // MARK: - Publish and receive

    func testPublishAndReceive() async {
        let bus = TypedEventBus()
        let stream = await bus.subscribe()
        let id = UUID()

        await bus.publish(.workspaceCreated(id: id))

        var iterator = stream.makeAsyncIterator()
        let event = await iterator.next()
        if case .workspaceCreated(let receivedID) = event {
            XCTAssertEqual(receivedID, id)
        } else {
            XCTFail("Expected .workspaceCreated, got \(String(describing: event))")
        }
    }

    // MARK: - Multiple subscribers

    func testMultipleSubscribers() async {
        let bus = TypedEventBus()
        let stream1 = await bus.subscribe()
        let stream2 = await bus.subscribe()
        let id = UUID()

        await bus.publish(.workspaceDeleted(id: id))

        var iter1 = stream1.makeAsyncIterator()
        var iter2 = stream2.makeAsyncIterator()
        let event1 = await iter1.next()
        let event2 = await iter2.next()

        if case .workspaceDeleted(let id1) = event1 {
            XCTAssertEqual(id1, id)
        } else {
            XCTFail("Subscriber 1 did not receive .workspaceDeleted")
        }
        if case .workspaceDeleted(let id2) = event2 {
            XCTAssertEqual(id2, id)
        } else {
            XCTFail("Subscriber 2 did not receive .workspaceDeleted")
        }
    }

    // MARK: - Unsubscribe

    func testUnsubscribe() async {
        let bus = TypedEventBus()
        let stream = await bus.subscribe()

        // Cancel the stream (simulates unsubscribe via onTermination)
        let task = Task {
            for await _ in stream { }
        }
        task.cancel()

        // Subsequent publishes must not crash
        await bus.publish(.workspaceCreated(id: UUID()))
        await bus.publish(.workspaceCreated(id: UUID()))
        // If we reach here without crashing, the test passes
    }

    // MARK: - Different event types

    func testDifferentEventTypes() async {
        let bus = TypedEventBus()
        let stream = await bus.subscribe()

        let panelID = UUID()
        let workspaceID = UUID()

        await bus.publish(.paneCreated(panelID: panelID, workspaceID: workspaceID))
        await bus.publish(.paneClosed(panelID: panelID, workspaceID: workspaceID))
        await bus.publish(.workspaceSelected(id: workspaceID))

        var iter = stream.makeAsyncIterator()

        let e1 = await iter.next()
        if case .paneCreated(let pid, let wid) = e1 {
            XCTAssertEqual(pid, panelID)
            XCTAssertEqual(wid, workspaceID)
        } else {
            XCTFail("Expected .paneCreated")
        }

        let e2 = await iter.next()
        if case .paneClosed(let pid, let wid) = e2 {
            XCTAssertEqual(pid, panelID)
            XCTAssertEqual(wid, workspaceID)
        } else {
            XCTFail("Expected .paneClosed")
        }

        let e3 = await iter.next()
        if case .workspaceSelected(let wid) = e3 {
            XCTAssertEqual(wid, workspaceID)
        } else {
            XCTFail("Expected .workspaceSelected")
        }
    }
}
