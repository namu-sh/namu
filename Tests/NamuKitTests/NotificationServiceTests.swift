import XCTest
@testable import Namu

final class NotificationServiceTests: XCTestCase {

    // MARK: - jumpToOldestUnread

    @MainActor func test_jumpToOldestUnread_returnsNil_whenNoNotifications() {
        let service = NotificationService()
        XCTAssertNil(service.jumpToOldestUnread())
    }

    @MainActor func test_jumpToOldestUnread_returnsNil_whenAllRead() {
        let service = NotificationService()
        let wsID = UUID()
        service.create(title: "A", body: "", workspaceID: wsID)
        service.markAllRead()
        XCTAssertNil(service.jumpToOldestUnread())
    }

    @MainActor func test_jumpToOldestUnread_returnsOldestUnreadWorkspace() {
        let service = NotificationService()
        let ws1 = UUID()
        let ws2 = UUID()

        // Create two notifications in order: ws1 first, ws2 second
        service.create(title: "First", body: "", workspaceID: ws1)
        service.create(title: "Second", body: "", workspaceID: ws2)

        // Oldest unread should be ws1
        XCTAssertEqual(service.jumpToOldestUnread(), ws1)
    }

    @MainActor func test_jumpToOldestUnread_skipsReadNotifications() {
        let service = NotificationService()
        let ws1 = UUID()
        let ws2 = UUID()

        service.create(title: "First", body: "", workspaceID: ws1)
        service.create(title: "Second", body: "", workspaceID: ws2)

        // Mark the first one read
        if let id = service.allNotifications.first?.id {
            service.markRead(id: id)
        }

        // Now the oldest unread should be ws2
        XCTAssertEqual(service.jumpToOldestUnread(), ws2)
    }

    @MainActor func test_jumpToOldestUnread_returnsNil_afterMarkAllRead() {
        let service = NotificationService()
        service.create(title: "A", body: "", workspaceID: UUID())
        service.create(title: "B", body: "", workspaceID: UUID())
        service.markAllRead()
        XCTAssertNil(service.jumpToOldestUnread())
    }

    @MainActor func test_jumpToOldestUnread_withNoWorkspaceID_returnsNil() {
        let service = NotificationService()
        // Notification with no workspaceID
        service.create(title: "No workspace", body: "")
        // jumpToOldestUnread returns workspaceID which will be nil
        let result = service.jumpToOldestUnread()
        // The notification exists but workspaceID is nil
        XCTAssertNil(result)
    }

    @MainActor func test_unreadCount_decreasesAfterMarkRead() {
        let service = NotificationService()
        service.create(title: "A", body: "", workspaceID: UUID())
        service.create(title: "B", body: "", workspaceID: UUID())
        XCTAssertEqual(service.unreadCount, 2)

        if let id = service.allNotifications.first?.id {
            service.markRead(id: id)
        }
        XCTAssertEqual(service.unreadCount, 1)
    }
}
