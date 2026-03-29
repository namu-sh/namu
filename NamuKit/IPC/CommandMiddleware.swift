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
/// Separate from CommandSafety.CommandSource to avoid coupling.
enum MiddlewareCommandSource: Sendable {
    case local
    case automation
    case gateway
    case ai
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

// MARK: - Built-in Middleware

/// Logging middleware: records method name and duration.
let loggingMiddleware: CommandMiddleware = { req, ctx, next in
    let start = ContinuousClock.now
    do {
        let response = try await next(req, ctx)
        let elapsed = ContinuousClock.now - start
        print("[IPC] \(req.method) completed in \(elapsed)")
        return response
    } catch {
        let elapsed = ContinuousClock.now - start
        print("[IPC] \(req.method) failed in \(elapsed): \(error)")
        throw error
    }
}

/// Rate limiting middleware: enforces 20 commands/minute for external sources.
final class RateLimiter: @unchecked Sendable {
    private let lock = NSLock()
    private var timestamps: [ContinuousClock.Instant] = []
    private let limit: Int
    private let window: Duration

    init(limit: Int = 20, window: Duration = .seconds(60)) {
        self.limit = limit
        self.window = window
    }

    func tryConsume() -> Bool {
        let now = ContinuousClock.now
        return lock.withLock {
            timestamps.removeAll { now - $0 > window }
            guard timestamps.count < limit else { return false }
            timestamps.append(now)
            return true
        }
    }
}

func makeRateLimitMiddleware(limiter: RateLimiter = RateLimiter()) -> CommandMiddleware {
    return { req, ctx, next in
        switch ctx.source {
        case .gateway, .ai:
            guard limiter.tryConsume() else {
                throw JSONRPCError(code: -32000, message: "Rate limit exceeded")
            }
        case .local, .automation:
            break
        }
        return try await next(req, ctx)
    }
}

/// Safety middleware factory: blocks dangerous commands from non-local sources.
func makeSafetyMiddleware(safety: CommandSafety) -> CommandMiddleware {
    return { req, ctx, next in
        let level = safety.safetyLevel(for: req.method)
        if level == .dangerous && ctx.source != .local {
            throw JSONRPCError(code: -32003, message: "Dangerous command requires local access")
        }
        return try await next(req, ctx)
    }
}