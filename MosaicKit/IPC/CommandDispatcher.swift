import Foundation

/// Routes incoming JSON-RPC 2.0 messages to registered handlers.
/// Supports both requests (with `id`) and notifications (without `id`).
final class CommandDispatcher: @unchecked Sendable {
    private let registry: CommandRegistry
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

    init(registry: CommandRegistry) {
        self.registry = registry
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

        guard let handler = registry.handler(for: request.method) else {
            if isNotification { return nil }
            return encode(JSONRPCResponse.failure(id: request.id, error: .methodNotFound(request.method)))
        }

        do {
            let response = try await handler(request)
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
