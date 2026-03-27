import Foundation

/// Handlers for the pane.* command namespace.
/// Focus policy: only pane.focus steals focus. All others preserve current focus.
@MainActor
final class PaneCommands {

    private let workspaceManager: WorkspaceManager
    private let panelManager: PanelManager

    init(workspaceManager: WorkspaceManager, panelManager: PanelManager) {
        self.workspaceManager = workspaceManager
        self.panelManager = panelManager
    }

    // MARK: - Registration

    func register(in registry: CommandRegistry) {
        registry.register("pane.split")      { [weak self] req in try await self?.split(req) ?? .notAvailable(req) }
        registry.register("pane.close")      { [weak self] req in try await self?.close(req) ?? .notAvailable(req) }
        registry.register("pane.focus")      { [weak self] req in try await self?.focus(req) ?? .notAvailable(req) }
        registry.register("pane.resize")     { [weak self] req in try await self?.resize(req) ?? .notAvailable(req) }
        registry.register("pane.send_keys")  { [weak self] req in try await self?.sendKeys(req) ?? .notAvailable(req) }
        registry.register("pane.read_screen") { [weak self] req in try await self?.readScreen(req) ?? .notAvailable(req) }
        registry.register("pane.swap")       { [weak self] req in try await self?.swap(req) ?? .notAvailable(req) }
        registry.register("pane.zoom")       { [weak self] req in try await self?.zoom(req) ?? .notAvailable(req) }
        registry.register("pane.unzoom")     { [weak self] req in try await self?.unzoom(req) ?? .notAvailable(req) }
        registry.register("pane.join")       { [weak self] req in try await self?.join(req) ?? .notAvailable(req) }
        registry.register("pane.break")      { [weak self] req in try await self?.breakOut(req) ?? .notAvailable(req) }
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

        guard let workspace = workspaceManager.selectedWorkspace,
              workspace.paneTree.findPane(id: pid) != nil else {
            throw JSONRPCError(code: -32001, message: "Pane not found")
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

        guard let splitValue = params["split_id"], case .string(let splitStr) = splitValue,
              let splitID = UUID(uuidString: splitStr) else {
            throw JSONRPCError(code: -32602, message: "Missing or invalid param: split_id")
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
}

// MARK: - Helpers

private extension JSONRPCResponse {
    static func notAvailable(_ req: JSONRPCRequest) -> JSONRPCResponse {
        .failure(id: req.id, error: .internalError("Service unavailable"))
    }
}
