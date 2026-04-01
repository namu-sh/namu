import Foundation
#if canImport(AppKit)
import AppKit
#endif

/// Handlers for the window.* command namespace.
/// Multi-window CRUD: list, current, focus, create, close.
@MainActor
final class WindowCommands {

    init() {}

    // MARK: - Registration

    func register(in registry: CommandRegistry) {
        registry.register(HandlerRegistration(
            method: "window.list",
            execution: .mainActor,
            safety: .safe,
            handler: { [weak self] req in try await self?.list(req) ?? .notAvailable(req) }
        ))
        registry.register(HandlerRegistration(
            method: "window.current",
            execution: .mainActor,
            safety: .safe,
            handler: { [weak self] req in try await self?.current(req) ?? .notAvailable(req) }
        ))
        registry.register(HandlerRegistration(
            method: "window.focus",
            execution: .mainActor,
            safety: .normal,
            handler: { [weak self] req in try await self?.focus(req) ?? .notAvailable(req) }
        ))
        registry.register(HandlerRegistration(
            method: "window.create",
            execution: .mainActor,
            safety: .normal,
            handler: { [weak self] req in try await self?.create(req) ?? .notAvailable(req) }
        ))
        registry.register(HandlerRegistration(
            method: "window.close",
            execution: .mainActor,
            safety: .normal,
            handler: { [weak self] req in try await self?.close(req) ?? .notAvailable(req) }
        ))
    }

    // MARK: - window.list

    private func list(_ req: JSONRPCRequest) throws -> JSONRPCResponse {
        guard let delegate = AppDelegate.shared else {
            throw JSONRPCError.internalError("AppDelegate unavailable")
        }

        var windows: [JSONRPCValue] = []
        var index = 0

        // Primary window
        if let wm = delegate.workspaceManager {
            let primaryNSWindow = NSApp.windows.first { $0.identifier?.rawValue == "namu-primary" }
            let isKey = primaryNSWindow?.isKeyWindow ?? false
            let isVisible = primaryNSWindow?.isVisible ?? true
            let frame = primaryNSWindow?.frame

            var entry: [String: JSONRPCValue] = [
                "id": .string("primary"),
                "index": .int(index),
                "is_key": .bool(isKey),
                "is_visible": .bool(isVisible),
                "workspace_count": .int(wm.workspaces.count),
                "selected_workspace_id": .string(wm.selectedWorkspaceID?.uuidString ?? ""),
            ]
            if let frame {
                entry["window_frame"] = .object([
                    "x": .double(frame.origin.x),
                    "y": .double(frame.origin.y),
                    "width": .double(frame.size.width),
                    "height": .double(frame.size.height),
                ])
            }
            windows.append(.object(entry))
            index += 1
        }

        // Secondary windows
        for (windowID, ctx) in delegate.windowContexts {
            let nsWindow = NSApp.windows.first {
                $0.identifier?.rawValue == "namu-secondary-\(windowID.uuidString)"
            }
            let isKey = nsWindow?.isKeyWindow ?? false
            let isVisible = nsWindow?.isVisible ?? true
            let frame = nsWindow?.frame

            var entry: [String: JSONRPCValue] = [
                "id": .string(windowID.uuidString),
                "index": .int(index),
                "is_key": .bool(isKey),
                "is_visible": .bool(isVisible),
                "workspace_count": .int(ctx.workspaceManager.workspaces.count),
                "selected_workspace_id": .string(ctx.workspaceManager.selectedWorkspaceID?.uuidString ?? ""),
                "sidebar_collapsed": .bool(ctx.sidebarCollapsed),
                "sidebar_width": .double(ctx.sidebarWidth),
            ]
            if let frame {
                entry["window_frame"] = .object([
                    "x": .double(frame.origin.x),
                    "y": .double(frame.origin.y),
                    "width": .double(frame.size.width),
                    "height": .double(frame.size.height),
                ])
            }
            windows.append(.object(entry))
            index += 1
        }

        return .success(id: req.id, result: .object([
            "windows": .array(windows),
            "count": .int(windows.count),
        ]))
    }

    // MARK: - window.current

    private func current(_ req: JSONRPCRequest) throws -> JSONRPCResponse {
        guard let delegate = AppDelegate.shared else {
            throw JSONRPCError.internalError("AppDelegate unavailable")
        }

        if let ctx = delegate.keyWindowContext {
            return .success(id: req.id, result: .object([
                "window_id": .string(ctx.windowID.uuidString),
                "workspace_count": .int(ctx.workspaceManager.workspaces.count),
                "selected_workspace_id": .string(ctx.workspaceManager.selectedWorkspaceID?.uuidString ?? ""),
            ]))
        }

        // Fallback to primary
        if let wm = delegate.workspaceManager {
            return .success(id: req.id, result: .object([
                "window_id": .string("primary"),
                "workspace_count": .int(wm.workspaces.count),
                "selected_workspace_id": .string(wm.selectedWorkspaceID?.uuidString ?? ""),
            ]))
        }

        throw JSONRPCError(code: -32001, message: "No active window")
    }

    // MARK: - window.focus

    private func focus(_ req: JSONRPCRequest) throws -> JSONRPCResponse {
        let params = req.params?.object ?? [:]
        guard let idValue = params["window_id"], case .string(let idStr) = idValue else {
            throw JSONRPCError(code: -32602, message: "Missing required param: window_id")
        }

        let nsWindow: NSWindow?
        if idStr == "primary" {
            nsWindow = NSApp.windows.first { $0.identifier?.rawValue == "namu-primary" }
        } else {
            nsWindow = NSApp.windows.first {
                $0.identifier?.rawValue == "namu-secondary-\(idStr)"
            }
        }

        guard let window = nsWindow else {
            throw JSONRPCError(code: -32001, message: "Window not found: \(idStr)")
        }

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        return .success(id: req.id, result: .object([
            "window_id": .string(idStr),
            "focused": .bool(true),
        ]))
    }

    // MARK: - window.create

    private func create(_ req: JSONRPCRequest) throws -> JSONRPCResponse {
        guard let delegate = AppDelegate.shared else {
            throw JSONRPCError.internalError("AppDelegate unavailable")
        }

        let window = delegate.createMainWindow()
        // Extract the UUID from the window identifier (format: "namu-secondary-<UUID>")
        let windowID: String
        if let identifier = window.identifier?.rawValue,
           identifier.hasPrefix("namu-secondary-") {
            windowID = String(identifier.dropFirst("namu-secondary-".count))
        } else {
            windowID = "unknown"
        }

        return .success(id: req.id, result: .object([
            "window_id": .string(windowID),
            "created": .bool(true),
        ]))
    }

    // MARK: - window.close

    private func close(_ req: JSONRPCRequest) throws -> JSONRPCResponse {
        let params = req.params?.object ?? [:]
        guard let idValue = params["window_id"], case .string(let idStr) = idValue else {
            throw JSONRPCError(code: -32602, message: "Missing required param: window_id")
        }

        guard let delegate = AppDelegate.shared else {
            throw JSONRPCError.internalError("AppDelegate unavailable")
        }

        if idStr == "primary" {
            throw JSONRPCError(code: -32001, message: "Cannot close primary window via API")
        }

        guard let windowID = UUID(uuidString: idStr) else {
            throw JSONRPCError(code: -32602, message: "Invalid window_id format")
        }

        let nsWindow = NSApp.windows.first {
            $0.identifier?.rawValue == "namu-secondary-\(idStr)"
        }

        guard let window = nsWindow else {
            throw JSONRPCError(code: -32001, message: "Window not found: \(idStr)")
        }

        delegate.unregisterWindowContext(windowID: windowID)
        window.close()

        return .success(id: req.id, result: .object([
            "window_id": .string(idStr),
            "closed": .bool(true),
        ]))
    }
}

// MARK: - Helpers

private extension JSONRPCResponse {
    static func notAvailable(_ req: JSONRPCRequest) -> JSONRPCResponse {
        .failure(id: req.id, error: .internalError("Service unavailable"))
    }
}
