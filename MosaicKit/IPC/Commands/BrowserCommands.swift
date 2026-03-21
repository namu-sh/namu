import Foundation

/// Stubs for the browser.* command namespace (7 commands).
/// Full implementation deferred to Phase 3 browser panel work.
/// Focus policy: no browser command steals focus.
@MainActor
final class BrowserCommands {

    private let workspaceManager: WorkspaceManager

    init(workspaceManager: WorkspaceManager) {
        self.workspaceManager = workspaceManager
    }

    // MARK: - Registration

    func register(in registry: CommandRegistry) {
        registry.register("browser.navigate")   { [weak self] req in try await self?.navigate(req) ?? .notAvailable(req) }
        registry.register("browser.back")        { [weak self] req in try await self?.back(req) ?? .notAvailable(req) }
        registry.register("browser.forward")     { [weak self] req in try await self?.forward(req) ?? .notAvailable(req) }
        registry.register("browser.reload")      { [weak self] req in try await self?.reload(req) ?? .notAvailable(req) }
        registry.register("browser.get_url")     { [weak self] req in try await self?.getURL(req) ?? .notAvailable(req) }
        registry.register("browser.get_title")   { [weak self] req in try await self?.getTitle(req) ?? .notAvailable(req) }
        registry.register("browser.execute_js")  { [weak self] req in try await self?.executeJS(req) ?? .notAvailable(req) }
    }

    // MARK: - browser.navigate

    private func navigate(_ req: JSONRPCRequest) async throws -> JSONRPCResponse {
        let params = req.params?.object ?? [:]
        guard let urlValue = params["url"], case .string(let urlStr) = urlValue, !urlStr.isEmpty else {
            throw JSONRPCError(code: -32602, message: "Missing required param: url")
        }
        let panelID = try resolveBrowserPanel(params: params)
        // TODO: call BrowserPanel.navigate(url:) when browser panel is implemented
        return .success(id: req.id, result: .object([
            "surface_id": .string(panelID.uuidString),
            "url":        .string(urlStr)
        ]))
    }

    // MARK: - browser.back

    private func back(_ req: JSONRPCRequest) async throws -> JSONRPCResponse {
        let panelID = try resolveBrowserPanel(params: req.params?.object ?? [:])
        // TODO: call BrowserPanel.goBack() when browser panel is implemented
        return .success(id: req.id, result: .object([
            "surface_id": .string(panelID.uuidString)
        ]))
    }

    // MARK: - browser.forward

    private func forward(_ req: JSONRPCRequest) async throws -> JSONRPCResponse {
        let panelID = try resolveBrowserPanel(params: req.params?.object ?? [:])
        // TODO: call BrowserPanel.goForward() when browser panel is implemented
        return .success(id: req.id, result: .object([
            "surface_id": .string(panelID.uuidString)
        ]))
    }

    // MARK: - browser.reload

    private func reload(_ req: JSONRPCRequest) async throws -> JSONRPCResponse {
        let panelID = try resolveBrowserPanel(params: req.params?.object ?? [:])
        // TODO: call BrowserPanel.reload() when browser panel is implemented
        return .success(id: req.id, result: .object([
            "surface_id": .string(panelID.uuidString)
        ]))
    }

    // MARK: - browser.get_url

    private func getURL(_ req: JSONRPCRequest) async throws -> JSONRPCResponse {
        let panelID = try resolveBrowserPanel(params: req.params?.object ?? [:])
        // TODO: return BrowserPanel.currentURL when browser panel is implemented
        return .success(id: req.id, result: .object([
            "surface_id": .string(panelID.uuidString),
            "url":        .null
        ]))
    }

    // MARK: - browser.get_title

    private func getTitle(_ req: JSONRPCRequest) async throws -> JSONRPCResponse {
        let panelID = try resolveBrowserPanel(params: req.params?.object ?? [:])
        // TODO: return BrowserPanel.title when browser panel is implemented
        return .success(id: req.id, result: .object([
            "surface_id": .string(panelID.uuidString),
            "title":      .null
        ]))
    }

    // MARK: - browser.execute_js

    private func executeJS(_ req: JSONRPCRequest) async throws -> JSONRPCResponse {
        let params = req.params?.object ?? [:]
        guard let scriptValue = params["script"], case .string(let script) = scriptValue else {
            throw JSONRPCError(code: -32602, message: "Missing required param: script")
        }
        let panelID = try resolveBrowserPanel(params: params)
        // TODO: call BrowserPanel.evaluateJavaScript(_:) when browser panel is implemented
        _ = script
        return .success(id: req.id, result: .object([
            "surface_id": .string(panelID.uuidString),
            "result":     .null
        ]))
    }

    // MARK: - Private helpers

    /// Resolve a browser panel from the params or raise an error.
    /// Accepts surface_id param, or falls back to the focused panel.
    /// Validates that the panel type is .browser.
    private func resolveBrowserPanel(params: [String: JSONRPCValue]) throws -> UUID {
        if let sidValue = params["surface_id"], case .string(let sidStr) = sidValue,
           let sid = UUID(uuidString: sidStr) {
            for ws in workspaceManager.workspaces {
                if let leaf = ws.paneTree.findPane(id: sid) {
                    guard leaf.panelType == .browser else {
                        throw JSONRPCError(code: -32001, message: "Surface is not a browser pane")
                    }
                    return sid
                }
            }
            throw JSONRPCError(code: -32001, message: "Surface not found")
        }

        guard let workspace = workspaceManager.selectedWorkspace,
              let focusedID = workspace.focusedPanelID,
              let leaf = workspace.paneTree.findPane(id: focusedID) else {
            throw JSONRPCError(code: -32001, message: "No focused browser surface")
        }
        guard leaf.panelType == .browser else {
            throw JSONRPCError(code: -32001, message: "Focused surface is not a browser pane")
        }
        return focusedID
    }
}

// MARK: - Helpers

private extension JSONRPCResponse {
    static func notAvailable(_ req: JSONRPCRequest) -> JSONRPCResponse {
        .failure(id: req.id, error: .internalError("Service unavailable"))
    }
}
