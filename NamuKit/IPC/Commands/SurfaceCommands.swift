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
        // Dangerous commands → .mainActor + .dangerous
        registry.register(HandlerRegistration(method: "surface.send_text", execution: .mainActor, safety: .dangerous,
            handler: { [weak self] req in try await self?.sendText(req) ?? .notAvailable(req) }))
        registry.register(HandlerRegistration(method: "surface.send_key", execution: .mainActor, safety: .dangerous,
            handler: { [weak self] req in try await self?.sendKey(req) ?? .notAvailable(req) }))

        // State-mutating commands → .mainActor + .normal
        registry.register(HandlerRegistration(method: "surface.split", execution: .mainActor, safety: .normal,
            handler: { [weak self] req in try await self?.split(req) ?? .notAvailable(req) }))
        registry.register(HandlerRegistration(method: "surface.close", execution: .mainActor, safety: .normal,
            handler: { [weak self] req in try await self?.closeSurface(req) ?? .notAvailable(req) }))

        // Read-only queries → .background + .safe
        registry.register(HandlerRegistration(method: "surface.list", execution: .mainActor, safety: .safe,
            handler: { [weak self] req in try await self?.list(req) ?? .notAvailable(req) }))
        registry.register(HandlerRegistration(method: "surface.current", execution: .mainActor, safety: .safe,
            handler: { [weak self] req in try await self?.current(req) ?? .notAvailable(req) }))
        registry.register(HandlerRegistration(method: "surface.read_text", execution: .background, safety: .safe,
            handler: { [weak self] req in try await self?.readText(req) ?? .notAvailable(req) }))
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

    // MARK: - surface.split

    private func split(_ req: JSONRPCRequest) async throws -> JSONRPCResponse {
        let params = req.params?.object ?? [:]

        guard let dirValue = params["direction"], case .string(let dirStr) = dirValue else {
            throw JSONRPCError(code: -32602, message: "Missing required param: direction")
        }
        let direction: SplitDirection
        switch dirStr {
        case "left", "right": direction = .horizontal
        case "up", "down":    direction = .vertical
        default:
            guard let d = SplitDirection(rawValue: dirStr) else {
                throw JSONRPCError(code: -32602, message: "Invalid direction: \(dirStr)")
            }
            direction = d
        }

        let (targetPanelID, workspaceID) = try resolveTarget(params: params)

        let focusNew: Bool
        if let focusVal = params["focus"], case .bool(let f) = focusVal {
            focusNew = f
        } else {
            focusNew = true
        }

        let newPanel = panelManager.createTerminalPanel()
        panelManager.splitPanel(id: targetPanelID, direction: direction, newPanel: newPanel)

        // If focus=false (tmux -d flag), restore focus to original panel
        if !focusNew {
            panelManager.activatePanel(id: targetPanelID)
        }

        return .success(id: req.id, result: .object([
            "surface_id":   .string(newPanel.id.uuidString),
            "pane_id":      .string(newPanel.id.uuidString),
            "workspace_id": .string(workspaceID.uuidString)
        ]))
    }

    // MARK: - surface.close

    private func closeSurface(_ req: JSONRPCRequest) async throws -> JSONRPCResponse {
        let params = req.params?.object ?? [:]
        let (panelID, workspaceID) = try resolveTarget(params: params)

        panelManager.closePanel(id: panelID)
        return .success(id: req.id, result: .object([
            "surface_id":   .string(panelID.uuidString),
            "workspace_id": .string(workspaceID.uuidString)
        ]))
    }

    // MARK: - surface.current

    private func current(_ req: JSONRPCRequest) async throws -> JSONRPCResponse {
        let params = req.params?.object ?? [:]

        let workspace: Workspace
        if let wsValue = params["workspace_id"], case .string(let wsStr) = wsValue,
           let wsID = UUID(uuidString: wsStr) {
            guard let ws = workspaceManager.workspaces.first(where: { $0.id == wsID }) else {
                throw JSONRPCError(code: -32001, message: "Workspace not found")
            }
            workspace = ws
        } else {
            guard let ws = workspaceManager.selectedWorkspace else {
                throw JSONRPCError(code: -32001, message: "No active workspace")
            }
            workspace = ws
        }

        guard let activePanelID = workspace.activePanelID else {
            throw JSONRPCError(code: -32001, message: "No active surface")
        }

        var result: [String: JSONRPCValue] = [
            "surface_id":   .string(activePanelID.uuidString),
            "pane_id":      .string(activePanelID.uuidString),
            "pane_ref":     .string("%\(activePanelID.uuidString)"),
            "workspace_id": .string(workspace.id.uuidString)
        ]

        if let panel = panelManager.panel(for: activePanelID) {
            let cell = panel.cellSize
            let frame = panel.surfaceView.frame.size
            if cell.width > 0 && cell.height > 0 {
                result["columns"] = .int(Int(frame.width / cell.width))
                result["rows"] = .int(Int(frame.height / cell.height))
                result["cell_width_px"] = .double(Double(cell.width))
                result["cell_height_px"] = .double(Double(cell.height))
            }
            result["pixel_width"] = .int(Int(frame.width))
            result["pixel_height"] = .int(Int(frame.height))
        }

        return .success(id: req.id, result: .object(result))
    }

    // MARK: - surface.read_text

    private func readText(_ req: JSONRPCRequest) async throws -> JSONRPCResponse {
        let params = req.params?.object ?? [:]
        let (panelID, workspaceID) = try resolveTarget(params: params)

        guard let panel = panelManager.panel(for: panelID) else {
            throw JSONRPCError(code: -32001, message: "Surface not available")
        }

        let text = panel.session.readVisibleText() ?? ""

        return .success(id: req.id, result: .object([
            "surface_id":   .string(panelID.uuidString),
            "workspace_id": .string(workspaceID.uuidString),
            "text":         .string(text)
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
