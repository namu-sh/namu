import Foundation
import Combine

// MARK: - AIMessage

struct AIMessage: Sendable {
    enum Role: Sendable { case user, assistant }
    let role: Role
    let content: String
    let timestamp: Date

    init(role: Role, content: String) {
        self.role = role
        self.content = content
        self.timestamp = Date()
    }
}

// MARK: - AIError

enum AIError: Error, Sendable {
    case providerUnavailable(String)
    case malformedToolUse(String)
    case commandFailed(method: String, error: String)
    case safetyBlocked(reason: String)
    case safetyRequiresConfirmation(command: String, reason: String)
    case noProvider
}

// MARK: - NamuAI

/// Core AI engine. Routes natural-language user messages through:
///   context → LLM → tool_use → CommandSafety → CommandRegistry → result
@MainActor
final class NamuAI: ObservableObject {

    // MARK: - Published state

    @Published private(set) var isProcessing = false
    @Published private(set) var lastError: String?

    // MARK: - Dependencies

    private var provider: (any LLMProvider)?
    var hasProvider: Bool { provider != nil }
    private let commandRegistry: CommandRegistry
    private let commandSafety: CommandSafety
    private let conversationManager: ConversationManager
    private let contextCollector: ContextCollector
    private let commandSource: CommandSource

    // MARK: - Init

    init(
        provider: (any LLMProvider)? = nil,
        commandRegistry: CommandRegistry,
        commandSafety: CommandSafety,
        conversationManager: ConversationManager,
        contextCollector: ContextCollector,
        commandSource: CommandSource = .local
    ) {
        self.provider = provider
        self.commandRegistry = commandRegistry
        self.commandSafety = commandSafety
        self.conversationManager = conversationManager
        self.contextCollector = contextCollector
        self.commandSource = commandSource
    }

    func setProvider(_ provider: any LLMProvider) {
        self.provider = provider
    }

    // MARK: - Main entry point

    /// Process a natural-language message and return the assistant's reply.
    /// - Parameters:
    ///   - text: User's natural-language input.
    ///   - conversationID: ID of the ongoing conversation (creates one if nil).
    /// - Returns: Assistant reply string.
    @discardableResult
    func send(_ text: String, conversationID: UUID? = nil) async -> String {
        guard let provider else {
            let msg = "AI is not configured. Please add an API key in AI Preferences."
            lastError = msg
            return msg
        }

        isProcessing = true
        lastError = nil
        defer { isProcessing = false }

        let convID = conversationID ?? conversationManager.createConversation()
        let conversation = conversationManager.conversation(for: convID)

        // Append the user turn.
        let userMessage = Message(role: .user, content: text)
        conversation.append(userMessage)

        // Build the full message list with system prompt.
        let snapshot = contextCollector.snapshot
        let systemMessage = Message(role: .system, content: CommandMapper.systemPrompt(context: snapshot))

        var llmMessages: [Message] = [systemMessage] + conversation.allMessages()

        // Agentic loop: keep calling LLM until it stops emitting tool_use.
        var finalReply = ""
        var iterations = 0
        let maxIterations = 10

        while iterations < maxIterations {
            iterations += 1

            let response: LLMResponse
            do {
                response = try await provider.complete(messages: llmMessages, tools: CommandMapper.allTools)
            } catch {
                // If we already executed tool calls successfully, the follow-up LLM call
                // failure is non-fatal — the commands ran, we just can't get a summary.
                if !finalReply.isEmpty || iterations > 1 {
                    return finalReply.isEmpty ? "Done." : finalReply
                }
                let msg = (error is LLMError)
                    ? userFacingError(for: error as! LLMError)
                    : "AI temporarily unavailable. Please try again later."
                lastError = msg
                return msg
            }

            // Accumulate any text content.
            if !response.content.isEmpty {
                finalReply = response.content
            }

            // If no tool calls, we're done.
            if response.toolUses.isEmpty {
                break
            }

            // Append the assistant turn (with tool_use blocks) to history.
            let assistantTurn = Message(role: .assistant, content: response.content)
            conversation.append(assistantTurn)
            llmMessages.append(assistantTurn)

            // Execute each tool call sequentially.
            for toolUse in response.toolUses {
                let toolResultContent = await executeToolUse(toolUse)

                // Feed the tool result back into the conversation.
                let toolResultMessage = Message(
                    role: .tool,
                    content: toolResultContent,
                    toolUseID: toolUse.id
                )
                conversation.append(toolResultMessage)
                llmMessages.append(toolResultMessage)
            }
        }

        // Append the final assistant reply to history.
        if !finalReply.isEmpty {
            conversation.append(Message(role: .assistant, content: finalReply))
        }

        return finalReply.isEmpty ? "Done." : finalReply
    }

    // MARK: - Tool execution

    private func executeToolUse(_ toolUse: ToolUse) async -> String {
        guard let method = CommandMapper.rpcMethod(for: toolUse.name) else {
            let msg = "Unknown tool '\(toolUse.name)'. Skipping."
            print("[NamuAI] \(msg)")
            return msg
        }

        // Safety check — use the RPC method's local part (after the dot) to match CommandSafety classification.
        let safetyCommandName = method.components(separatedBy: ".").last ?? toolUse.name
        let keyPayload = (toolUse.input["keys"] as? String) ?? (toolUse.input["text"] as? String)
        let safetyResult = commandSafety.validate(
            command: safetyCommandName,
            payload: keyPayload,
            source: commandSource
        )

        switch safetyResult {
        case .rejected(let reason):
            return "Command blocked: \(reason)"

        case .requiresConfirmation(let reason):
            // For local source this returns a message; external confirmation is handled by the gateway.
            return "Command requires confirmation: \(reason). Please confirm before proceeding."

        case .allowed:
            break
        }

        // Build JSON-RPC request and dispatch.
        let params = CommandMapper.params(from: toolUse.input)
        let request = JSONRPCRequest(id: .string(toolUse.id), method: method, params: params)

        guard let handler = commandRegistry.handler(for: method) else {
            let msg = "No handler registered for '\(method)'."
            print("[NamuAI] \(msg)")
            return msg
        }

        do {
            let response = try await handler(request)
            if let error = response.error {
                let msg = "Command '\(method)' failed: \(error.message)"
                print("[NamuAI] \(msg)")
                return msg
            }
            if let result = response.result {
                return formatResult(result)
            }
            return "OK"
        } catch {
            let msg = "Command '\(method)' threw an error: \(error.localizedDescription)"
            print("[NamuAI] \(msg)")
            return msg
        }
    }

    // MARK: - Helpers

    private func userFacingError(for error: LLMError) -> String {
        switch error {
        case .authenticationFailed:
            return "AI authentication failed. Please check your API key in AI Preferences."
        case .rateLimitExceeded:
            return "AI rate limit reached. Please wait a moment before sending another message."
        case .timeout:
            return "AI request timed out. Please try again."
        case .invalidResponse(let detail):
            print("[NamuAI] Invalid LLM response: \(detail)")
            return "I couldn't understand how to do that. Try rephrasing."
        case .httpError(let code, let body):
            print("[NamuAI] HTTP \(code): \(body)")
            return "AI temporarily unavailable (HTTP \(code)). Please try again later."
        }
    }

    private func formatResult(_ value: JSONRPCValue) -> String {
        switch value {
        case .null:          return "null"
        case .bool(let b):   return b ? "true" : "false"
        case .int(let i):    return "\(i)"
        case .double(let d): return "\(d)"
        case .string(let s): return s
        case .array(let arr):
            return arr.map { formatResult($0) }.joined(separator: ", ")
        case .object(let obj):
            return obj.map { "\($0.key): \(formatResult($0.value))" }.joined(separator: "; ")
        }
    }
}
