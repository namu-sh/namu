import Foundation
import Combine
import AppKit
import UserNotifications

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
// MARK: - NotificationSound

enum NotificationSound: String, CaseIterable, Codable {
    case none   = "None"
    case system = "System Default"
    case glass  = "Glass"
    case ping   = "Ping"
    case pop    = "Pop"
    case purr   = "Purr"

    /// NSSound name for macOS system sounds (nil = use NSSound.beep).
    var soundName: String? {
        switch self {
        case .none:   return nil
        case .system: return nil  // triggers NSSound.beep()
        case .glass:  return "Glass"
        case .ping:   return "Ping"
        case .pop:    return "Pop"
        case .purr:   return "Purr"
        }
    }
}

// MARK: - NotificationService

@MainActor
final class NotificationService: ObservableObject {

    // MARK: - Configuration

    /// Maximum number of notifications retained in the ring.
    static let ringCapacity = 256

    // MARK: - Sound preference

    var notificationSound: NotificationSound {
        get {
            let raw = UserDefaults.standard.string(forKey: "namu.notificationSound") ?? ""
            return NotificationSound(rawValue: raw) ?? .system
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: "namu.notificationSound")
        }
    }

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
        playSound()

        // Notify the pane to show attention ring.
        NotificationCenter.default.post(
            name: .namuPaneAttentionRequested,
            object: nil,
            userInfo: [
                "workspace_id": workspaceID as Any,
                "panel_id": panelID as Any
            ]
        )

        return notification
    }

    // MARK: - Terminal notifications

    /// Handle a terminal OSC desktop notification. Checks if the workspace has an
    /// active Claude session and suppresses if so (Claude hooks handle those).
    @discardableResult
    func handleTerminalNotification(
        title: String,
        body: String,
        workspaceManager: WorkspaceManager
    ) -> InAppNotification? {
        // Check if the selected workspace has an active Claude session.
        if let wsID = workspaceManager.selectedWorkspaceID,
           let ws = workspaceManager.workspaces.first(where: { $0.id == wsID }),
           ws.claudeSessionPID != nil {
            return nil
        }

        let notification = create(
            title: title.isEmpty ? "Terminal" : title,
            body: body,
            workspaceID: workspaceManager.selectedWorkspaceID
        )
        postDesktopNotification(title: title.isEmpty ? "Terminal" : title, body: body)
        return notification
    }

    // MARK: - Desktop notification

    func postDesktopNotification(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
    }

    // MARK: - Audio

    private func playSound() {
        let sound = notificationSound
        guard sound != .none else { return }
        if let name = sound.soundName, let nsSound = NSSound(named: NSSound.Name(name)) {
            nsSound.play()
        } else if sound == .system {
            NSSound.beep()
        }
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
