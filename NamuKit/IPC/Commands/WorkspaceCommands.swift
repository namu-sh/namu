import Foundation

/// Handlers for the workspace.* command namespace.
/// Focus policy: only workspace.select steals focus. All others preserve current focus.
@MainActor
final class WorkspaceCommands {

    private let workspaceManager: WorkspaceManager

    init(workspaceManager: WorkspaceManager) {
        self.workspaceManager = workspaceManager
    }

    // MARK: - Registration

    func register(in registry: CommandRegistry) {
        registry.register("workspace.list")   { [weak self] req in try await self?.list(req) ?? .notAvailable(req) }
        registry.register("workspace.create") { [weak self] req in try await self?.create(req) ?? .notAvailable(req) }
        registry.register("workspace.delete") { [weak self] req in try await self?.delete(req) ?? .notAvailable(req) }
        registry.register("workspace.select") { [weak self] req in try await self?.select(req) ?? .notAvailable(req) }
        registry.register("workspace.rename") { [weak self] req in try await self?.rename(req) ?? .notAvailable(req) }
        registry.register("workspace.pin")    { [weak self] req in try await self?.pin(req) ?? .notAvailable(req) }
        registry.register("workspace.color")  { [weak self] req in try await self?.color(req) ?? .notAvailable(req) }
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
                "pane_count": .int(ws.panelCount)
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

        let ws = workspaceManager.createWorkspace(title: title)
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

        workspaceManager.deleteWorkspace(id: id)
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
        let newPinned = !ws.isPinned  // toggled
        return .success(id: req.id, result: .object([
            "id":     .string(idStr),
            "pinned": .bool(newPinned)
        ]))
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
