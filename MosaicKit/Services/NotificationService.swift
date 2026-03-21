import Foundation
import Combine

// MARK: - InAppNotification

/// A single in-app notification entry.
struct InAppNotification: Identifiable, Sendable {
    let id: UUID
    let title: String
    let body: String
    let workspaceID: UUID?
    let panelID: UUID?
    let createdAt: Date
    var isRead: Bool

    init(
        id: UUID = UUID(),
        title: String,
        body: String,
        workspaceID: UUID? = nil,
        panelID: UUID? = nil,
        createdAt: Date = Date(),
        isRead: Bool = false
    ) {
        self.id = id
        self.title = title
        self.body = body
        self.workspaceID = workspaceID
        self.panelID = panelID
        self.createdAt = createdAt
        self.isRead = isRead
    }
}

// MARK: - NotificationService

/// In-app notification ring system.
///
/// Ring hierarchy (matching Namu patterns):
///   global   → updates unread count for the whole app (dock badge)
///   workspace → sidebar badge on the relevant workspace tab
///   pane      → ring indicator on the pane that triggered the notification
///
/// The ring has a bounded capacity: oldest notifications are dropped when the ring is full.
@MainActor
final class NotificationService: ObservableObject {

    // MARK: - Configuration

    /// Maximum number of notifications retained in the ring.
    static let ringCapacity = 256

    // MARK: - Published state

    @Published private(set) var allNotifications: [InAppNotification] = []

    // MARK: - Computed

    var unreadCount: Int {
        allNotifications.filter { !$0.isRead }.count
    }

    func unreadCountForWorkspace(_ workspaceID: UUID) -> Int {
        allNotifications.filter { !$0.isRead && $0.workspaceID == workspaceID }.count
    }

    func unreadCountForPanel(_ panelID: UUID) -> Int {
        allNotifications.filter { !$0.isRead && $0.panelID == panelID }.count
    }

    // MARK: - Create

    /// Add a notification to the ring. Drops the oldest entry if at capacity.
    @discardableResult
    func create(
        title: String,
        body: String,
        workspaceID: UUID? = nil,
        panelID: UUID? = nil
    ) -> InAppNotification {
        let notification = InAppNotification(
            title: title,
            body: body,
            workspaceID: workspaceID,
            panelID: panelID
        )

        if allNotifications.count >= Self.ringCapacity {
            allNotifications.removeFirst()
        }
        allNotifications.append(notification)
        return notification
    }

    // MARK: - Mark read

    func markRead(id: UUID) {
        guard let idx = allNotifications.firstIndex(where: { $0.id == id }) else { return }
        allNotifications[idx].isRead = true
    }

    func markAllRead() {
        for idx in allNotifications.indices {
            allNotifications[idx].isRead = true
        }
    }

    func markAllRead(workspaceID: UUID) {
        for idx in allNotifications.indices where allNotifications[idx].workspaceID == workspaceID {
            allNotifications[idx].isRead = true
        }
    }

    // MARK: - Remove

    func remove(id: UUID) {
        allNotifications.removeAll { $0.id == id }
    }

    /// Clear notifications. If workspaceID is nil, clears all. Returns the number cleared.
    @discardableResult
    func clearAll(workspaceID: UUID?) -> Int {
        if let wsID = workspaceID {
            let before = allNotifications.count
            allNotifications.removeAll { $0.workspaceID == wsID }
            return before - allNotifications.count
        } else {
            let count = allNotifications.count
            allNotifications.removeAll()
            return count
        }
    }
}
