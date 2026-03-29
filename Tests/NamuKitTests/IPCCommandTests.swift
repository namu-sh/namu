import XCTest
@testable import Namu

/// Unit tests for WorkspaceCommands and SystemCommands IPC handlers.
///
/// PanelManager requires AppKit surface views and a live Ghostty C runtime,
/// so pane.list and other PanelManager-dependent commands are tested as stubs.
/// WorkspaceManager and WorkspaceCommands are pure Swift and fully testable.
@MainActor
final class IPCCommandTests: XCTestCase {

    // MARK: - Helpers

    private func makeWorkspaceManager() -> WorkspaceManager {
        WorkspaceManager()
    }

    private func makeWorkspaceCommands(manager: WorkspaceManager) -> WorkspaceCommands {
        WorkspaceCommands(workspaceManager: manager)
    }

    private func makeRegistry(manager: WorkspaceManager) -> (WorkspaceCommands, CommandRegistry) {
        let commands = makeWorkspaceCommands(manager: manager)
        let registry = CommandRegistry()
        commands.register(in: registry)
        return (commands, registry)
    }

    private func dispatch(_ registry: CommandRegistry, method: String, params: [String: JSONRPCValue] = [:]) async throws -> JSONRPCResponse {
        let req = JSONRPCRequest(id: .string("test"), method: method, params: params.isEmpty ? nil : .object(params))
        guard let handler = registry.handler(for: method) else {
            throw JSONRPCError.methodNotFound(method)
        }
        return try await handler(req)
    }

    private func successResult(_ response: JSONRPCResponse) throws -> [String: JSONRPCValue] {
        XCTAssertNil(response.error, "Expected success but got error: \(response.error?.message ?? "")")
        guard let result = response.result, case .object(let obj) = result else {
            XCTFail("Expected object result")
            return [:]
        }
        return obj
    }

    // MARK: - workspace.current

    func testWorkspaceCurrentReturnsSelected() async throws {
        let manager = makeWorkspaceManager()
        let (commands, registry) = makeRegistry(manager: manager)
        defer { _ = commands }
        let response = try await dispatch(registry, method: "workspace.current")
        let obj = try successResult(response)
        XCTAssertNotNil(obj["workspace_id"], "workspace_id should be present")
        XCTAssertNotNil(obj["title"], "title should be present")
        if case .string(let idStr) = obj["workspace_id"] {
            XCTAssertEqual(idStr, manager.selectedWorkspaceID?.uuidString)
        } else {
            XCTFail("workspace_id should be a string")
        }
    }

    // MARK: - workspace.next wraps around

    func testWorkspaceNextWrapsAround() async throws {
        let manager = makeWorkspaceManager()
        let ws2 = manager.createWorkspace(title: "B")
        let ws3 = manager.createWorkspace(title: "C")
        // Select the last workspace
        manager.selectWorkspace(id: ws3.id)
        let (commands, registry) = makeRegistry(manager: manager)
        defer { _ = commands }
        let response = try await dispatch(registry, method: "workspace.next")
        let obj = try successResult(response)
        // Next after last should wrap to first
        if case .string(let idStr) = obj["workspace_id"] {
            XCTAssertEqual(idStr, manager.workspaces.first?.id.uuidString, "next after last should wrap to first")
        } else {
            XCTFail("workspace_id should be a string")
        }
        _ = ws2 // suppress unused warning
    }

    // MARK: - workspace.previous wraps around

    func testWorkspacePreviousWrapsAround() async throws {
        let manager = makeWorkspaceManager()
        let ws2 = manager.createWorkspace(title: "B")
        let ws3 = manager.createWorkspace(title: "C")
        // Select the first workspace
        manager.selectWorkspace(id: manager.workspaces.first!.id)
        let (commands, registry) = makeRegistry(manager: manager)
        defer { _ = commands }
        let response = try await dispatch(registry, method: "workspace.previous")
        let obj = try successResult(response)
        // Previous before first should wrap to last
        if case .string(let idStr) = obj["workspace_id"] {
            XCTAssertEqual(idStr, ws3.id.uuidString, "previous before first should wrap to last")
        } else {
            XCTFail("workspace_id should be a string")
        }
        _ = ws2 // suppress unused warning
    }

    // MARK: - workspace.last tracking

    func testWorkspaceLastTracking() async throws {
        let manager = makeWorkspaceManager()
        let wsA = manager.workspaces.first!
        let wsB = manager.createWorkspace(title: "B")
        let (commands, registry) = makeRegistry(manager: manager)
        defer { _ = commands }

        // Select A (already selected), then select B via workspace.select
        let selectResponse = try await dispatch(registry, method: "workspace.select",
                                                 params: ["id": .string(wsB.id.uuidString)])
        XCTAssertNil(selectResponse.error)
        // Now selectedWorkspaceID is B; previous should be A
        let lastResponse = try await dispatch(registry, method: "workspace.last")
        let obj = try successResult(lastResponse)
        if case .string(let idStr) = obj["workspace_id"] {
            XCTAssertEqual(idStr, wsA.id.uuidString, "workspace.last should return workspace A")
        } else {
            XCTFail("workspace_id should be a string")
        }
    }

    // MARK: - workspace.list

    func testWorkspaceListReturnsAllWorkspaces() async throws {
        let manager = makeWorkspaceManager()
        manager.createWorkspace(title: "B")
        manager.createWorkspace(title: "C")
        let (commands, registry) = makeRegistry(manager: manager)
        defer { _ = commands }
        let response = try await dispatch(registry, method: "workspace.list")
        let obj = try successResult(response)
        guard case .array(let items) = obj["workspaces"] else {
            return XCTFail("Expected workspaces array")
        }
        XCTAssertEqual(items.count, 3)
    }

    // MARK: - workspace.create

    func testWorkspaceCreateReturnsNewWorkspace() async throws {
        let manager = makeWorkspaceManager()
        let (commands, registry) = makeRegistry(manager: manager)
        defer { _ = commands }
        let response = try await dispatch(registry, method: "workspace.create",
                                           params: ["title": .string("My Workspace")])
        let obj = try successResult(response)
        XCTAssertNotNil(obj["id"])
        if case .string(let title) = obj["title"] {
            XCTAssertEqual(title, "My Workspace")
        } else {
            XCTFail("title should be a string")
        }
        XCTAssertEqual(manager.workspaces.count, 2)
    }

    // MARK: - workspace.delete

    func testWorkspaceDeleteRemovesWorkspace() async throws {
        let manager = makeWorkspaceManager()
        let ws2 = manager.createWorkspace(title: "To Delete")
        let (commands, registry) = makeRegistry(manager: manager)
        defer { _ = commands }
        let response = try await dispatch(registry, method: "workspace.delete",
                                           params: ["id": .string(ws2.id.uuidString)])
        XCTAssertNil(response.error)
        XCTAssertEqual(manager.workspaces.count, 1)
    }

    func testWorkspaceDeleteLastWorkspaceFails() async throws {
        let manager = makeWorkspaceManager()
        let (commands, registry) = makeRegistry(manager: manager)
        defer { _ = commands }
        let wsID = manager.workspaces.first!.id.uuidString
        do {
            let response = try await dispatch(registry, method: "workspace.delete",
                                               params: ["id": .string(wsID)])
            XCTAssertNotNil(response.error, "Should fail when deleting last workspace")
        } catch {
            // Acceptable — threw instead of returning error response
        }
    }

    // MARK: - system.identify

    func testSystemIdentifyReturnsFocusedWorkspaceID() async throws {
        let manager = makeWorkspaceManager()
        let registry = CommandRegistry()
        let systemCommands = SystemCommands(appVersion: "1.0.0", workspaceManager: manager, panelManager: nil)
        systemCommands.register(in: registry)

        let req = JSONRPCRequest(id: .string("test"), method: "system.identify")
        guard let handler = registry.handler(for: "system.identify") else {
            return XCTFail("system.identify not registered")
        }
        let response = try await handler(req)
        XCTAssertNil(response.error)
        guard let result = response.result, case .object(let obj) = result,
              case .object(let focused) = obj["focused"] else {
            return XCTFail("Expected focused object in response")
        }
        if case .string(let wsID) = focused["workspace_id"] {
            XCTAssertEqual(wsID, manager.selectedWorkspaceID?.uuidString)
        } else {
            XCTFail("workspace_id should be present in focused")
        }
    }

    // MARK: - pane.list (stubs — requires PanelManager with AppKit surface views)

    // TODO: requires mock managers
    // func testPaneListReturnsAllPanes() async throws { ... }
    // pane.list calls panelManager.panel(for:) which requires live AppKit surfaces.
    // To test this, create a MockPanelManager conforming to a PanelManaging protocol.
}
