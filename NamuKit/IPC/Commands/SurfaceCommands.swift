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
        registry.register(HandlerRegistration(method: "surface.send_text", execution: .mainActor, safety: .dangerous,
            handler: { [weak self] req in try await self?.sendText(req) ?? .notAvailable(req) }))
        registry.register(HandlerRegistration(method: "surface.send_key", execution: .mainActor, safety: .dangerous,
            handler: { [weak self] req in try await self?.sendKey(req) ?? .notAvailable(req) }))
        registry.register(HandlerRegistration(method: "surface.split", execution: .mainActor, safety: .normal,
            handler: { [weak self] req in try await self?.split(req) ?? .notAvailable(req) }))
        registry.register(HandlerRegistration(method: "surface.close", execution: .mainActor, safety: .normal,
            handler: { [weak self] req in try await self?.closeSurface(req) ?? .notAvailable(req) }))
        registry.register(HandlerRegistration(method: "surface.list", execution: .mainActor, safety: .safe,
            handler: { [weak self] req in try await self?.list(req) ?? .notAvailable(req) }))
        registry.register(HandlerRegistration(method: "surface.current", execution: .mainActor, safety: .safe,
            handler: { [weak self] req in try await self?.current(req) ?? .notAvailable(req) }))
        registry.register(HandlerRegistration(method: "surface.read_text", execution: .background, safety: .safe,
            handler: { [weak self] req in try await self?.readText(req) ?? .notAvailable(req) }))
        registry.register(HandlerRegistration(method: "report_shell_state", execution: .mainActor, safety: .safe,
            handler: { [weak self] req in try await self?.reportShellState(req) ?? .notAvailable(req) }))
        registry.register(HandlerRegistration(method: "report_tty", execution: .mainActor, safety: .safe,
            handler: { [weak self] req in try await self?.reportTTY(req) ?? .notAvailable(req) }))
        registry.register(HandlerRegistration(method: "ports_kick", execution: .mainActor, safety: .safe,
            handler: { [weak self] req in try await self?.portsKick(req) ?? .notAvailable(req) }))
    }

    // MARK: - Helpers

    /// Resolve target panel from params, falling back to the focused panel.
    private func resolveTarget(params: [String: JSONRPCValue]) throws -> (panelID: UUID, workspaceID: UUID) {
        // If surface_id is provided, look it up
        if let sidValue = params["surface_id"], case .string(let sidStr) = sidValue,
           let sid = UUID(uuidString: sidStr) {
            guard let wsID = panelManager.workspaceIDForPanel(sid) else {
                throw JSONRPCError(code: -32001, message: "Surface not found")
            }
            return (sid, wsID)
        }

        // Fall back to focused panel in selected workspace
        guard let wsID = workspaceManager.selectedWorkspaceID else {
            throw JSONRPCError(code: -32001, message: "No active workspace")
        }
        guard let focused = panelManager.focusedPanelID(in: wsID) else {
            throw JSONRPCError(code: -32001, message: "No active surface")
        }
        return (focused, wsID)
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
            let panelIDs = panelManager.allPanelIDs(in: ws.id)
            let focusedID = panelManager.focusedPanelID(in: ws.id)
            for panelID in panelIDs {
                let title = panelManager.panel(for: panelID)?.title ?? ""
                surfaces.append(.object([
                    "id":           .string(panelID.uuidString),
                    "workspace_id": .string(ws.id.uuidString),
                    "type":         .string("terminal"),
                    "title":        .string(title),
                    "focused":      .bool(panelID == focusedID)
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

        panelManager.splitPane(in: workspaceID, direction: direction)

        let newPanelID = panelManager.focusedPanelID(in: workspaceID)

        // If focus=false, restore focus to original panel
        if let focusVal = params["focus"], case .bool(let f) = focusVal, !f {
            panelManager.activatePanel(id: targetPanelID)
        }

        return .success(id: req.id, result: .object([
            "surface_id":   .string(newPanelID?.uuidString ?? ""),
            "pane_id":      .string(newPanelID?.uuidString ?? ""),
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

        let wsID: UUID
        if let wsValue = params["workspace_id"], case .string(let wsStr) = wsValue,
           let requestedWsID = UUID(uuidString: wsStr),
           workspaceManager.workspaces.contains(where: { $0.id == requestedWsID }) {
            wsID = requestedWsID
        } else {
            guard let selected = workspaceManager.selectedWorkspaceID else {
                throw JSONRPCError(code: -32001, message: "No active workspace")
            }
            wsID = selected
        }

        guard let activePanelID = panelManager.focusedPanelID(in: wsID) else {
            throw JSONRPCError(code: -32001, message: "No active surface")
        }

        var result: [String: JSONRPCValue] = [
            "surface_id":   .string(activePanelID.uuidString),
            "pane_id":      .string(activePanelID.uuidString),
            "pane_ref":     .string("%\(activePanelID.uuidString)"),
            "workspace_id": .string(wsID.uuidString)
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

    // MARK: - report_shell_state

    /// Update the shell integration state for a panel.
    /// Called by namu.zsh when a command starts (`running`) or the prompt appears (`prompt`).
    /// Params:
    ///   state       (string, required) — "running", "prompt", "idle", or "unknown"
    ///   surface_id  (string, optional) — panel UUID; defaults to focused panel
    ///   command     (string, optional) — command text (for "running" state)
    private func reportShellState(_ req: JSONRPCRequest) async throws -> JSONRPCResponse {
        let params = req.params?.object ?? [:]

        guard let stateValue = params["state"], case .string(let stateStr) = stateValue else {
            throw JSONRPCError(code: -32602, message: "Missing required param: state")
        }

        let (panelID, workspaceID) = try resolveTarget(params: params)

        guard let panel = panelManager.panel(for: panelID) else {
            throw JSONRPCError(code: -32001, message: "Surface not available")
        }

        let command: String
        if let cmdValue = params["command"], case .string(let cmd) = cmdValue {
            command = cmd
        } else {
            command = ""
        }

        let newState: ShellState
        switch stateStr {
        case "running":
            newState = .running(command: command)
        case "prompt":
            newState = .prompt
        case "commandInput":
            newState = .commandInput
        case "idle":
            let exitCode: Int?
            if let codeValue = params["exit_code"], case .int(let code) = codeValue {
                exitCode = code
            } else {
                exitCode = nil
            }
            newState = .idle(exitCode: exitCode)
        default:
            newState = .unknown
        }

        panel.updateShellState(newState)

        return .success(id: req.id, result: .object([
            "surface_id":   .string(panelID.uuidString),
            "workspace_id": .string(workspaceID.uuidString),
            "state":        .string(stateStr)
        ]))
    }

    // MARK: - report_tty

    /// Register the TTY name for a panel so PortScanner can scope ps/lsof to it.
    /// Params:
    ///   tty         (string, required) — TTY device name e.g. "s004"
    ///   surface_id  (string, optional) — panel UUID; defaults to focused panel
    private func reportTTY(_ req: JSONRPCRequest) async throws -> JSONRPCResponse {
        let params = req.params?.object ?? [:]

        guard let ttyValue = params["tty"], case .string(let ttyName) = ttyValue, !ttyName.isEmpty else {
            throw JSONRPCError(code: -32602, message: "Missing required param: tty")
        }

        let (panelID, workspaceID) = try resolveTarget(params: params)

        PortScanner.shared.registerTTY(workspaceID: workspaceID, panelID: panelID, ttyName: ttyName)

        return .success(id: req.id, result: .object([
            "surface_id":   .string(panelID.uuidString),
            "workspace_id": .string(workspaceID.uuidString),
            "tty":          .string(ttyName)
        ]))
    }

    // MARK: - ports_kick

    /// Trigger a port scan burst for a panel after a command completes.
    /// Params:
    ///   surface_id  (string, optional) — panel UUID; defaults to focused panel
    private func portsKick(_ req: JSONRPCRequest) async throws -> JSONRPCResponse {
        let params = req.params?.object ?? [:]
        let (panelID, workspaceID) = try resolveTarget(params: params)

        PortScanner.shared.kick(workspaceID: workspaceID, panelID: panelID)

        return .success(id: req.id, result: .object([
            "surface_id":   .string(panelID.uuidString),
            "workspace_id": .string(workspaceID.uuidString)
        ]))
    }
}

// MARK: - Helpers

private extension JSONRPCResponse {
    static func notAvailable(_ req: JSONRPCRequest) -> JSONRPCResponse {
        .failure(id: req.id, error: .internalError("Service unavailable"))
    }
}
