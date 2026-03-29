import Foundation

/// Registry for JSON-RPC command handlers, keyed by "namespace.method".
final class CommandRegistry: @unchecked Sendable {
    typealias Handler = (JSONRPCRequest) async throws -> JSONRPCResponse

    private let lock = NSLock()
    private var handlers: [String: Handler] = [:]
    private var registrations: [String: HandlerRegistration] = [:]

    // MARK: - Registration

    /// Register a handler for the given method name (e.g. "workspace.list").
    func register(_ method: String, handler: @escaping Handler) {
        lock.withLock {
            handlers[method] = handler
        }
    }

    /// Register a handler using metadata-aware registration.
    /// Stores the handler and its metadata for middleware pipeline decisions.
    func register(_ registration: HandlerRegistration) {
        lock.withLock {
            handlers[registration.method] = registration.handler
            registrations[registration.method] = registration
        }
    }

    // MARK: - Lookup

    func handler(for method: String) -> Handler? {
        lock.withLock { handlers[method] }
    }

    /// Retrieve the full registration metadata for a method.
    func registration(for method: String) -> HandlerRegistration? {
        lock.withLock { registrations[method] }
    }

    /// All registered method names — used for capabilities reporting.
    var registeredMethods: [String] {
        lock.withLock { Array(handlers.keys).sorted() }
    }
}