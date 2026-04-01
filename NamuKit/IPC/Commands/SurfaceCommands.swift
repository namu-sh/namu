import Foundation
import Bonsplit

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
        registry.register(HandlerRegistration(method: "surface.reorder", execution: .mainActor, safety: .normal,
            handler: { [weak self] req in try await self?.reorder(req) ?? .notAvailable(req) }))
        registry.register(HandlerRegistration(method: "surface.drag_to_split", execution: .mainActor, safety: .normal,
            handler: { [weak self] req in try await self?.dragToSplit(req) ?? .notAvailable(req) }))
        registry.register(HandlerRegistration(method: "surface.move", execution: .mainActor, safety: .normal,
            handler: { [weak self] req in try await self?.move(req) ?? .notAvailable(req) }))
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
        var globalIndex = 0
        for ws in workspaces {
            let panelIDs = panelManager.allPanelIDs(in: ws.id)
            let focusedID = panelManager.focusedPanelID(in: ws.id)
            for panelID in panelIDs {
                let title = panelManager.panel(for: panelID)?.title ?? ""
                surfaces.append(.object([
                    "id":           .string(panelID.uuidString),
                    "ref":          .string("surface:\(globalIndex)"),
                    "index":        .int(globalIndex),
                    "workspace_id": .string(ws.id.uuidString),
                    "type":         .string("terminal"),
                    "title":        .string(title),
                    "focused":      .bool(panelID == focusedID)
                ]))
                globalIndex += 1
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

    // MARK: - surface.reorder

    private func reorder(_ req: JSONRPCRequest) async throws -> JSONRPCResponse {
        let params = req.params?.object ?? [:]

        guard let surfaceValue = params["surface_id"], case .string(let surfStr) = surfaceValue,
              let surfaceID = UUID(uuidString: surfStr) else {
            throw JSONRPCError(code: -32602, message: "Missing required param: surface_id")
        }

        guard let workspaceID = panelManager.workspaceIDForPanel(surfaceID) else {
            throw JSONRPCError(code: -32001, message: "Surface not found")
        }

        let index: Int?
        if let idxValue = params["index"], case .int(let i) = idxValue {
            index = i
        } else {
            index = nil
        }

        let beforeID: UUID?
        if let bValue = params["before_surface_id"], case .string(let bStr) = bValue {
            beforeID = UUID(uuidString: bStr)
        } else {
            beforeID = nil
        }

        let afterID: UUID?
        if let aValue = params["after_surface_id"], case .string(let aStr) = aValue {
            afterID = UUID(uuidString: aStr)
        } else {
            afterID = nil
        }

        let posCount = [index != nil, beforeID != nil, afterID != nil].filter { $0 }.count
        guard posCount == 1 else {
            throw JSONRPCError(code: -32602, message: "Exactly one of index, before_surface_id, or after_surface_id required")
        }

        let targetIndex: Int
        if let i = index {
            targetIndex = i
        } else if let bid = beforeID {
            let allPanels = panelManager.allPanelIDs(in: workspaceID)
            guard let beforeIdx = allPanels.firstIndex(of: bid) else {
                throw JSONRPCError(code: -32001, message: "before_surface_id not found in workspace")
            }
            targetIndex = beforeIdx
        } else if let aid = afterID {
            let allPanels = panelManager.allPanelIDs(in: workspaceID)
            guard let afterIdx = allPanels.firstIndex(of: aid) else {
                throw JSONRPCError(code: -32001, message: "after_surface_id not found in workspace")
            }
            targetIndex = afterIdx + 1
        } else {
            throw JSONRPCError(code: -32602, message: "No position specified")
        }

        guard panelManager.reorderSurface(panelID: surfaceID, inWorkspace: workspaceID, toIndex: targetIndex) else {
            throw JSONRPCError(code: -32001, message: "Failed to reorder surface")
        }

        return .success(id: req.id, result: .object([
            "surface_id":   .string(surfaceID.uuidString),
            "workspace_id": .string(workspaceID.uuidString),
            "index":        .int(targetIndex),
        ]))
    }

    // MARK: - surface.drag_to_split

    private func dragToSplit(_ req: JSONRPCRequest) async throws -> JSONRPCResponse {
        let params = req.params?.object ?? [:]

        guard let surfaceValue = params["surface_id"], case .string(let surfStr) = surfaceValue,
              let surfaceID = UUID(uuidString: surfStr) else {
            throw JSONRPCError(code: -32602, message: "Missing required param: surface_id")
        }

        guard let dirValue = params["direction"], case .string(let dirStr) = dirValue else {
            throw JSONRPCError(code: -32602, message: "Missing required param: direction (left|right|up|down)")
        }

        let splitDirection: SplitDirection
        let insertFirst: Bool
        switch dirStr.lowercased() {
        case "left":
            splitDirection = .horizontal
            insertFirst = true
        case "right":
            splitDirection = .horizontal
            insertFirst = false
        case "up":
            splitDirection = .vertical
            insertFirst = true
        case "down":
            splitDirection = .vertical
            insertFirst = false
        default:
            throw JSONRPCError(code: -32602, message: "Invalid direction: \(dirStr). Must be left|right|up|down")
        }

        guard let workspaceID = panelManager.workspaceIDForPanel(surfaceID) else {
            throw JSONRPCError(code: -32001, message: "Surface not found")
        }

        let engine = panelManager.engine(for: workspaceID)
        guard let newPaneID = engine.splitPaneWithMovingTab(id: surfaceID, direction: splitDirection, insertFirst: insertFirst) else {
            throw JSONRPCError(code: -32001, message: "Failed to drag surface to split")
        }

        return .success(id: req.id, result: .object([
            "surface_id":   .string(surfaceID.uuidString),
            "pane_id":      .string(newPaneID.id.uuidString),
            "workspace_id": .string(workspaceID.uuidString),
            "direction":    .string(dirStr),
        ]))
    }

    // MARK: - surface.move

    private func move(_ req: JSONRPCRequest) async throws -> JSONRPCResponse {
        let params = req.params?.object ?? [:]

        // Required: surface_id
        guard let surfValue = params["surface_id"], case .string(let surfStr) = surfValue,
              let surfaceID = UUID(uuidString: surfStr) else {
            throw JSONRPCError(code: -32602, message: "Missing required param: surface_id")
        }

        guard let sourceWorkspaceID = panelManager.workspaceIDForPanel(surfaceID) else {
            throw JSONRPCError(code: -32001, message: "Surface not found")
        }

        // Optional: pane_id (split container UUID), workspace_id, window_id, index, focus
        let targetPaneID: Bonsplit.PaneID?
        if let pValue = params["pane_id"], case .string(let pStr) = pValue, let uuid = UUID(uuidString: pStr) {
            targetPaneID = Bonsplit.PaneID(id: uuid)
        } else {
            targetPaneID = nil
        }

        let targetWorkspaceID: UUID?
        if let wValue = params["workspace_id"], case .string(let wStr) = wValue {
            targetWorkspaceID = UUID(uuidString: wStr)
        } else {
            targetWorkspaceID = nil
        }

        let index: Int?
        if let iValue = params["index"], case .int(let i) = iValue {
            index = i
        } else {
            index = nil
        }

        let focus: Bool
        if let fValue = params["focus"], case .bool(let f) = fValue {
            focus = f
        } else {
            focus = true
        }

        // Cross-window move: window_id provided — detach from source, attach to target window's PanelManager.
        if let winValue = params["window_id"], case .string(let winStr) = winValue,
           let winID = UUID(uuidString: winStr) {
            guard let targetCtx = AppDelegate.shared?.windowContexts[winID] else {
                throw JSONRPCError(code: -32001, message: "Window not found")
            }
            let targetPM = targetCtx.panelManager
            let targetWM = targetCtx.workspaceManager

            let destWSID: UUID
            if let twid = targetWorkspaceID {
                destWSID = twid
            } else if let selected = targetWM.selectedWorkspaceID {
                destWSID = selected
            } else {
                throw JSONRPCError(code: -32001, message: "Target window has no workspace")
            }

            guard let transfer = panelManager.detachPanel(id: surfaceID) else {
                throw JSONRPCError(code: -32001, message: "Failed to detach surface")
            }

            guard let attached = targetPM.attachPanel(transfer, inWorkspace: destWSID, paneID: targetPaneID, atIndex: index, focus: focus) else {
                panelManager.attachPanel(transfer, inWorkspace: sourceWorkspaceID)
                throw JSONRPCError(code: -32001, message: "Failed to attach surface to target window")
            }

            return .success(id: req.id, result: .object([
                "surface_id":   .string(attached.uuidString),
                "workspace_id": .string(destWSID.uuidString),
                "window_id":    .string(winID.uuidString),
            ]))
        }

        // Determine destination workspace: explicit workspace_id > pane_id's workspace > source workspace
        let destWorkspaceID: UUID
        if let twid = targetWorkspaceID {
            destWorkspaceID = twid
        } else if let tpid = targetPaneID {
            // Find which workspace contains this pane
            let found = panelManager.engines.first { _, eng in eng.allPaneIDs.contains(tpid) }
            destWorkspaceID = found?.key ?? sourceWorkspaceID
        } else {
            destWorkspaceID = sourceWorkspaceID
        }

        // Code path 1: Same-workspace move (reorder or move between panes)
        if destWorkspaceID == sourceWorkspaceID {
            if let tpid = targetPaneID {
                guard panelManager.moveSurface(panelID: surfaceID, toPaneID: tpid, inWorkspace: destWorkspaceID, atIndex: index, focus: focus) else {
                    throw JSONRPCError(code: -32001, message: "Failed to move surface within workspace")
                }
            } else if let idx = index {
                guard panelManager.reorderSurface(panelID: surfaceID, inWorkspace: destWorkspaceID, toIndex: idx) else {
                    throw JSONRPCError(code: -32001, message: "Failed to reorder surface")
                }
            }
            return .success(id: req.id, result: .object([
                "surface_id":   .string(surfaceID.uuidString),
                "workspace_id": .string(destWorkspaceID.uuidString),
            ]))
        }

        // Code path 2: Cross-workspace move (detach + attach)
        guard let transfer = panelManager.detachPanel(id: surfaceID) else {
            throw JSONRPCError(code: -32001, message: "Failed to detach surface")
        }

        guard let attached = panelManager.attachPanel(transfer, inWorkspace: destWorkspaceID, paneID: targetPaneID, atIndex: index, focus: focus) else {
            // Rollback: reattach to source workspace
            panelManager.attachPanel(transfer, inWorkspace: sourceWorkspaceID)
            throw JSONRPCError(code: -32001, message: "Failed to attach surface to target workspace")
        }

        return .success(id: req.id, result: .object([
            "surface_id":   .string(attached.uuidString),
            "workspace_id": .string(destWorkspaceID.uuidString),
        ]))
    }
}

// MARK: - Helpers

private extension JSONRPCResponse {
    static func notAvailable(_ req: JSONRPCRequest) -> JSONRPCResponse {
        .failure(id: req.id, error: .internalError("Service unavailable"))
    }
}
