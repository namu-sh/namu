import Foundation

// MARK: - Command Context

/// Context accumulated through the middleware pipeline.
struct CommandContext: Sendable {
    let clientID: UUID
    let accessMode: AccessMode
    var source: MiddlewareCommandSource
    var startTime: ContinuousClock.Instant
    var metadata: [String: String]

    init(
        clientID: UUID,
        accessMode: AccessMode,
        source: MiddlewareCommandSource = .local,
        startTime: ContinuousClock.Instant = .now,
        metadata: [String: String] = [:]
    ) {
        self.clientID = clientID
        self.accessMode = accessMode
        self.source = source
        self.startTime = startTime
        self.metadata = metadata
    }
}

// MARK: - Command Source (Middleware)

/// Source classification for middleware pipeline decisions.
enum MiddlewareCommandSource: Sendable {
    case local
}

// MARK: - Middleware Type

/// A middleware transforms a request/context, optionally short-circuiting.
typealias CommandMiddleware = @Sendable (
    JSONRPCRequest,
    CommandContext,
    _ next: @Sendable (JSONRPCRequest, CommandContext) async throws -> JSONRPCResponse
) async throws -> JSONRPCResponse

// MARK: - Middleware Chain

/// Chains an array of middleware into a single function.
/// Middleware executes in array order; the final handler is called last.
func chainMiddleware(
    _ middlewares: [CommandMiddleware],
    handler: @escaping @Sendable (JSONRPCRequest, CommandContext) async throws -> JSONRPCResponse
) -> @Sendable (JSONRPCRequest, CommandContext) async throws -> JSONRPCResponse {
    var chain = handler
    for middleware in middlewares.reversed() {
        let next = chain
        chain = { req, ctx in try await middleware(req, ctx, next) }
    }
    return chain
}


