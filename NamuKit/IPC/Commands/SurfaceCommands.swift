import Foundation

/// Handlers for the surface.* command namespace.
/// Surfaces map to panels in Namu's domain model.
/// Focus policy: no surface command steals focus.
@MainActor
final class SurfaceCommands {

    private let workspaceManager: WorkspaceManager
    private let panelManager: PanelManager

    init(workspaceManager: WorkspaceManager, panelManager: PanelManager) {
        self.workspaceManager = workspaceManager
        self.panelManager = panelManager
    }

    // MARK: - Registration

    func register(in registry: CommandRegistry) {
        registry.register("surface.send_text") { [weak self] req in try await self?.sendText(req) ?? .notAvailable(req) }
        registry.register("surface.send_key")  { [weak self] req in try await self?.sendKey(req) ?? .notAvailable(req) }
        registry.register("surface.list")      { [weak self] req in try await self?.list(req) ?? .notAvailable(req) }
    }

    // MARK: - surface.send_text

    private func sendText(_ req: JSONRPCRequest) async throws -> JSONRPCResponse {
        let params = req.params?.object ?? [:]

        guard let textValue = params["text"], case .string(let text) = textValue else {
            throw JSONRPCError(code: -32602, message: "Missing required param: text")
        }

        let (panelID, workspaceID) = try resolveTarget(params: params)

        guard let panel = panelManager.panel(for: panelID) else {
            throw JSONRPCError(code: -32001, message: "Surface not available")
        }

        panel.session.sendText(text)

        return .success(id: req.id, result: .object([
            "surface_id":   .string(panelID.uuidString),
            "workspace_id": .string(workspaceID.uuidString),
            "sent":         .bool(true)
        ]))
    }

    // MARK: - surface.send_key

    private func sendKey(_ req: JSONRPCRequest) async throws -> JSONRPCResponse {
        let params = req.params?.object ?? [:]

        guard let keyValue = params["key"], case .string(let key) = keyValue else {
            throw JSONRPCError(code: -32602, message: "Missing required param: key")
        }

        let (panelID, workspaceID) = try resolveTarget(params: params)

        guard let panel = panelManager.panel(for: panelID) else {
            throw JSONRPCError(code: -32001, message: "Surface not available")
        }

        let sent = panel.session.sendNamedKey(key)
        if !sent {
            throw JSONRPCError(code: -32602, message: "Unknown key: \(key)")
        }

        return .success(id: req.id, result: .object([
            "surface_id":   .string(panelID.uuidString),
            "workspace_id": .string(workspaceID.uuidString),
            "key":          .string(key),
            "sent":         .bool(true)
        ]))
    }

    // MARK: - surface.list

    private func list(_ req: JSONRPCRequest) async throws -> JSONRPCResponse {
        let params = req.params?.object ?? [:]

        // Optionally filter by workspace
        let workspaces: [Workspace]
        if let wsValue = params["workspace_id"], case .string(let wsStr) = wsValue,
           let wsID = UUID(uuidString: wsStr) {
            guard let ws = workspaceManager.workspaces.first(where: { $0.id == wsID }) else {
                throw JSONRPCError(code: -32001, message: "Workspace not found")
            }
            workspaces = [ws]
        } else {
            workspaces = workspaceManager.workspaces
        }

        var surfaces: [JSONRPCValue] = []
        for ws in workspaces {
            for leaf in ws.allPanels {
                let isFocused = ws.activePanelID == leaf.id
                let title = panelManager.panel(for: leaf.id)?.title ?? ""
                surfaces.append(.object([
                    "id":           .string(leaf.id.uuidString),
                    "workspace_id": .string(ws.id.uuidString),
                    "type":         .string(leaf.panelType.rawValue),
                    "title":        .string(title),
                    "focused":      .bool(isFocused)
                ]))
            }
        }

        return .success(id: req.id, result: .object([
            "surfaces": .array(surfaces)
        ]))
    }

    // MARK: - Private helpers

    /// Resolve target panel from params, falling back to the focused panel.
    private func resolveTarget(params: [String: JSONRPCValue]) throws -> (panelID: UUID, workspaceID: UUID) {
        // If surface_id is provided, look it up across all workspaces
        if let sidValue = params["surface_id"], case .string(let sidStr) = sidValue,
           let sid = UUID(uuidString: sidStr) {
            for ws in workspaceManager.workspaces {
                if ws.paneTree.findPane(id: sid) != nil {
                    return (sid, ws.id)
                }
            }
            throw JSONRPCError(code: -32001, message: "Surface not found")
        }

        // Fall back to focused panel in selected workspace
        guard let workspace = workspaceManager.selectedWorkspace else {
            throw JSONRPCError(code: -32001, message: "No active workspace")
        }
        guard let focused = workspace.activePanelID else {
            throw JSONRPCError(code: -32001, message: "No active surface")
        }
        return (focused, workspace.id)
    }
}

// MARK: - Helpers

private extension JSONRPCResponse {
    static func notAvailable(_ req: JSONRPCRequest) -> JSONRPCResponse {
        .failure(id: req.id, error: .internalError("Service unavailable"))
    }
}
