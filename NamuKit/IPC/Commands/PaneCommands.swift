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
        // State-mutating commands → .mainActor
        registry.register(HandlerRegistration(method: "pane.split", execution: .mainActor, safety: .normal,
            handler: { [weak self] req in try await self?.split(req) ?? .notAvailable(req) }))
        registry.register(HandlerRegistration(method: "pane.close", execution: .mainActor, safety: .normal,
            handler: { [weak self] req in try await self?.close(req) ?? .notAvailable(req) }))
        registry.register(HandlerRegistration(method: "pane.focus", execution: .mainActor, safety: .normal,
            handler: { [weak self] req in try await self?.focus(req) ?? .notAvailable(req) }))
        registry.register(HandlerRegistration(method: "pane.resize", execution: .mainActor, safety: .normal,
            handler: { [weak self] req in try await self?.resize(req) ?? .notAvailable(req) }))
        registry.register(HandlerRegistration(method: "pane.zoom", execution: .mainActor, safety: .normal,
            handler: { [weak self] req in try await self?.zoom(req) ?? .notAvailable(req) }))
        registry.register(HandlerRegistration(method: "pane.unzoom", execution: .mainActor, safety: .normal,
            handler: { [weak self] req in try await self?.unzoom(req) ?? .notAvailable(req) }))
        registry.register(HandlerRegistration(method: "pane.join", execution: .mainActor, safety: .normal,
            handler: { [weak self] req in try await self?.join(req) ?? .notAvailable(req) }))
        registry.register(HandlerRegistration(method: "pane.last", execution: .mainActor, safety: .normal,
            handler: { [weak self] req in try await self?.lastPane(req) ?? .notAvailable(req) }))
        registry.register(HandlerRegistration(method: "pane.equalize", execution: .mainActor, safety: .normal,
            handler: { [weak self] req in try await self?.equalize(req) ?? .notAvailable(req) }))
        registry.register(HandlerRegistration(method: "pane.new_browser_tab", execution: .mainActor, safety: .normal,
            handler: { [weak self] req in try await self?.newBrowserTab(req) ?? .notAvailable(req) }))
        registry.register(HandlerRegistration(method: "pane.new_markdown_tab", execution: .mainActor, safety: .normal,
            handler: { [weak self] req in try await self?.newMarkdownTab(req) ?? .notAvailable(req) }))
        registry.register(HandlerRegistration(method: "pane.pin", execution: .mainActor, safety: .normal,
            handler: { [weak self] req in try await self?.pinPane(req) ?? .notAvailable(req) }))
        registry.register(HandlerRegistration(method: "pane.unpin", execution: .mainActor, safety: .normal,
            handler: { [weak self] req in try await self?.unpinPane(req) ?? .notAvailable(req) }))

        // Dangerous commands → .mainActor + .dangerous
        registry.register(HandlerRegistration(method: "pane.send_keys", execution: .mainActor, safety: .dangerous,
            handler: { [weak self] req in try await self?.sendKeys(req) ?? .notAvailable(req) }))

        // Read-only queries → .background + .safe
        registry.register(HandlerRegistration(method: "pane.read_screen", execution: .background, safety: .safe,
            handler: { [weak self] req in try await self?.readScreen(req) ?? .notAvailable(req) }))
        registry.register(HandlerRegistration(method: "pane.list", execution: .mainActor, safety: .safe,
            handler: { [weak self] req in try await self?.listPanes(req) ?? .notAvailable(req) }))
    }

    // MARK: - Helpers

    /// Resolve a panel ID from params, falling back to focused panel in the given workspace.
    private func resolvePanel(params: [String: JSONRPCValue], wsID: UUID, key: String = "pane_id") throws -> UUID {
        if let pidValue = params[key], case .string(let pidStr) = pidValue,
           let pid = UUID(uuidString: pidStr) {
            guard panelManager.panel(for: pid) != nil else {
                throw JSONRPCError(code: -32001, message: "Pane not found")
            }
            return pid
        }
        guard let focused = panelManager.focusedPanelID(in: wsID) else {
            throw JSONRPCError(code: -32001, message: "No focused pane")
        }
        return focused
    }

    private func requireWorkspaceID() throws -> UUID {
        guard let wsID = workspaceManager.selectedWorkspaceID else {
            throw JSONRPCError(code: -32001, message: "No active workspace")
        }
        return wsID
    }

    // MARK: - pane.split

    private func split(_ req: JSONRPCRequest) async throws -> JSONRPCResponse {
        let params = req.params?.object ?? [:]

        guard let dirValue = params["direction"], case .string(let dirStr) = dirValue,
              let direction = SplitDirection(rawValue: dirStr) else {
            throw JSONRPCError(code: -32602, message: "Missing or invalid param: direction (horizontal|vertical)")
        }

        let wsID = try requireWorkspaceID()
        // Resolve pane_id if provided (just for validation), split uses the engine's focused pane
        let _ = try resolvePanel(params: params, wsID: wsID)

        panelManager.splitPane(in: wsID, direction: direction)

        // Get the newly focused panel (the new split)
        let newPanelID = panelManager.focusedPanelID(in: wsID)

        return .success(id: req.id, result: .object([
            "pane_id":      .string(newPanelID?.uuidString ?? ""),
            "workspace_id": .string(wsID.uuidString),
            "direction":    .string(dirStr)
        ]))
    }

    // MARK: - pane.close

    private func close(_ req: JSONRPCRequest) async throws -> JSONRPCResponse {
        let params = req.params?.object ?? [:]
        let wsID = try requireWorkspaceID()
        let panelID = try resolvePanel(params: params, wsID: wsID)

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

        // Resolve workspace
        let wsID: UUID
        if let wsValue = params["workspace_id"], case .string(let wsStr) = wsValue,
           let requestedWsID = UUID(uuidString: wsStr),
           workspaceManager.workspaces.contains(where: { $0.id == requestedWsID }) {
            wsID = requestedWsID
            if workspaceManager.selectedWorkspaceID != wsID {
                workspaceManager.selectWorkspace(id: wsID)
            }
        } else {
            wsID = try requireWorkspaceID()
        }

        guard panelManager.panel(for: pid) != nil else {
            throw JSONRPCError(code: -32001, message: "Pane not found")
        }

        panelManager.activatePanel(id: pid)
        return .success(id: req.id, result: .object([
            "pane_id":      .string(pidStr),
            "workspace_id": .string(wsID.uuidString)
        ]))
    }

    // MARK: - pane.resize

    private func resize(_ req: JSONRPCRequest) async throws -> JSONRPCResponse {
        let params = req.params?.object ?? [:]
        let wsID = try requireWorkspaceID()

        // Original API: split_id + ratio
        if let splitValue = params["split_id"], case .string(let splitStr) = splitValue,
           let splitID = UUID(uuidString: splitStr) {
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

            panelManager.resizeSplit(in: wsID, splitID: splitID, ratio: CGFloat(ratio))
            return .success(id: req.id, result: .object([
                "split_id": .string(splitStr),
                "ratio":    .double(ratio)
            ]))
        }

        // Directional resize: direction + amount (pixels)
        if let dirValue = params["direction"], case .string(let dirStr) = dirValue {
            let amount: CGFloat
            switch params["amount"] {
            case .some(.double(let d)): amount = CGFloat(d)
            case .some(.int(let i)):    amount = CGFloat(i)
            default:                   amount = 20.0  // default 20 pixels per step
            }
            let moved = panelManager.resizeSplitDirectional(in: wsID, direction: dirStr, amount: amount)
            return .success(id: req.id, result: .object([
                "direction": .string(dirStr),
                "amount":    .double(Double(amount)),
                "moved":     .bool(moved)
            ]))
        }

        return .success(id: req.id, result: .object([:]))
    }

    // MARK: - pane.send_keys

    private func sendKeys(_ req: JSONRPCRequest) async throws -> JSONRPCResponse {
        let params = req.params?.object ?? [:]

        guard let keysValue = params["keys"], case .string(let keys) = keysValue else {
            throw JSONRPCError(code: -32602, message: "Missing required param: keys")
        }

        let wsID = try requireWorkspaceID()
        let panelID = try resolvePanel(params: params, wsID: wsID)

        guard let panel = panelManager.panel(for: panelID) else {
            throw JSONRPCError(code: -32001, message: "Panel not available")
        }

        panel.session.sendText(keys)

        return .success(id: req.id, result: .object([
            "pane_id":      .string(panelID.uuidString),
            "workspace_id": .string(wsID.uuidString),
            "sent":         .bool(true)
        ]))
    }

    // MARK: - pane.read_screen

    private func readScreen(_ req: JSONRPCRequest) async throws -> JSONRPCResponse {
        let params = req.params?.object ?? [:]
        let wsID = try requireWorkspaceID()
        let panelID = try resolvePanel(params: params, wsID: wsID)

        guard let panel = panelManager.panel(for: panelID) else {
            throw JSONRPCError(code: -32001, message: "Panel not available")
        }

        let text = panel.session.readVisibleText() ?? ""

        return .success(id: req.id, result: .object([
            "pane_id":      .string(panelID.uuidString),
            "workspace_id": .string(wsID.uuidString),
            "text":         .string(text)
        ]))
    }

    // MARK: - pane.zoom

    private func zoom(_ req: JSONRPCRequest) async throws -> JSONRPCResponse {
        let wsID = try requireWorkspaceID()
        panelManager.toggleZoom(in: wsID)
        return .success(id: req.id, result: .object([
            "workspace_id": .string(wsID.uuidString),
            "zoomed":       .bool(true)
        ]))
    }

    // MARK: - pane.unzoom

    private func unzoom(_ req: JSONRPCRequest) async throws -> JSONRPCResponse {
        let wsID = try requireWorkspaceID()
        panelManager.toggleZoom(in: wsID)
        return .success(id: req.id, result: .object([
            "workspace_id": .string(wsID.uuidString),
            "zoomed":       .bool(false)
        ]))
    }

    // MARK: - pane.join

    private func join(_ req: JSONRPCRequest) async throws -> JSONRPCResponse {
        let params = req.params?.object ?? [:]
        let wsID = try requireWorkspaceID()

        guard let pidValue = params["pane_id"], case .string(let pidStr) = pidValue,
              let panelID = UUID(uuidString: pidStr) else {
            throw JSONRPCError(code: -32602, message: "Missing required param: pane_id")
        }

        guard panelManager.panel(for: panelID) != nil else {
            throw JSONRPCError(code: -32001, message: "Pane not found")
        }

        guard panelManager.allPanelIDs(in: wsID).count > 1 else {
            throw JSONRPCError(code: -32001, message: "Cannot join the last pane in a workspace")
        }

        panelManager.closePanel(id: panelID)
        return .success(id: req.id, result: .object([
            "pane_id":      .string(pidStr),
            "workspace_id": .string(wsID.uuidString),
            "joined":       .bool(true)
        ]))
    }

    // MARK: - pane.list

    private func listPanes(_ req: JSONRPCRequest) async throws -> JSONRPCResponse {
        let params = req.params?.object ?? [:]

        let wsID: UUID
        if let wsValue = params["workspace_id"], case .string(let wsStr) = wsValue,
           let requestedWsID = UUID(uuidString: wsStr) {
            guard workspaceManager.workspaces.contains(where: { $0.id == requestedWsID }) else {
                throw JSONRPCError(code: -32001, message: "Workspace not found")
            }
            wsID = requestedWsID
        } else {
            wsID = try requireWorkspaceID()
        }

        let panelIDs = panelManager.allPanelIDs(in: wsID)
        let focusedID = panelManager.focusedPanelID(in: wsID)
        var paneItems: [JSONRPCValue] = []

        for (index, panelID) in panelIDs.enumerated() {
            let panel = panelManager.panel(for: panelID)
            let title = panel?.title ?? ""
            let ref = "%\(panelID.uuidString)"
            var item: [String: JSONRPCValue] = [
                "id":           .string(panelID.uuidString),
                "ref":          .string(ref),
                "index":        .int(index),
                "workspace_id": .string(wsID.uuidString),
                "active":       .bool(panelID == focusedID),
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

    // MARK: - pane.equalize

    private func equalize(_ req: JSONRPCRequest) async throws -> JSONRPCResponse {
        let params = req.params?.object ?? [:]

        let wsID: UUID
        if let wsValue = params["workspace_id"], case .string(let wsStr) = wsValue,
           let requestedWsID = UUID(uuidString: wsStr) {
            guard workspaceManager.workspaces.contains(where: { $0.id == requestedWsID }) else {
                throw JSONRPCError(code: -32001, message: "Workspace not found")
            }
            wsID = requestedWsID
        } else {
            wsID = try requireWorkspaceID()
        }

        let orientation: String?
        if let oriValue = params["orientation"], case .string(let oriStr) = oriValue {
            guard oriStr == "vertical" || oriStr == "horizontal" else {
                throw JSONRPCError(code: -32602, message: "orientation must be 'vertical' or 'horizontal'")
            }
            orientation = oriStr
        } else {
            orientation = nil
        }

        let changed = panelManager.equalizeSplits(in: wsID, orientation: orientation)
        return .success(id: req.id, result: .object([
            "workspace_id": .string(wsID.uuidString),
            "changed":      .bool(changed)
        ]))
    }

    // MARK: - pane.last

    private func lastPane(_ req: JSONRPCRequest) async throws -> JSONRPCResponse {
        let wsID = try requireWorkspaceID()

        guard let previousID = panelManager.previousFocusedPanelID,
              panelManager.panel(for: previousID) != nil else {
            throw JSONRPCError(code: -32001, message: "No previous pane")
        }

        panelManager.activatePanel(id: previousID)
        return .success(id: req.id, result: .object([
            "pane_id":      .string(previousID.uuidString),
            "workspace_id": .string(wsID.uuidString)
        ]))
    }

    // MARK: - pane.pin

    private func pinPane(_ req: JSONRPCRequest) async throws -> JSONRPCResponse {
        let params = req.params?.object ?? [:]
        let wsID = try requireWorkspaceID()
        let panelID = try resolvePanel(params: params, wsID: wsID)

        if !panelManager.isPanelPinned(id: panelID) {
            panelManager.togglePanelPin(id: panelID)
        }
        return .success(id: req.id, result: .object([
            "pane_id": .string(panelID.uuidString),
            "pinned":  .bool(true)
        ]))
    }

    // MARK: - pane.unpin

    private func unpinPane(_ req: JSONRPCRequest) async throws -> JSONRPCResponse {
        let params = req.params?.object ?? [:]
        let wsID = try requireWorkspaceID()
        let panelID = try resolvePanel(params: params, wsID: wsID)

        if panelManager.isPanelPinned(id: panelID) {
            panelManager.togglePanelPin(id: panelID)
        }
        return .success(id: req.id, result: .object([
            "pane_id": .string(panelID.uuidString),
            "pinned":  .bool(false)
        ]))
    }

    // MARK: - pane.new_browser_tab

    private func newBrowserTab(_ req: JSONRPCRequest) async throws -> JSONRPCResponse {
        let params = req.params?.object ?? [:]
        let wsID = try requireWorkspaceID()

        let url: URL?
        if let urlValue = params["url"], case .string(let urlStr) = urlValue {
            url = URL(string: urlStr)
        } else {
            url = nil
        }

        panelManager.createBrowserTabInFocusedPane(url: url)

        let newPanelID = panelManager.focusedPanelID(in: wsID)
        return .success(id: req.id, result: .object([
            "pane_id":      .string(newPanelID?.uuidString ?? ""),
            "workspace_id": .string(wsID.uuidString),
            "type":         .string("browser")
        ]))
    }

    // MARK: - pane.new_markdown_tab

    private func newMarkdownTab(_ req: JSONRPCRequest) async throws -> JSONRPCResponse {
        let params = req.params?.object ?? [:]
        let wsID = try requireWorkspaceID()

        let fileURL: URL?
        if let fileValue = params["file"], case .string(let filePath) = fileValue, !filePath.isEmpty {
            fileURL = URL(fileURLWithPath: filePath)
        } else {
            fileURL = nil
        }

        panelManager.createMarkdownTabInFocusedPane(fileURL: fileURL)

        let newPanelID = panelManager.focusedPanelID(in: wsID)
        return .success(id: req.id, result: .object([
            "pane_id":      .string(newPanelID?.uuidString ?? ""),
            "workspace_id": .string(wsID.uuidString),
            "type":         .string("markdown"),
            "file":         .string(fileURL?.path ?? "")
        ]))
    }
}

// MARK: - Helpers

private extension JSONRPCResponse {
    static func notAvailable(_ req: JSONRPCRequest) -> JSONRPCResponse {
        .failure(id: req.id, error: .internalError("Service unavailable"))
    }
}
