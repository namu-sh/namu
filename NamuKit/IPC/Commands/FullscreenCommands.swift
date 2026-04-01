import Foundation
#if canImport(AppKit)
import AppKit
#endif

/// Handlers for the fullscreen.* command namespace.
/// Programmatic fullscreen control for windows.
@MainActor
final class FullscreenCommands {

    init() {}

    // MARK: - Registration

    func register(in registry: CommandRegistry) {
        registry.register(HandlerRegistration(
            method: "fullscreen.toggle",
            execution: .mainActor,
            safety: .normal,
            handler: { [weak self] req in try await self?.toggle(req) ?? .notAvailable(req) }
        ))
        registry.register(HandlerRegistration(
            method: "fullscreen.status",
            execution: .mainActor,
            safety: .safe,
            handler: { [weak self] req in try await self?.status(req) ?? .notAvailable(req) }
        ))
    }

    // MARK: - fullscreen.toggle

    private func toggle(_ req: JSONRPCRequest) throws -> JSONRPCResponse {
        let params = req.params?.object ?? [:]
        let window = try resolveWindow(params)
        window.toggleFullScreen(nil)

        return .success(id: req.id, result: .object([
            "window_id": windowIdValue(window),
            "toggled": .bool(true),
        ]))
    }

    // MARK: - fullscreen.status

    private func status(_ req: JSONRPCRequest) throws -> JSONRPCResponse {
        let params = req.params?.object ?? [:]
        let window = try resolveWindow(params)
        let isFullScreen = window.styleMask.contains(.fullScreen)

        return .success(id: req.id, result: .object([
            "window_id": windowIdValue(window),
            "is_fullscreen": .bool(isFullScreen),
        ]))
    }

    // MARK: - Private Helpers

    private func resolveWindow(_ params: [String: JSONRPCValue]) throws -> NSWindow {
        if let idValue = params["window_id"], case .string(let idStr) = idValue {
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
            return window
        }

        // Default to key window
        guard let window = NSApp.keyWindow ?? NSApp.mainWindow else {
            throw JSONRPCError(code: -32001, message: "No active window")
        }
        return window
    }

    private func windowIdValue(_ window: NSWindow) -> JSONRPCValue {
        if let id = window.identifier?.rawValue {
            if id == "namu-primary" {
                return .string("primary")
            } else if id.hasPrefix("namu-secondary-") {
                return .string(String(id.dropFirst("namu-secondary-".count)))
            }
        }
        return .string("unknown")
    }
}

// MARK: - Helpers

private extension JSONRPCResponse {
    static func notAvailable(_ req: JSONRPCRequest) -> JSONRPCResponse {
        .failure(id: req.id, error: .internalError("Service unavailable"))
    }
}
