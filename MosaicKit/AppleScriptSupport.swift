import AppKit

// MARK: - AppleScript Support

/// Lightweight AppleScript bridge for Mosaic.
/// Delegates operations to WorkspaceManager/PanelManager via notifications.
/// Full SDEF integration deferred to distribution — this provides the core
/// notification-based API that scripts can trigger.
enum AppleScriptSupport {

    // MARK: - Notification Names

    static let createWorkspaceNotification = Notification.Name("mosaic.applescript.createWorkspace")
    static let listWorkspacesNotification = Notification.Name("mosaic.applescript.listWorkspaces")
    static let sendKeysNotification = Notification.Name("mosaic.applescript.sendKeys")

    // MARK: - Registration

    /// Register AppleScript event handlers with the shared application.
    /// Call once during app startup (e.g. from ServiceContainer.start()).
    static func register() {
        let center = NotificationCenter.default

        center.addObserver(
            forName: createWorkspaceNotification,
            object: nil,
            queue: .main
        ) { notification in
            handleCreateWorkspace(notification)
        }

        center.addObserver(
            forName: sendKeysNotification,
            object: nil,
            queue: .main
        ) { notification in
            handleSendKeys(notification)
        }
    }

    // MARK: - Handlers

    private static func handleCreateWorkspace(_ notification: Notification) {
        // Post a notification that WorkspaceManager observes
        // The title can be passed via userInfo
        let title = notification.userInfo?["title"] as? String
        NotificationCenter.default.post(
            name: .appleScriptCreateWorkspace,
            object: nil,
            userInfo: title.map { ["title": $0] }
        )
    }

    private static func handleSendKeys(_ notification: Notification) {
        guard let text = notification.userInfo?["text"] as? String else { return }
        NotificationCenter.default.post(
            name: .appleScriptSendKeys,
            object: nil,
            userInfo: ["text": text]
        )
    }
}

// MARK: - Notification Names

extension Notification.Name {
    static let appleScriptCreateWorkspace = Notification.Name("mosaic.applescript.action.createWorkspace")
    static let appleScriptSendKeys = Notification.Name("mosaic.applescript.action.sendKeys")
}
