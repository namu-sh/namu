import Foundation

/// Handlers for the system.* command namespace.
/// These are all read-only, stateless commands — no focus mutations.
@MainActor
final class SystemCommands {

    private let appVersion: String
    private let workspaceManager: WorkspaceManager?
    private let panelManager: PanelManager?
    /// Relay server reference (type-erased to avoid build-order dependency).
    private weak var relayServer: AnyObject?

    init(
        appVersion: String = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0",
        workspaceManager: WorkspaceManager? = nil,
        panelManager: PanelManager? = nil,
        relayServer: AnyObject? = nil
    ) {
        self.appVersion = appVersion
        self.workspaceManager = workspaceManager
        self.panelManager = panelManager
        self.relayServer = relayServer
    }

    // MARK: - Registration

    func register(in registry: CommandRegistry) {
        registry.register("system.ping")         { [weak self] req in try await self?.ping(req) ?? .notAvailable(req) }
        registry.register("system.version")      { [weak self] req in try await self?.version(req) ?? .notAvailable(req) }
        registry.register("system.status")       { [weak self] req in try await self?.status(req) ?? .notAvailable(req) }
        registry.register("system.identify")     { [weak self] req in try await self?.identify(req) ?? .notAvailable(req) }
        registry.register("system.render_stats") { [weak self] req in try await self?.renderStats(req) ?? .notAvailable(req) }
        registry.register("system.relay_status") { [weak self] req in try await self?.relayStatus(req) ?? .notAvailable(req) }
        // system.claude_hook is registered in ServiceContainer with full workspace state access
        // capabilities uses the registry reference to list all registered methods
        registry.register("system.capabilities") { [weak self, weak registry] req in
            guard let self, let registry else { return .notAvailable(req) }
            return await self.capabilities(req, registry: registry)
        }

    }

    // MARK: - system.ping

    private func ping(_ req: JSONRPCRequest) -> JSONRPCResponse {
        .success(id: req.id, result: .object(["pong": .bool(true)]))
    }

    // MARK: - system.version

    private func version(_ req: JSONRPCRequest) -> JSONRPCResponse {
        .success(id: req.id, result: .object([
            "version": .string(appVersion),
            "name":    .string("Namu"),
            "platform": .string("macOS")
        ]))
    }

    // MARK: - system.status

    private func status(_ req: JSONRPCRequest) -> JSONRPCResponse {
        .success(id: req.id, result: .object([
            "status":  .string("ok"),
            "version": .string(appVersion),
            "pid":     .int(Int(ProcessInfo.processInfo.processIdentifier))
        ]))
    }

    // MARK: - system.identify

    private func identify(_ req: JSONRPCRequest) async throws -> JSONRPCResponse {
        guard let workspaceManager else {
            throw JSONRPCError.internalError("WorkspaceManager not available")
        }

        guard let workspace = workspaceManager.selectedWorkspace else {
            throw JSONRPCError(code: -32001, message: "No active workspace")
        }

        var focused: [String: JSONRPCValue] = [
            "workspace_id": .string(workspace.id.uuidString)
        ]

        if let activePanelID = panelManager?.focusedPanelID(in: workspace.id) {
            focused["pane_id"] = .string(activePanelID.uuidString)
            focused["surface_id"] = .string(activePanelID.uuidString)
            // pane_ref uses %<id> format for tmux compat
            focused["pane_ref"] = .string("%\(activePanelID.uuidString)")
        }

        return .success(id: req.id, result: .object([
            "focused": .object(focused)
        ]))
    }

    // MARK: - system.render_stats

    /// Return GPU drawable statistics for all active NamuMetalLayer instances.
    /// Each entry includes a layer index, drawable count, and last drawable timestamp.
    private func renderStats(_ req: JSONRPCRequest) -> JSONRPCResponse {
        let layers = NamuMetalLayer.all
        let surfaceStats: [JSONRPCValue] = layers.enumerated().map { index, layer in
            let stats = layer.debugStats()
            return .object([
                "layer_index":    .int(index),
                "drawable_count": .int(stats.count),
                "last_drawable":  .double(stats.lastTime)
            ])
        }
        return .success(id: req.id, result: .object(["surfaces": .array(surfaceStats)]))
    }

    // MARK: - system.relay_status

    private func relayStatus(_ req: JSONRPCRequest) -> JSONRPCResponse {
        // Query relay server status via KVC to avoid compile-time type dependency.
        let isRunning = (relayServer?.value(forKey: "isRunning") as? Bool) ?? false
        let port = (relayServer?.value(forKey: "port") as? Int) ?? 0
        return .success(id: req.id, result: .object([
            "running":       .bool(isRunning),
            "port":          .int(port),
            "available":     .bool(relayServer != nil)
        ]))
    }

    // MARK: - system.capabilities

    private func capabilities(_ req: JSONRPCRequest, registry: CommandRegistry) -> JSONRPCResponse {
        let methods = registry.registeredMethods
        let methodValues: [JSONRPCValue] = methods.map { .string($0) }
        return .success(id: req.id, result: .object([
            "methods": .array(methodValues),
            "version": .string(appVersion)
        ]))
    }
}

// MARK: - Helpers

private extension JSONRPCResponse {
    static func notAvailable(_ req: JSONRPCRequest) -> JSONRPCResponse {
        .failure(id: req.id, error: .internalError("Service unavailable"))
    }
}
