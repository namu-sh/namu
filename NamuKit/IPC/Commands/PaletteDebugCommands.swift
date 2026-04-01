import Foundation
#if canImport(AppKit)
import AppKit
#endif

/// Handlers for the debug.command_palette.* command namespace.
/// Debug introspection for the command palette UI — visibility, selection, results.
@MainActor
final class PaletteDebugCommands {

    init() {}

    // MARK: - Registration

    func register(in registry: CommandRegistry) {
        registry.register(HandlerRegistration(
            method: "debug.command_palette.toggle",
            execution: .mainActor,
            safety: .normal,
            handler: { [weak self] req in try await self?.toggle(req) ?? .notAvailable(req) }
        ))
        registry.register(HandlerRegistration(
            method: "debug.command_palette.visible",
            execution: .mainActor,
            safety: .safe,
            handler: { [weak self] req in try await self?.visible(req) ?? .notAvailable(req) }
        ))
        registry.register(HandlerRegistration(
            method: "debug.command_palette.results",
            execution: .mainActor,
            safety: .safe,
            handler: { [weak self] req in try await self?.results(req) ?? .notAvailable(req) }
        ))
        registry.register(HandlerRegistration(
            method: "debug.command_palette.selection",
            execution: .mainActor,
            safety: .safe,
            handler: { [weak self] req in try await self?.selection(req) ?? .notAvailable(req) }
        ))
    }

    // MARK: - debug.command_palette.toggle

    private func toggle(_ req: JSONRPCRequest) throws -> JSONRPCResponse {
        AppDelegate.shared?.toggleCommandPalette?()
        return .success(id: req.id, result: .object(["toggled": .bool(true)]))
    }

    // MARK: - debug.command_palette.visible

    private func visible(_ req: JSONRPCRequest) throws -> JSONRPCResponse {
        let snapshot = PaletteDebugSnapshot.current
        return .success(id: req.id, result: .object([
            "visible": .bool(snapshot?.isVisible ?? false),
        ]))
    }

    // MARK: - debug.command_palette.results

    private func results(_ req: JSONRPCRequest) throws -> JSONRPCResponse {
        let params = req.params?.object ?? [:]
        let limit: Int
        if let limitValue = params["limit"], case .int(let l) = limitValue {
            limit = max(1, min(l, 100))
        } else {
            limit = 20
        }

        guard let snapshot = PaletteDebugSnapshot.current else {
            return .success(id: req.id, result: .object([
                "visible": .bool(false),
                "query": .string(""),
                "results": .array([]),
            ]))
        }

        let limitedResults = Array(snapshot.results.prefix(limit))
        let resultsJSON: [JSONRPCValue] = limitedResults.map { result in
            .object([
                "title": .string(result.title),
                "score": .int(result.score),
            ])
        }

        return .success(id: req.id, result: .object([
            "visible": .bool(snapshot.isVisible),
            "query": .string(snapshot.query),
            "selected_index": .int(snapshot.selectedIndex),
            "results": .array(resultsJSON),
        ]))
    }

    // MARK: - debug.command_palette.selection

    private func selection(_ req: JSONRPCRequest) throws -> JSONRPCResponse {
        let snapshot = PaletteDebugSnapshot.current
        return .success(id: req.id, result: .object([
            "visible": .bool(snapshot?.isVisible ?? false),
            "selected_index": .int(snapshot?.selectedIndex ?? -1),
        ]))
    }
}

// MARK: - Palette Debug Snapshot

/// Observable snapshot of command palette state for debug introspection.
/// Updated by CommandPaletteView whenever query/selection changes.
struct PaletteDebugSnapshot {
    let isVisible: Bool
    let query: String
    let selectedIndex: Int
    let results: [PaletteResultSnapshot]

    struct PaletteResultSnapshot {
        let title: String
        let score: Int
    }

    /// Current snapshot — set by CommandPaletteView.
    @MainActor static var current: PaletteDebugSnapshot?
}

// MARK: - Helpers

private extension JSONRPCResponse {
    static func notAvailable(_ req: JSONRPCRequest) -> JSONRPCResponse {
        .failure(id: req.id, error: .internalError("Service unavailable"))
    }
}
