import Foundation

/// Handlers for the system.* command namespace.
/// These are all read-only, stateless commands — no focus mutations.
final class SystemCommands {

    private let appVersion: String

    init(appVersion: String = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0") {
        self.appVersion = appVersion
    }

    // MARK: - Registration

    func register(in registry: CommandRegistry) {
        registry.register("system.ping")         { [weak self] req in self?.ping(req) ?? .notAvailable(req) }
        registry.register("system.version")      { [weak self] req in self?.version(req) ?? .notAvailable(req) }
        registry.register("system.status")       { [weak self] req in self?.status(req) ?? .notAvailable(req) }
        // capabilities uses the registry reference to list all registered methods
        registry.register("system.capabilities") { [weak self, weak registry] req in
            guard let self, let registry else { return .notAvailable(req) }
            return self.capabilities(req, registry: registry)
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
