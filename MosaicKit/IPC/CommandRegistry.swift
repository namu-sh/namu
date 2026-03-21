import Foundation

/// Registry for JSON-RPC command handlers, keyed by "namespace.method".
final class CommandRegistry: @unchecked Sendable {
    typealias Handler = (JSONRPCRequest) async throws -> JSONRPCResponse

    private let lock = NSLock()
    private var handlers: [String: Handler] = [:]

    // MARK: - Registration

    /// Register a handler for the given method name (e.g. "workspace.list").
    func register(_ method: String, handler: @escaping Handler) {
        lock.withLock {
            handlers[method] = handler
        }
    }

    /// Unregister a handler.
    func unregister(_ method: String) {
        lock.withLock {
            handlers.removeValue(forKey: method)
        }
    }

    // MARK: - Lookup

    func handler(for method: String) -> Handler? {
        lock.withLock { handlers[method] }
    }

    /// All registered method names — used for capabilities reporting.
    var registeredMethods: [String] {
        lock.withLock { Array(handlers.keys).sorted() }
    }
}

private extension NSLock {
    @discardableResult
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
