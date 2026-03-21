import Foundation

// MARK: - Message

struct Message: Sendable {
    enum Role: String, Sendable {
        case system
        case user
        case assistant
        case tool
    }

    let role: Role
    let content: String
    /// Only set when role == .tool; matches the ToolUse.id that triggered this result.
    let toolUseID: String?

    init(role: Role, content: String, toolUseID: String? = nil) {
        self.role = role
        self.content = content
        self.toolUseID = toolUseID
    }
}

// MARK: - Tool

struct Tool: @unchecked Sendable {
    let name: String
    let description: String
    /// JSON Schema object describing the tool's input parameters.
    let inputSchema: [String: Any]
}

// MARK: - ToolUse

struct ToolUse: @unchecked Sendable {
    let id: String
    let name: String
    /// Decoded tool input arguments.
    let input: [String: Any]
}

// MARK: - Response

struct LLMResponse: Sendable {
    /// Text content returned by the model (may be empty when tool_use blocks are present).
    let content: String
    /// Tool invocations requested by the model.
    let toolUses: [ToolUse]
}

// MARK: - Errors

enum LLMError: Error, Sendable {
    case authenticationFailed
    case rateLimitExceeded
    case timeout
    case invalidResponse(String)
    case httpError(statusCode: Int, body: String)
}

// MARK: - Protocol

protocol LLMProvider: Sendable {
    /// Send a conversation turn and receive a completion.
    func complete(messages: [Message], tools: [Tool]) async throws -> LLMResponse
}
