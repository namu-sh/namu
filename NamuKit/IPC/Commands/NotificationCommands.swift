import Foundation

/// Handlers for the notification.* command namespace.
/// Delegates to NotificationService for in-app notification management.
/// Focus policy: no notification command steals focus.
@MainActor
final class NotificationCommands {

    private let workspaceManager: WorkspaceManager
    private let panelManager: PanelManager
    private let notificationService: NotificationService
    private let eventBus: EventBus

    init(workspaceManager: WorkspaceManager, panelManager: PanelManager, notificationService: NotificationService, eventBus: EventBus) {
        self.workspaceManager = workspaceManager
        self.panelManager = panelManager
        self.notificationService = notificationService
        self.eventBus = eventBus
    }

    // MARK: - Registration

    func register(in registry: CommandRegistry) {
        registry.register("notification.create")      { [weak self] req in try await self?.create(req) ?? .notAvailable(req) }
        registry.register("notification.list")        { [weak self] req in try await self?.list(req) ?? .notAvailable(req) }
        registry.register("notification.clear")       { [weak self] req in try await self?.clear(req) ?? .notAvailable(req) }
        registry.register("notification.subscribe")   { [weak self] req in try await self?.subscribe(req) ?? .notAvailable(req) }
        registry.register("notification.unsubscribe") { [weak self] req in try await self?.unsubscribe(req) ?? .notAvailable(req) }
        registry.register(HandlerRegistration(method: "notification.jump_to_unread", execution: .mainActor, safety: .normal,
            handler: { [weak self] req in try await self?.jumpToUnread(req) ?? .notAvailable(req) }))
    }

    // MARK: - notification.create

    private func create(_ req: JSONRPCRequest) async throws -> JSONRPCResponse {
        let params = req.params?.object ?? [:]

        guard let titleValue = params["title"], case .string(let title) = titleValue else {
            throw JSONRPCError(code: -32602, message: "Missing required param: title")
        }

        let body: String
        if let bodyValue = params["body"], case .string(let b) = bodyValue {
            body = b
        } else {
            body = ""
        }

        let workspaceID: UUID?
        if let wsValue = params["workspace_id"], case .string(let wsStr) = wsValue {
            workspaceID = UUID(uuidString: wsStr)
        } else {
            workspaceID = workspaceManager.selectedWorkspaceID
        }

        let panelID: UUID?
        if let pidValue = params["pane_id"], case .string(let pidStr) = pidValue {
            panelID = UUID(uuidString: pidStr)
        } else {
            panelID = workspaceID.flatMap { wsID in
                panelManager.focusedPanelID(in: wsID)
            }
        }

        let notification = notificationService.create(
            title: title,
            body: body,
            workspaceID: workspaceID,
            panelID: panelID
        )

        // Publish workspace.change so subscribers get notified
        eventBus.publish(event: .workspaceChange, params: [
            "notification_id": .string(notification.id.uuidString)
        ])

        // Update sidebar metadata with latest notification text
        NotificationCenter.default.post(
            name: .namuNotificationCreated,
            object: nil,
            userInfo: [
                "workspace_id": workspaceID as Any,
                "body": body.isEmpty ? title : body
            ]
        )

        return .success(id: req.id, result: .object([
            "id":           .string(notification.id.uuidString),
            "title":        .string(notification.title),
            "body":         .string(notification.body),
            "workspace_id": notification.workspaceID.map { .string($0.uuidString) } ?? .null,
            "pane_id":      notification.panelID.map { .string($0.uuidString) } ?? .null
        ]))
    }

    // MARK: - notification.list

    private func list(_ req: JSONRPCRequest) async throws -> JSONRPCResponse {
        let params = req.params?.object ?? [:]

        var notifications = notificationService.allNotifications

        // Optional workspace filter
        if let wsValue = params["workspace_id"], case .string(let wsStr) = wsValue,
           let wsID = UUID(uuidString: wsStr) {
            notifications = notifications.filter { $0.workspaceID == wsID }
        }

        let items: [JSONRPCValue] = notifications.map { n in
            .object([
                "id":           .string(n.id.uuidString),
                "title":        .string(n.title),
                "body":         .string(n.body),
                "workspace_id": n.workspaceID.map { .string($0.uuidString) } ?? .null,
                "pane_id":      n.panelID.map { .string($0.uuidString) } ?? .null,
                "is_read":      .bool(n.isRead),
                "created_at":   .double(n.createdAt.timeIntervalSince1970)
            ])
        }

        return .success(id: req.id, result: .object([
            "notifications": .array(items),
            "count":         .int(items.count)
        ]))
    }

    // MARK: - notification.clear

    private func clear(_ req: JSONRPCRequest) async throws -> JSONRPCResponse {
        let params = req.params?.object ?? [:]

        if let idValue = params["id"], case .string(let idStr) = idValue,
           let id = UUID(uuidString: idStr) {
            notificationService.remove(id: id)
            return .success(id: req.id, result: .object(["cleared": .int(1)]))
        }

        // Clear all (optionally scoped to workspace)
        if let wsValue = params["workspace_id"], case .string(let wsStr) = wsValue,
           let wsID = UUID(uuidString: wsStr) {
            let count = notificationService.clearAll(workspaceID: wsID)
            return .success(id: req.id, result: .object(["cleared": .int(count)]))
        }

        let count = notificationService.clearAll(workspaceID: nil)
        return .success(id: req.id, result: .object(["cleared": .int(count)]))
    }

    // MARK: - notification.jump_to_unread

    private func jumpToUnread(_ req: JSONRPCRequest) async throws -> JSONRPCResponse {
        guard let wsID = notificationService.jumpToOldestUnread() else {
            return .success(id: req.id, result: .object([
                "jumped": .bool(false),
                "workspace_id": .null
            ]))
        }

        workspaceManager.selectWorkspace(id: wsID)
        notificationService.markAllRead(workspaceID: wsID)

        if let panelID = panelManager.focusedPanelID(in: wsID) {
            panelManager.activatePanel(id: panelID)
        }

        return .success(id: req.id, result: .object([
            "jumped": .bool(true),
            "workspace_id": .string(wsID.uuidString)
        ]))
    }

    // MARK: - notification.subscribe

    private func subscribe(_ req: JSONRPCRequest) async throws -> JSONRPCResponse {
        // Subscription to notification events is handled via the EventBus.
        // Clients use EventBus subscription; this command returns the subscription token.
        // The actual push happens when notificationService publishes events.
        return .success(id: req.id, result: .object([
            "subscribed": .bool(true),
            "events":     .array([.string("workspace.change")])
        ]))
    }

    // MARK: - notification.unsubscribe

    private func unsubscribe(_ req: JSONRPCRequest) async throws -> JSONRPCResponse {
        let params = req.params?.object ?? [:]
        let token: String
        if let tokenValue = params["token"], case .string(let t) = tokenValue {
            token = t
        } else {
            token = ""
        }

        return .success(id: req.id, result: .object([
            "unsubscribed": .bool(true),
            "token":        .string(token)
        ]))
    }
}

// MARK: - Helpers

private extension JSONRPCResponse {
    static func notAvailable(_ req: JSONRPCRequest) -> JSONRPCResponse {
        .failure(id: req.id, error: .internalError("Service unavailable"))
    }
}
