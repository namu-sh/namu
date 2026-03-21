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
        } else if let focused = workspace.focusedPanelID {
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
        } else if let focused = workspace.focusedPanelID {
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

        panelManager.focusPanel(id: pid)
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
        } else if let focused = workspace.focusedPanelID {
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
        } else if let focused = workspace.focusedPanelID {
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
}

// MARK: - Helpers

private extension JSONRPCResponse {
    static func notAvailable(_ req: JSONRPCRequest) -> JSONRPCResponse {
        .failure(id: req.id, error: .internalError("Service unavailable"))
    }
}
