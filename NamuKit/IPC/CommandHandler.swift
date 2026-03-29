import Foundation

// MARK: - Execution Context

/// Declares where a command handler should execute.
enum ExecutionContext: Sendable {
    /// Read-only queries that don't need main actor isolation.
    case background
    /// State-mutating commands that require main actor.
    case mainActor
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
