import Foundation

/// Payload sent to alert channels when a rule fires.
struct AlertPayload: Codable, Sendable {
    let ruleName: String
    let event: String
    let summary: String
    let workspaceTitle: String
    let timestamp: Date

    /// Markdown-formatted message for channels that support it.
    var markdownBody: String {
        """
        **\(ruleName)** — \(summary)
        Event: `\(event)` | Workspace: \(workspaceTitle)
        """
    }

    /// Plain text fallback.
    var plainBody: String {
        "\(ruleName) — \(summary)\nEvent: \(event) | Workspace: \(workspaceTitle)"
    }
}

/// Protocol for platform-specific alert delivery.
/// Each channel is Sendable and async — safe to call from any context.
protocol AlertChannel: Sendable {
    /// Unique identifier: "slack", "telegram", "discord", "webhook"
    var id: String { get }
    /// Human-readable name for settings UI.
    var displayName: String { get }
    /// Deliver an alert payload. Throws on network/auth failure.
    func send(_ payload: AlertPayload) async throws
}

/// Errors that channel adapters can throw.
enum AlertChannelError: Error, LocalizedError {
    case notConfigured(String)
    case sendFailed(String, underlyingError: Error?)
    case rateLimited
    case invalidResponse(Int)

    var errorDescription: String? {
        switch self {
        case .notConfigured(let channel): return "\(channel) is not configured"
        case .sendFailed(let channel, let err): return "\(channel) send failed: \(err?.localizedDescription ?? "unknown")"
        case .rateLimited: return "Rate limited"
        case .invalidResponse(let code): return "HTTP \(code)"
        }
    }
}
