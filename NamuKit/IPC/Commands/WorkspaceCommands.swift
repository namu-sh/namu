import Foundation

/// Handlers for the workspace.* command namespace.
/// Focus policy: only workspace.select steals focus. All others preserve current focus.
@MainActor
final class WorkspaceCommands {

    private let workspaceManager: WorkspaceManager
    private let panelManager: PanelManager

    /// Tracks the previously selected workspace for workspace.last navigation.
    private var previousSelectedWorkspaceID: UUID?

    init(workspaceManager: WorkspaceManager, panelManager: PanelManager) {
        self.workspaceManager = workspaceManager
        self.panelManager = panelManager
    }

    // MARK: - Registration

    func register(in registry: CommandRegistry) {
        registry.register("workspace.list")     { [weak self] req in try await self?.list(req) ?? .notAvailable(req) }
        registry.register("workspace.create")   { [weak self] req in try await self?.create(req) ?? .notAvailable(req) }
        registry.register("workspace.delete")   { [weak self] req in try await self?.delete(req) ?? .notAvailable(req) }
        registry.register("workspace.select")   { [weak self] req in try await self?.select(req) ?? .notAvailable(req) }
        registry.register("workspace.rename")   { [weak self] req in try await self?.rename(req) ?? .notAvailable(req) }
        registry.register("workspace.pin")      { [weak self] req in try await self?.pin(req) ?? .notAvailable(req) }
        registry.register("workspace.color")    { [weak self] req in try await self?.color(req) ?? .notAvailable(req) }
        registry.register("workspace.current")  { [weak self] req in try await self?.current(req) ?? .notAvailable(req) }
        registry.register("workspace.close")    { [weak self] req in try await self?.closeWorkspace(req) ?? .notAvailable(req) }
        registry.register("workspace.next")     { [weak self] req in try await self?.next(req) ?? .notAvailable(req) }
        registry.register("workspace.previous") { [weak self] req in try await self?.previous(req) ?? .notAvailable(req) }
        registry.register("workspace.last")     { [weak self] req in try await self?.last(req) ?? .notAvailable(req) }
    }

    // MARK: - workspace.list

    private func list(_ req: JSONRPCRequest) async throws -> JSONRPCResponse {
        let workspaces = workspaceManager.workspaces
        let selectedID = workspaceManager.selectedWorkspaceID

        let items: [JSONRPCValue] = workspaces.map { ws in
            .object([
                "id":       .string(ws.id.uuidString),
                "title":    .string(ws.title),
                "order":    .int(ws.order),
                "selected": .bool(ws.id == selectedID),
                "pinned":   .bool(ws.isPinned),
                "pane_count": .int(panelManager.allPanelIDs(in: ws.id).count)
            ])
        }

        return .success(id: req.id, result: .object([
            "workspaces": .array(items),
            "selected_id": selectedID.map { .string($0.uuidString) } ?? .null
        ]))
    }

    // MARK: - workspace.create

    private func create(_ req: JSONRPCRequest) async throws -> JSONRPCResponse {
        let params = req.params?.object ?? [:]
        let title: String
        if let t = params["title"], case .string(let s) = t, !s.isEmpty {
            title = s
        } else {
            title = String(localized: "workspace.default.title", defaultValue: "New Workspace")
        }

        let ws = panelManager.createWorkspace(title: title)
        return .success(id: req.id, result: .object([
            "id":    .string(ws.id.uuidString),
            "title": .string(ws.title),
            "order": .int(ws.order)
        ]))
    }

    // MARK: - workspace.delete

    private func delete(_ req: JSONRPCRequest) async throws -> JSONRPCResponse {
        let params = req.params?.object ?? [:]
        guard let idValue = params["id"], case .string(let idStr) = idValue,
              let id = UUID(uuidString: idStr) else {
            throw JSONRPCError.invalidParams
        }
        guard workspaceManager.workspaces.contains(where: { $0.id == id }) else {
            throw JSONRPCError(code: -32001, message: "Workspace not found")
        }
        guard workspaceManager.workspaces.count > 1 else {
            throw JSONRPCError(code: -32001, message: "Cannot delete the last workspace")
        }

        panelManager.deleteWorkspace(id: id)
        return .success(id: req.id, result: .object(["id": .string(idStr)]))
    }

    // MARK: - workspace.select  (focus-stealing command)

    private func select(_ req: JSONRPCRequest) async throws -> JSONRPCResponse {
        let params = req.params?.object ?? [:]
        guard let idValue = params["id"], case .string(let idStr) = idValue,
              let id = UUID(uuidString: idStr) else {
            throw JSONRPCError.invalidParams
        }
        guard workspaceManager.workspaces.contains(where: { $0.id == id }) else {
            throw JSONRPCError(code: -32001, message: "Workspace not found")
        }

        trackPreviousWorkspace()
        NotificationCenter.default.post(
            name: .selectWorkspace,
            object: nil,
            userInfo: ["id": id]
        )
        return .success(id: req.id, result: .object([
            "id":       .string(idStr),
            "selected": .bool(true)
        ]))
    }

    // MARK: - workspace.rename

    private func rename(_ req: JSONRPCRequest) async throws -> JSONRPCResponse {
        let params = req.params?.object ?? [:]
        guard let idValue = params["id"], case .string(let idStr) = idValue,
              let id = UUID(uuidString: idStr) else {
            throw JSONRPCError.invalidParams
        }
        guard let titleValue = params["title"], case .string(let title) = titleValue else {
            throw JSONRPCError(code: -32602, message: "Missing required param: title")
        }
        guard workspaceManager.workspaces.contains(where: { $0.id == id }) else {
            throw JSONRPCError(code: -32001, message: "Workspace not found")
        }

        workspaceManager.renameWorkspace(id: id, title: title)
        return .success(id: req.id, result: .object([
            "id":    .string(idStr),
            "title": .string(title)
        ]))
    }

    // MARK: - workspace.pin
    //
    // Toggle the pinned state of a workspace.
    // Params: id (string, required)
    // Returns: id, pinned (bool)

    private func pin(_ req: JSONRPCRequest) async throws -> JSONRPCResponse {
        let params = req.params?.object ?? [:]
        guard let idValue = params["id"], case .string(let idStr) = idValue,
              let id = UUID(uuidString: idStr) else {
            throw JSONRPCError.invalidParams
        }
        guard let ws = workspaceManager.workspaces.first(where: { $0.id == id }) else {
            throw JSONRPCError(code: -32001, message: "Workspace not found")
        }
        workspaceManager.pinWorkspace(id: id)
        let newPinned = workspaceManager.workspaces.first(where: { $0.id == id })?.isPinned ?? !ws.isPinned
        return .success(id: req.id, result: .object([
            "id":     .string(idStr),
            "pinned": .bool(newPinned)
        ]))
    }

    // MARK: - workspace.current

    private func current(_ req: JSONRPCRequest) async throws -> JSONRPCResponse {
        guard let workspace = workspaceManager.selectedWorkspace else {
            throw JSONRPCError(code: -32001, message: "No active workspace")
        }

        return .success(id: req.id, result: .object([
            "workspace_id": .string(workspace.id.uuidString),
            "title":        .string(workspace.title),
            "order":        .int(workspace.order),
            "pane_count":   .int(panelManager.allPanelIDs(in: workspace.id).count)
        ]))
    }

    // MARK: - workspace.close

    private func closeWorkspace(_ req: JSONRPCRequest) async throws -> JSONRPCResponse {
        let params = req.params?.object ?? [:]

        let workspaceID: UUID
        if let wsValue = params["workspace_id"], case .string(let wsStr) = wsValue,
           let wsID = UUID(uuidString: wsStr) {
            workspaceID = wsID
        } else if let selected = workspaceManager.selectedWorkspaceID {
            workspaceID = selected
        } else {
            throw JSONRPCError(code: -32001, message: "No workspace specified")
        }

        guard workspaceManager.workspaces.contains(where: { $0.id == workspaceID }) else {
            throw JSONRPCError(code: -32001, message: "Workspace not found")
        }
        guard workspaceManager.workspaces.count > 1 else {
            throw JSONRPCError(code: -32001, message: "Cannot close the last workspace")
        }

        panelManager.deleteWorkspace(id: workspaceID)
        return .success(id: req.id, result: .object([
            "workspace_id": .string(workspaceID.uuidString)
        ]))
    }

    // MARK: - workspace.next

    private func next(_ req: JSONRPCRequest) async throws -> JSONRPCResponse {
        let workspaces = workspaceManager.workspaces
        guard let selectedID = workspaceManager.selectedWorkspaceID,
              let currentIdx = workspaces.firstIndex(where: { $0.id == selectedID }) else {
            throw JSONRPCError(code: -32001, message: "No active workspace")
        }
        let nextIdx = (currentIdx + 1) % workspaces.count
        let nextWorkspace = workspaces[nextIdx]
        trackPreviousWorkspace()
        workspaceManager.selectWorkspace(id: nextWorkspace.id)
        return .success(id: req.id, result: .object([
            "workspace_id": .string(nextWorkspace.id.uuidString),
            "title":        .string(nextWorkspace.title)
        ]))
    }

    // MARK: - workspace.previous

    private func previous(_ req: JSONRPCRequest) async throws -> JSONRPCResponse {
        let workspaces = workspaceManager.workspaces
        guard let selectedID = workspaceManager.selectedWorkspaceID,
              let currentIdx = workspaces.firstIndex(where: { $0.id == selectedID }) else {
            throw JSONRPCError(code: -32001, message: "No active workspace")
        }
        let prevIdx = currentIdx == 0 ? workspaces.count - 1 : currentIdx - 1
        let prevWorkspace = workspaces[prevIdx]
        trackPreviousWorkspace()
        workspaceManager.selectWorkspace(id: prevWorkspace.id)
        return .success(id: req.id, result: .object([
            "workspace_id": .string(prevWorkspace.id.uuidString),
            "title":        .string(prevWorkspace.title)
        ]))
    }

    // MARK: - workspace.last

    private func last(_ req: JSONRPCRequest) async throws -> JSONRPCResponse {
        guard let previousID = previousSelectedWorkspaceID,
              workspaceManager.workspaces.contains(where: { $0.id == previousID }) else {
            throw JSONRPCError(code: -32001, message: "No previous workspace")
        }
        trackPreviousWorkspace()
        workspaceManager.selectWorkspace(id: previousID)
        return .success(id: req.id, result: .object([
            "workspace_id": .string(previousID.uuidString)
        ]))
    }

    // MARK: - Private helpers

    private func trackPreviousWorkspace() {
        if let current = workspaceManager.selectedWorkspaceID {
            previousSelectedWorkspaceID = current
        }
    }

    // MARK: - workspace.color
    //
    // Set or clear the custom accent color of a workspace.
    // Params: id (string, required), color (string, optional hex e.g. "#FF6B6B"; omit or null to clear)
    // Returns: id, color (string or null)

    private func color(_ req: JSONRPCRequest) async throws -> JSONRPCResponse {
        let params = req.params?.object ?? [:]
        guard let idValue = params["id"], case .string(let idStr) = idValue,
              let id = UUID(uuidString: idStr) else {
            throw JSONRPCError.invalidParams
        }
        guard workspaceManager.workspaces.contains(where: { $0.id == id }) else {
            throw JSONRPCError(code: -32001, message: "Workspace not found")
        }

        let newColor: String?
        if let colorValue = params["color"], case .string(let hex) = colorValue, !hex.isEmpty {
            newColor = hex
        } else {
            newColor = nil
        }

        workspaceManager.setWorkspaceColor(id: id, color: newColor)
        return .success(id: req.id, result: .object([
            "id":    .string(idStr),
            "color": newColor.map { .string($0) } ?? .null
        ]))
    }
}

// MARK: - Helpers

private extension JSONRPCResponse {
    static func notAvailable(_ req: JSONRPCRequest) -> JSONRPCResponse {
        .failure(id: req.id, error: .internalError("Service unavailable"))
    }
}
