import Foundation

/// Handlers for the workspace.* command namespace.
/// Focus policy: only workspace.select steals focus. All others preserve current focus.
@MainActor
final class WorkspaceCommands {

    private let workspaceManager: WorkspaceManager
    private let panelManager: PanelManager
    private weak var remoteSessionService: RemoteSessionService?

    /// Tracks the previously selected workspace for workspace.last navigation.
    private var previousSelectedWorkspaceID: UUID?

    init(workspaceManager: WorkspaceManager, panelManager: PanelManager, remoteSessionService: RemoteSessionService? = nil) {
        self.workspaceManager = workspaceManager
        self.panelManager = panelManager
        self.remoteSessionService = remoteSessionService
    }

    // MARK: - Registration

    func register(in registry: CommandRegistry) {
        registry.register("workspace.list")            { [weak self] req in try await self?.list(req) ?? .notAvailable(req) }
        registry.register("workspace.create")          { [weak self] req in try await self?.create(req) ?? .notAvailable(req) }
        registry.register("workspace.create_remote")   { [weak self] req in try await self?.createRemote(req) ?? .notAvailable(req) }
        registry.register("workspace.delete")          { [weak self] req in try await self?.delete(req) ?? .notAvailable(req) }
        registry.register("workspace.select")          { [weak self] req in try await self?.select(req) ?? .notAvailable(req) }
        registry.register("workspace.rename")          { [weak self] req in try await self?.rename(req) ?? .notAvailable(req) }
        registry.register("workspace.pin")             { [weak self] req in try await self?.pin(req) ?? .notAvailable(req) }
        registry.register("workspace.color")           { [weak self] req in try await self?.color(req) ?? .notAvailable(req) }
        registry.register("workspace.current")         { [weak self] req in try await self?.current(req) ?? .notAvailable(req) }
        registry.register("workspace.close")           { [weak self] req in try await self?.closeWorkspace(req) ?? .notAvailable(req) }
        registry.register("workspace.next")            { [weak self] req in try await self?.next(req) ?? .notAvailable(req) }
        registry.register("workspace.previous")        { [weak self] req in try await self?.previous(req) ?? .notAvailable(req) }
        registry.register("workspace.last")            { [weak self] req in try await self?.last(req) ?? .notAvailable(req) }
        registry.register("workspace.remote.status")       { [weak self] req in try await self?.remoteStatus(req) ?? .notAvailable(req) }
        registry.register("workspace.remote.configure")    { [weak self] req in try await self?.remoteConfigure(req) ?? .notAvailable(req) }
        registry.register("workspace.remote.reconnect")    { [weak self] req in try await self?.remoteReconnect(req) ?? .notAvailable(req) }
        registry.register("workspace.remote.disconnect")   { [weak self] req in try await self?.remoteDisconnect(req) ?? .notAvailable(req) }
        registry.register("workspace.remote.terminal_session_end") { [weak self] req in try await self?.remoteTerminalSessionEnd(req) ?? .notAvailable(req) }
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

    // MARK: - workspace.create_remote

    private func createRemote(_ req: JSONRPCRequest) async throws -> JSONRPCResponse {
        let params = req.params?.object ?? [:]

        guard let destValue = params["destination"], case .string(let destination) = destValue, !destination.isEmpty else {
            throw JSONRPCError(code: -32602, message: "Missing required param: destination")
        }

        let title: String
        if let nameValue = params["name"], case .string(let n) = nameValue, !n.isEmpty {
            title = n
        } else {
            title = destination
        }

        let port: Int?
        if let portValue = params["port"], case .int(let p) = portValue {
            // M13: Validate port is in the valid TCP range.
            guard (1...65535).contains(p) else {
                throw JSONRPCError(code: -32602, message: "Port must be between 1 and 65535")
            }
            port = p
        } else {
            port = nil
        }

        let identityFile: String?
        if let idValue = params["identity_file"], case .string(let f) = idValue, !f.isEmpty {
            identityFile = f
        } else {
            identityFile = nil
        }

        var sshOptions: [String] = []
        if let optsValue = params["ssh_options"], case .array(let arr) = optsValue {
            // M12: Reject options containing newlines or null bytes to prevent injection.
            sshOptions = arr.compactMap {
                if case .string(let s) = $0 {
                    let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty,
                          !trimmed.contains("\n"),
                          !trimmed.contains("\r"),
                          !trimmed.contains("\0") else { return nil }
                    return trimmed
                }
                return nil
            }
        }

        let relayPort: Int?
        if let rpValue = params["relay_port"], case .int(let rp) = rpValue {
            guard (1...65535).contains(rp) else {
                throw JSONRPCError(code: -32602, message: "relay_port must be between 1 and 65535")
            }
            relayPort = rp
        } else {
            relayPort = nil
        }

        let relayID: String?
        if let riValue = params["relay_id"], case .string(let ri) = riValue, !ri.isEmpty {
            relayID = ri
        } else {
            relayID = nil
        }

        let relayToken: String?
        if let rtValue = params["relay_token"], case .string(let rt) = rtValue, !rt.isEmpty {
            relayToken = rt
        } else {
            relayToken = nil
        }

        let localSocketPath: String?
        if let lspValue = params["local_socket_path"], case .string(let lsp) = lspValue, !lsp.isEmpty {
            localSocketPath = lsp
        } else {
            localSocketPath = nil
        }

        let terminalStartupCommand: String?
        if let tscValue = params["terminal_startup_command"], case .string(let tsc) = tscValue, !tsc.isEmpty {
            terminalStartupCommand = tsc
        } else {
            terminalStartupCommand = nil
        }

        let localProxyPort: Int?
        if let lppValue = params["local_proxy_port"], case .int(let lpp) = lppValue {
            guard (1...65535).contains(lpp) else {
                throw JSONRPCError(code: -32602, message: "local_proxy_port must be between 1 and 65535")
            }
            localProxyPort = lpp
        } else {
            localProxyPort = nil
        }

        let autoConnect: Bool
        if let acValue = params["auto_connect"], case .bool(let b) = acValue {
            autoConnect = b
        } else {
            autoConnect = true
        }

        guard let service = remoteSessionService else {
            return .failure(id: req.id, error: .internalError("Remote session service unavailable"))
        }

        let ws = panelManager.createWorkspace(title: title)

        let configuration = RemoteConfiguration(
            destination: destination,
            port: port,
            identityFile: identityFile,
            sshOptions: sshOptions,
            localProxyPort: localProxyPort,
            relayPort: relayPort,
            relayID: relayID,
            relayToken: relayToken,
            localSocketPath: localSocketPath,
            terminalStartupCommand: terminalStartupCommand
        )
        service.configureRemoteConnection(
            workspaceID: ws.id,
            configuration: configuration,
            autoConnect: autoConnect
        )

        return .success(id: req.id, result: .object([
            "id":          .string(ws.id.uuidString),
            "title":       .string(ws.title),
            "destination": .string(destination)
        ]))
    }

    // MARK: - workspace.remote.status

    private func remoteStatus(_ req: JSONRPCRequest) async throws -> JSONRPCResponse {
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

        guard let service = remoteSessionService else {
            throw JSONRPCError(code: -32001, message: "Remote session service unavailable")
        }

        guard let payload = service.remoteStatusPayload(workspaceID: workspaceID) else {
            throw JSONRPCError(code: -32001, message: "No remote session for workspace")
        }

        // Convert the [String: Any] payload to JSONRPCValue
        func toValue(_ any: Any) -> JSONRPCValue {
            switch any {
            case let s as String:  return .string(s)
            case let i as Int:     return .int(i)
            case let b as Bool:    return .bool(b)
            case is NSNull:        return .null
            case let d as [String: Any]:
                return .object(d.mapValues { toValue($0) })
            case let a as [Any]:
                return .array(a.map { toValue($0) })
            default:               return .string("\(any)")
            }
        }

        let result = payload.mapValues { toValue($0) }
        return .success(id: req.id, result: .object(result))
    }

    // MARK: - workspace.remote.configure

    private func remoteConfigure(_ req: JSONRPCRequest) async throws -> JSONRPCResponse {
        let params = req.params?.object ?? [:]

        guard let destValue = params["destination"], case .string(let destination) = destValue, !destination.isEmpty else {
            throw JSONRPCError(code: -32602, message: "Missing required param: destination")
        }

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

        let port: Int?
        if let portValue = params["port"], case .int(let p) = portValue {
            // M13: Validate port is in the valid TCP range.
            guard (1...65535).contains(p) else {
                throw JSONRPCError(code: -32602, message: "Port must be between 1 and 65535")
            }
            port = p
        } else {
            port = nil
        }

        let identityFile: String?
        if let idValue = params["identity_file"], case .string(let f) = idValue, !f.isEmpty {
            identityFile = f
        } else {
            identityFile = nil
        }

        var sshOptions: [String] = []
        if let optsValue = params["ssh_options"], case .array(let arr) = optsValue {
            // M12: Reject options containing newlines or null bytes to prevent injection.
            sshOptions = arr.compactMap {
                if case .string(let s) = $0 {
                    let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty,
                          !trimmed.contains("\n"),
                          !trimmed.contains("\r"),
                          !trimmed.contains("\0") else { return nil }
                    return trimmed
                }
                return nil
            }
        }

        let relayPort: Int?
        if let rpValue = params["relay_port"], case .int(let rp) = rpValue {
            guard (1...65535).contains(rp) else {
                throw JSONRPCError(code: -32602, message: "relay_port must be between 1 and 65535")
            }
            relayPort = rp
        } else {
            relayPort = nil
        }

        let relayID: String?
        if let riValue = params["relay_id"], case .string(let ri) = riValue, !ri.isEmpty {
            relayID = ri
        } else {
            relayID = nil
        }

        let relayToken: String?
        if let rtValue = params["relay_token"], case .string(let rt) = rtValue, !rt.isEmpty {
            relayToken = rt
        } else {
            relayToken = nil
        }

        let localSocketPath: String?
        if let lspValue = params["local_socket_path"], case .string(let lsp) = lspValue, !lsp.isEmpty {
            localSocketPath = lsp
        } else {
            localSocketPath = nil
        }

        let terminalStartupCommand: String?
        if let tscValue = params["terminal_startup_command"], case .string(let tsc) = tscValue, !tsc.isEmpty {
            terminalStartupCommand = tsc
        } else {
            terminalStartupCommand = nil
        }

        let localProxyPort: Int?
        if let lppValue = params["local_proxy_port"], case .int(let lpp) = lppValue {
            guard (1...65535).contains(lpp) else {
                throw JSONRPCError(code: -32602, message: "local_proxy_port must be between 1 and 65535")
            }
            localProxyPort = lpp
        } else {
            localProxyPort = nil
        }

        let autoConnect: Bool
        if let acValue = params["auto_connect"], case .bool(let b) = acValue {
            autoConnect = b
        } else {
            autoConnect = true
        }

        guard let service = remoteSessionService else {
            return .failure(id: req.id, error: .internalError("Remote session service unavailable"))
        }

        let configuration = RemoteConfiguration(
            destination: destination,
            port: port,
            identityFile: identityFile,
            sshOptions: sshOptions,
            localProxyPort: localProxyPort,
            relayPort: relayPort,
            relayID: relayID,
            relayToken: relayToken,
            localSocketPath: localSocketPath,
            terminalStartupCommand: terminalStartupCommand
        )

        service.configureRemoteConnection(
            workspaceID: workspaceID,
            configuration: configuration,
            autoConnect: autoConnect
        )

        return .success(id: req.id, result: .object([
            "workspace_id": .string(workspaceID.uuidString),
            "destination":  .string(destination)
        ]))
    }

    // MARK: - workspace.remote.reconnect

    private func remoteReconnect(_ req: JSONRPCRequest) async throws -> JSONRPCResponse {
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
        guard let service = remoteSessionService else {
            return .failure(id: req.id, error: .internalError("Remote session service unavailable"))
        }
        guard service.isRemoteWorkspace(workspaceID) else {
            throw JSONRPCError(code: -32001, message: "Workspace has no remote session")
        }
        service.reconnectRemoteConnection(workspaceID: workspaceID)
        return .success(id: req.id, result: .object([
            "workspace_id": .string(workspaceID.uuidString),
            "reconnecting": .bool(true)
        ]))
    }

    // MARK: - workspace.remote.disconnect

    private func remoteDisconnect(_ req: JSONRPCRequest) async throws -> JSONRPCResponse {
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
        guard let service = remoteSessionService else {
            return .failure(id: req.id, error: .internalError("Remote session service unavailable"))
        }
        let clear: Bool
        if let clearValue = params["clear"], case .bool(let b) = clearValue {
            clear = b
        } else {
            clear = false
        }
        service.disconnectRemoteConnection(workspaceID: workspaceID, clearConfiguration: clear)
        return .success(id: req.id, result: .object([
            "workspace_id": .string(workspaceID.uuidString),
            "disconnected": .bool(true)
        ]))
    }

    // MARK: - workspace.remote.terminal_session_end

    private func remoteTerminalSessionEnd(_ req: JSONRPCRequest) async throws -> JSONRPCResponse {
        let params = req.params?.object ?? [:]
        guard let wsValue = params["workspace_id"], case .string(let wsStr) = wsValue,
              let workspaceID = UUID(uuidString: wsStr) else {
            throw JSONRPCError(code: -32602, message: "Missing required param: workspace_id")
        }
        // relay_port is optional (CLI may not always have it); accept if present.
        let relayPort: Int?
        if let rpValue = params["relay_port"], case .int(let rp) = rpValue {
            relayPort = rp
        } else {
            relayPort = nil
        }
        // surface_id is optional for CLI-initiated session ends.
        let surfaceID: UUID?
        if let sValue = params["surface_id"], case .string(let sStr) = sValue {
            surfaceID = UUID(uuidString: sStr)
        } else {
            surfaceID = nil
        }
        // TODO: Track active remote terminal sessions in RemoteSessionService
        // For now, acknowledge the session end.
        return .success(id: req.id, result: .object([
            "workspace_id": .string(workspaceID.uuidString),
            "surface_id": surfaceID.map { .string($0.uuidString) } ?? .null,
            "relay_port": relayPort.map { .int($0) } ?? .null,
            "acknowledged": .bool(true)
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
