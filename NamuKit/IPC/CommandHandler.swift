import Foundation

// MARK: - Execution Context

/// Declares where a command handler should execute.
enum ExecutionContext: Sendable {
    /// Read-only queries that don't need main actor isolation.
    case background
    /// State-mutating commands that require main actor.
    case mainActor
}

// MARK: - Safety Level

/// Classification of how sensitive a command is.
/// Used by the middleware pipeline and rate-limiter to gate access.
enum SafetyLevel: Sendable {
    /// Read-only, no side effects.
    case safe
    /// State-mutating but non-destructive.
    case normal
    /// Potentially destructive or high-impact.
    case dangerous
}

// MARK: - Handler Registration

/// Metadata registered alongside each command handler.
/// Enables the middleware pipeline to make routing decisions
/// (e.g. skip main-actor hop for background queries).
struct HandlerRegistration: Sendable {
    let method: String
    let execution: ExecutionContext
    let safety: SafetyLevel
    let handler: @Sendable (JSONRPCRequest) async throws -> JSONRPCResponse
}
