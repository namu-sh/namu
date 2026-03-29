import Foundation

/// Routes incoming JSON-RPC 2.0 messages to registered handlers.
/// Supports both requests (with `id`) and notifications (without `id`).
/// Optionally wraps handler execution in a middleware chain.
final class CommandDispatcher: @unchecked Sendable {
    private let registry: CommandRegistry
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()
    private let middlewareChain: (@Sendable (JSONRPCRequest, CommandContext) async throws -> JSONRPCResponse)?

    init(registry: CommandRegistry, middlewares: [CommandMiddleware] = []) {
        self.registry = registry

        if middlewares.isEmpty {
            self.middlewareChain = nil
        } else {
            // Build the chain with a terminal handler that dispatches to the registry.
            let reg = registry
            self.middlewareChain = chainMiddleware(middlewares) { req, _ in
                guard let handler = reg.handler(for: req.method) else {
                    throw JSONRPCError.methodNotFound(req.method)
                }
                return try await handler(req)
            }
        }
    }

    // MARK: - Dispatch

    /// Parse raw bytes and dispatch. Returns encoded response data, or nil for notifications.
    func dispatch(data: Data) async -> Data? {
        // Parse the raw JSON
        let request: JSONRPCRequest
        do {
            request = try decoder.decode(JSONRPCRequest.self, from: data)
        } catch {
            // Return parse error only if we can't even read the message.
            // We don't have an id, so respond with null id per spec.
            return encode(JSONRPCResponse.failure(id: nil, error: .parseError))
        }

        // Validate jsonrpc version
        guard request.jsonrpc == "2.0" else {
            return encode(JSONRPCResponse.failure(id: request.id, error: .invalidRequest))
        }

        // Notifications (no id) are fire-and-forget: dispatch but don't respond.
        let isNotification = request.id == nil

        do {
            let response: JSONRPCResponse
            if let chain = middlewareChain {
                // Route through middleware pipeline (logging, rate limit, safety)
                let ctx = CommandContext(
                    clientID: UUID(),
                    accessMode: .allowAll,
                    source: .local
                )
                response = try await chain(request, ctx)
            } else {
                // Direct dispatch (no middleware configured)
                guard let handler = registry.handler(for: request.method) else {
                    if isNotification { return nil }
                    return encode(JSONRPCResponse.failure(id: request.id, error: .methodNotFound(request.method)))
                }
                response = try await handler(request)
            }
            return isNotification ? nil : encode(response)
        } catch let rpcError as JSONRPCError {
            if isNotification { return nil }
            return encode(JSONRPCResponse.failure(id: request.id, error: rpcError))
        } catch {
            if isNotification { return nil }
            return encode(JSONRPCResponse.failure(
                id: request.id,
                error: .internalError(error.localizedDescription)
            ))
        }
    }

    // MARK: - Window ID routing helpers

    /// Extract the window_id string from a request's params object, if present.
    /// Command handlers can use this to route to the correct window context.
    static func windowIDString(from params: [String: JSONRPCValue]?) -> String? {
        guard let params, let v = params["window_id"], case .string(let s) = v else { return nil }
        return s
    }

    // MARK: - Notification Builder

    /// Encode an outbound notification (event push to client).
    func encodeNotification(_ notification: JSONRPCNotification) -> Data? {
        try? encoder.encode(notification)
    }

    // MARK: - Private

    private func encode(_ response: JSONRPCResponse) -> Data? {
        try? encoder.encode(response)
    }
}
