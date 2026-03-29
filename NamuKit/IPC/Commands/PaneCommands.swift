import Foundation

/// Handlers for the pane.* command namespace.
/// Focus policy: only pane.focus steals focus. All others preserve current focus.
@MainActor
final class PaneCommands {

    private let workspaceManager: WorkspaceManager
    private let panelManager: PanelManager

    /// Tracks the previously focused pane for pane.last navigation.
    private var previousFocusedPanelID: UUID?

    init(workspaceManager: WorkspaceManager, panelManager: PanelManager) {
        self.workspaceManager = workspaceManager
        self.panelManager = panelManager
    }

    // MARK: - Registration

    func register(in registry: CommandRegistry) {
        // State-mutating commands → .mainActor
        registry.register(HandlerRegistration(method: "pane.split", execution: .mainActor, safety: .normal,
            handler: { [weak self] req in try await self?.split(req) ?? .notAvailable(req) }))
        registry.register(HandlerRegistration(method: "pane.close", execution: .mainActor, safety: .normal,
            handler: { [weak self] req in try await self?.close(req) ?? .notAvailable(req) }))
        registry.register(HandlerRegistration(method: "pane.focus", execution: .mainActor, safety: .normal,
            handler: { [weak self] req in try await self?.focus(req) ?? .notAvailable(req) }))
        registry.register(HandlerRegistration(method: "pane.resize", execution: .mainActor, safety: .normal,
            handler: { [weak self] req in try await self?.resize(req) ?? .notAvailable(req) }))
        registry.register(HandlerRegistration(method: "pane.swap", execution: .mainActor, safety: .normal,
            handler: { [weak self] req in try await self?.swap(req) ?? .notAvailable(req) }))
        registry.register(HandlerRegistration(method: "pane.zoom", execution: .mainActor, safety: .normal,
            handler: { [weak self] req in try await self?.zoom(req) ?? .notAvailable(req) }))
        registry.register(HandlerRegistration(method: "pane.unzoom", execution: .mainActor, safety: .normal,
            handler: { [weak self] req in try await self?.unzoom(req) ?? .notAvailable(req) }))
        registry.register(HandlerRegistration(method: "pane.join", execution: .mainActor, safety: .normal,
            handler: { [weak self] req in try await self?.join(req) ?? .notAvailable(req) }))
        registry.register(HandlerRegistration(method: "pane.break", execution: .mainActor, safety: .normal,
            handler: { [weak self] req in try await self?.breakOut(req) ?? .notAvailable(req) }))
        registry.register(HandlerRegistration(method: "pane.last", execution: .mainActor, safety: .normal,
            handler: { [weak self] req in try await self?.lastPane(req) ?? .notAvailable(req) }))

        // Dangerous commands → .mainActor + .dangerous
        registry.register(HandlerRegistration(method: "pane.send_keys", execution: .mainActor, safety: .dangerous,
            handler: { [weak self] req in try await self?.sendKeys(req) ?? .notAvailable(req) }))

        // Read-only queries → .background + .safe
        registry.register(HandlerRegistration(method: "pane.read_screen", execution: .background, safety: .safe,
            handler: { [weak self] req in try await self?.readScreen(req) ?? .notAvailable(req) }))
        registry.register(HandlerRegistration(method: "pane.list", execution: .mainActor, safety: .safe,
            handler: { [weak self] req in try await self?.listPanes(req) ?? .notAvailable(req) }))
    }

    // MARK: - pane.split

    private func split(_ req: JSONRPCRequest) async throws -> JSONRPCResponse {
        let params = req.params?.object ?? [:]

        // Parse direction
        guard let dirValue = params["direction"], case .string(let dirStr) = dirValue,
              let direction = SplitDirection(rawValue: dirStr) else {
            throw JSONRPCError(code: -32602, message: "Missing or invalid param: direction (horizontal|vertical)")
        }

        guard let workspace = workspaceManager.selectedWorkspace else {
            throw JSONRPCError(code: -32001, message: "No active workspace")
        }

        // Determine which pane to split: use provided pane_id, else focused pane
        let targetPanelID: UUID
        if let pidValue = params["pane_id"], case .string(let pidStr) = pidValue,
           let pid = UUID(uuidString: pidStr) {
            guard workspace.paneTree.findPane(id: pid) != nil else {
                throw JSONRPCError(code: -32001, message: "Pane not found")
            }
            targetPanelID = pid
        } else if let focused = workspace.activePanelID {
            targetPanelID = focused
        } else {
            throw JSONRPCError(code: -32001, message: "No focused pane to split")
        }

        let newPanel = panelManager.createTerminalPanel()
        panelManager.splitPanel(id: targetPanelID, direction: direction, newPanel: newPanel)

        return .success(id: req.id, result: .object([
            "pane_id":            .string(newPanel.id.uuidString),
            "workspace_id":       .string(workspace.id.uuidString),
            "direction":          .string(dirStr)
        ]))
    }

    // MARK: - pane.close

    private func close(_ req: JSONRPCRequest) async throws -> JSONRPCResponse {
        let params = req.params?.object ?? [:]

        guard let workspace = workspaceManager.selectedWorkspace else {
            throw JSONRPCError(code: -32001, message: "No active workspace")
        }

        let panelID: UUID
        if let pidValue = params["pane_id"], case .string(let pidStr) = pidValue,
           let pid = UUID(uuidString: pidStr) {
            guard workspace.paneTree.findPane(id: pid) != nil else {
                throw JSONRPCError(code: -32001, message: "Pane not found")
            }
            panelID = pid
        } else if let focused = workspace.activePanelID {
            panelID = focused
        } else {
            throw JSONRPCError(code: -32001, message: "No pane to close")
        }

        panelManager.closePanel(id: panelID)
        return .success(id: req.id, result: .object([
            "pane_id": .string(panelID.uuidString)
        ]))
    }

    // MARK: - pane.focus  (focus-stealing command)

    private func focus(_ req: JSONRPCRequest) async throws -> JSONRPCResponse {
        let params = req.params?.object ?? [:]
        guard let pidValue = params["pane_id"], case .string(let pidStr) = pidValue,
              let pid = UUID(uuidString: pidStr) else {
            throw JSONRPCError.invalidParams
        }

        // Resolve workspace: accept workspace_id param or fall back to selected
        let workspace: Workspace
        if let wsValue = params["workspace_id"], case .string(let wsStr) = wsValue,
           let wsID = UUID(uuidString: wsStr),
           let ws = workspaceManager.workspaces.first(where: { $0.id == wsID }) {
            workspace = ws
            // Ensure correct workspace is selected if a different one was specified
            if workspaceManager.selectedWorkspaceID != wsID {
                workspaceManager.selectWorkspace(id: wsID)
            }
        } else {
            guard let ws = workspaceManager.selectedWorkspace else {
                throw JSONRPCError(code: -32001, message: "No active workspace")
            }
            workspace = ws
        }

        guard workspace.paneTree.findPane(id: pid) != nil else {
            throw JSONRPCError(code: -32001, message: "Pane not found")
        }

        // Track previous pane for pane.last
        if let current = workspace.activePanelID {
            previousFocusedPanelID = current
        }

        panelManager.activatePanel(id: pid)
        return .success(id: req.id, result: .object([
            "pane_id":      .string(pidStr),
            "workspace_id": .string(workspace.id.uuidString)
        ]))
    }

    // MARK: - pane.resize

    private func resize(_ req: JSONRPCRequest) async throws -> JSONRPCResponse {
        let params = req.params?.object ?? [:]

        // Support two calling conventions:
        // 1. split_id + ratio (original API)
        // 2. pane_id + direction + amount (tmux compat)

        if let dirValue = params["direction"], case .string(let dirStr) = dirValue {
            // tmux compat: pane_id + direction + amount
            let paneID: UUID
            if let pidValue = params["pane_id"], case .string(let pidStr) = pidValue,
               let pid = UUID(uuidString: pidStr) {
                paneID = pid
            } else if let workspace = workspaceManager.selectedWorkspace,
                      let focused = workspace.activePanelID {
                paneID = focused
            } else {
                throw JSONRPCError(code: -32001, message: "No target pane")
            }

            let ghosttyDir: ghostty_action_resize_split_direction_e
            switch dirStr {
            case "left":  ghosttyDir = GHOSTTY_RESIZE_SPLIT_LEFT
            case "right": ghosttyDir = GHOSTTY_RESIZE_SPLIT_RIGHT
            case "up":    ghosttyDir = GHOSTTY_RESIZE_SPLIT_UP
            case "down":  ghosttyDir = GHOSTTY_RESIZE_SPLIT_DOWN
            default:
                throw JSONRPCError(code: -32602, message: "Invalid direction: \(dirStr)")
            }

            let amount: Int
            switch params["amount"] {
            case .some(.int(let i)):    amount = i
            case .some(.double(let d)): amount = Int(d)
            default:                    amount = 5
            }

            guard var workspace = workspaceManager.selectedWorkspace else {
                throw JSONRPCError(code: -32001, message: "No active workspace")
            }

            let delta = Double(amount) / 100.0
            guard let (splitID, newRatio) = workspace.paneTree.adjustSplitRatio(
                containing: paneID, direction: ghosttyDir, delta: delta
            ) else {
                // No split found in that direction — silently succeed
                return .success(id: req.id, result: .object([:]))
            }

            panelManager.resizeSplit(splitID: splitID, ratio: newRatio)
            return .success(id: req.id, result: .object([
                "pane_id":   .string(paneID.uuidString),
                "direction": .string(dirStr),
                "amount":    .int(amount)
            ]))
        }

        // Original API: split_id + ratio
        guard let splitValue = params["split_id"], case .string(let splitStr) = splitValue,
              let splitID = UUID(uuidString: splitStr) else {
            throw JSONRPCError(code: -32602, message: "Missing or invalid param: split_id or direction")
        }

        let ratio: Double
        switch params["ratio"] {
        case .some(.double(let d)): ratio = d
        case .some(.int(let i)):    ratio = Double(i)
        default:
            throw JSONRPCError(code: -32602, message: "Missing or invalid param: ratio (0.0-1.0)")
        }

        guard (0.05...0.95).contains(ratio) else {
            throw JSONRPCError(code: -32602, message: "ratio must be between 0.05 and 0.95")
        }

        panelManager.resizeSplit(splitID: splitID, ratio: ratio)
        return .success(id: req.id, result: .object([
            "split_id": .string(splitStr),
            "ratio":    .double(ratio)
        ]))
    }

    // MARK: - pane.swap

    private func swap(_ req: JSONRPCRequest) async throws -> JSONRPCResponse {
        let params = req.params?.object ?? [:]

        guard let aValue = params["pane_id"], case .string(let aStr) = aValue,
              let idA = UUID(uuidString: aStr) else {
            throw JSONRPCError(code: -32602, message: "Missing or invalid param: pane_id")
        }

        guard let bValue = params["target_pane_id"], case .string(let bStr) = bValue,
              let idB = UUID(uuidString: bStr) else {
            throw JSONRPCError(code: -32602, message: "Missing or invalid param: target_pane_id")
        }

        guard let workspace = workspaceManager.selectedWorkspace else {
            throw JSONRPCError(code: -32001, message: "No active workspace")
        }

        guard workspace.paneTree.findPane(id: idA) != nil else {
            throw JSONRPCError(code: -32001, message: "Pane not found: pane_id")
        }
        guard workspace.paneTree.findPane(id: idB) != nil else {
            throw JSONRPCError(code: -32001, message: "Pane not found: target_pane_id")
        }

        panelManager.swapPanes(id: idA, with: idB)

        return .success(id: req.id, result: .object([
            "pane_id":        .string(aStr),
            "target_pane_id": .string(bStr),
            "workspace_id":   .string(workspace.id.uuidString)
        ]))
    }

    // MARK: - pane.send_keys

    private func sendKeys(_ req: JSONRPCRequest) async throws -> JSONRPCResponse {
        let params = req.params?.object ?? [:]

        guard let keysValue = params["keys"], case .string(let keys) = keysValue else {
            throw JSONRPCError(code: -32602, message: "Missing required param: keys")
        }

        guard let workspace = workspaceManager.selectedWorkspace else {
            throw JSONRPCError(code: -32001, message: "No active workspace")
        }

        let panelID: UUID
        if let pidValue = params["pane_id"], case .string(let pidStr) = pidValue,
           let pid = UUID(uuidString: pidStr) {
            guard workspace.paneTree.findPane(id: pid) != nil else {
                throw JSONRPCError(code: -32001, message: "Pane not found")
            }
            panelID = pid
        } else if let focused = workspace.activePanelID {
            panelID = focused
        } else {
            throw JSONRPCError(code: -32001, message: "No target pane")
        }

        guard let panel = panelManager.panel(for: panelID) else {
            throw JSONRPCError(code: -32001, message: "Panel not available")
        }

        panel.session.sendText(keys)

        return .success(id: req.id, result: .object([
            "pane_id":      .string(panelID.uuidString),
            "workspace_id": .string(workspace.id.uuidString),
            "sent":         .bool(true)
        ]))
    }

    // MARK: - pane.read_screen

    private func readScreen(_ req: JSONRPCRequest) async throws -> JSONRPCResponse {
        let params = req.params?.object ?? [:]

        guard let workspace = workspaceManager.selectedWorkspace else {
            throw JSONRPCError(code: -32001, message: "No active workspace")
        }

        let panelID: UUID
        if let pidValue = params["pane_id"], case .string(let pidStr) = pidValue,
           let pid = UUID(uuidString: pidStr) {
            guard workspace.paneTree.findPane(id: pid) != nil else {
                throw JSONRPCError(code: -32001, message: "Pane not found")
            }
            panelID = pid
        } else if let focused = workspace.activePanelID {
            panelID = focused
        } else {
            throw JSONRPCError(code: -32001, message: "No target pane")
        }

        guard let panel = panelManager.panel(for: panelID) else {
            throw JSONRPCError(code: -32001, message: "Panel not available")
        }

        let text = panel.session.readVisibleText() ?? ""

        return .success(id: req.id, result: .object([
            "pane_id":      .string(panelID.uuidString),
            "workspace_id": .string(workspace.id.uuidString),
            "text":         .string(text)
        ]))
    }
    // MARK: - pane.zoom

    private func zoom(_ req: JSONRPCRequest) async throws -> JSONRPCResponse {
        let params = req.params?.object ?? [:]

        guard let workspace = workspaceManager.selectedWorkspace else {
            throw JSONRPCError(code: -32001, message: "No active workspace")
        }

        let panelID: UUID
        if let pidValue = params["pane_id"], case .string(let pidStr) = pidValue,
           let pid = UUID(uuidString: pidStr) {
            guard workspace.paneTree.findPane(id: pid) != nil else {
                throw JSONRPCError(code: -32001, message: "Pane not found")
            }
            panelID = pid
        } else if let focused = workspace.activePanelID {
            panelID = focused
        } else {
            throw JSONRPCError(code: -32001, message: "No target pane")
        }

        panelManager.zoomPanel(id: panelID)
        return .success(id: req.id, result: .object([
            "pane_id":      .string(panelID.uuidString),
            "workspace_id": .string(workspace.id.uuidString),
            "zoomed":       .bool(true)
        ]))
    }

    // MARK: - pane.unzoom

    private func unzoom(_ req: JSONRPCRequest) async throws -> JSONRPCResponse {
        guard let workspace = workspaceManager.selectedWorkspace else {
            throw JSONRPCError(code: -32001, message: "No active workspace")
        }

        panelManager.unzoomPanel()
        return .success(id: req.id, result: .object([
            "workspace_id": .string(workspace.id.uuidString),
            "zoomed":       .bool(false)
        ]))
    }

    // MARK: - pane.join
    //
    // Close one pane, letting the sibling expand to fill the space.
    // Equivalent to pane.close but with explicit semantics for the "join" operation.
    // Params: pane_id (string, required) — the pane to close/absorb.

    private func join(_ req: JSONRPCRequest) async throws -> JSONRPCResponse {
        let params = req.params?.object ?? [:]

        guard let workspace = workspaceManager.selectedWorkspace else {
            throw JSONRPCError(code: -32001, message: "No active workspace")
        }

        guard let pidValue = params["pane_id"], case .string(let pidStr) = pidValue,
              let panelID = UUID(uuidString: pidStr) else {
            throw JSONRPCError(code: -32602, message: "Missing required param: pane_id")
        }

        guard workspace.paneTree.findPane(id: panelID) != nil else {
            throw JSONRPCError(code: -32001, message: "Pane not found")
        }

        guard workspace.paneTree.paneCount > 1 else {
            throw JSONRPCError(code: -32001, message: "Cannot join the last pane in a workspace")
        }

        panelManager.closePanel(id: panelID)
        return .success(id: req.id, result: .object([
            "pane_id":      .string(pidStr),
            "workspace_id": .string(workspace.id.uuidString),
            "joined":       .bool(true)
        ]))
    }

    // MARK: - pane.break
    //
    // Extract a pane from the current workspace into a new workspace.
    // Params: pane_id (string, optional) — defaults to focused pane.

    private func breakOut(_ req: JSONRPCRequest) async throws -> JSONRPCResponse {
        let params = req.params?.object ?? [:]

        guard let workspace = workspaceManager.selectedWorkspace else {
            throw JSONRPCError(code: -32001, message: "No active workspace")
        }

        let panelID: UUID
        if let pidValue = params["pane_id"], case .string(let pidStr) = pidValue,
           let pid = UUID(uuidString: pidStr) {
            guard workspace.paneTree.findPane(id: pid) != nil else {
                throw JSONRPCError(code: -32001, message: "Pane not found")
            }
            panelID = pid
        } else if let focused = workspace.activePanelID {
            panelID = focused
        } else {
            throw JSONRPCError(code: -32001, message: "No target pane")
        }

        guard let newWorkspaceID = panelManager.breakOutPanel(id: panelID) else {
            throw JSONRPCError(code: -32001, message: "Failed to break out pane")
        }

        return .success(id: req.id, result: .object([
            "pane_id":           .string(panelID.uuidString),
            "new_workspace_id":  .string(newWorkspaceID.uuidString)
        ]))
    }

    // MARK: - pane.list

    private func listPanes(_ req: JSONRPCRequest) async throws -> JSONRPCResponse {
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

        let panels = workspace.allPanels
        var paneItems: [JSONRPCValue] = []
        for (index, leaf) in panels.enumerated() {
            let isFocused = workspace.activePanelID == leaf.id
            let panel = panelManager.panel(for: leaf.id)
            let title = panel?.title ?? ""
            let ref = "%\(leaf.id.uuidString)"
            var item: [String: JSONRPCValue] = [
                "id":           .string(leaf.id.uuidString),
                "ref":          .string(ref),
                "index":        .int(index),
                "workspace_id": .string(workspace.id.uuidString),
                "active":       .bool(isFocused),
                "title":        .string(title)
            ]
            if let panel {
                let cell = panel.cellSize
                let frame = panel.surfaceView.frame.size
                if cell.width > 0 && cell.height > 0 {
                    item["columns"] = .int(Int(frame.width / cell.width))
                    item["rows"] = .int(Int(frame.height / cell.height))
                    item["cell_width_px"] = .double(Double(cell.width))
                    item["cell_height_px"] = .double(Double(cell.height))
                }
                item["pixel_width"] = .int(Int(frame.width))
                item["pixel_height"] = .int(Int(frame.height))
            }
            paneItems.append(.object(item))
        }

        return .success(id: req.id, result: .object([
            "panes": .array(paneItems)
        ]))
    }

    // MARK: - pane.last

    private func lastPane(_ req: JSONRPCRequest) async throws -> JSONRPCResponse {
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

        guard let previousID = previousFocusedPanelID,
              workspace.paneTree.findPane(id: previousID) != nil else {
            throw JSONRPCError(code: -32001, message: "No previous pane")
        }

        // Track current before switching
        if let current = workspace.activePanelID {
            previousFocusedPanelID = current
        }

        panelManager.activatePanel(id: previousID)
        return .success(id: req.id, result: .object([
            "pane_id":      .string(previousID.uuidString),
            "workspace_id": .string(workspace.id.uuidString)
        ]))
    }
}

// MARK: - Helpers

private extension JSONRPCResponse {
    static func notAvailable(_ req: JSONRPCRequest) -> JSONRPCResponse {
        .failure(id: req.id, error: .internalError("Service unavailable"))
    }
}
