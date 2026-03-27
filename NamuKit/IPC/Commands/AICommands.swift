import Foundation

/// Handlers for the ai.* command namespace.
///
/// Registered commands:
///   ai.message   — send a message; returns the assistant reply
///   ai.status    — current AI engine state (provider, model, ready)
///   ai.history   — retrieve conversation history for the active or named session
@MainActor
final class AICommands {

    // MARK: - Dependencies

    private let workspaceManager: WorkspaceManager
    private let eventBus: EventBus
    private let namuAI: NamuAI
    private let conversationManager: ConversationManager

    // MARK: - Init

    init(workspaceManager: WorkspaceManager, eventBus: EventBus, namuAI: NamuAI, conversationManager: ConversationManager) {
        self.workspaceManager = workspaceManager
        self.eventBus = eventBus
        self.namuAI = namuAI
        self.conversationManager = conversationManager
    }

    // MARK: - Registration

    func register(in registry: CommandRegistry) {
        registry.register("ai.message") { [weak self] req in
            try await self?.message(req) ?? .notAvailable(req)
        }
        registry.register("ai.status") { [weak self] req in
            try await self?.status(req) ?? .notAvailable(req)
        }
        registry.register("ai.history") { [weak self] req in
            try await self?.history(req) ?? .notAvailable(req)
        }
    }

    // MARK: - ai.message
    //
    // Params:
    //   content      (string, required) — the user message text
    //   session_id   (string, optional) — conversation session UUID; passed to NamuAI
    //
    // Returns:
    //   session_id   string
    //   reply        string   — assistant's reply

    private func message(_ req: JSONRPCRequest) async throws -> JSONRPCResponse {
        let params = req.params?.object ?? [:]

        guard let contentValue = params["content"], case .string(let content) = contentValue,
              !content.isEmpty else {
            throw JSONRPCError(code: -32602, message: "Missing required param: content")
        }

        let sessionID = resolvedSessionID(from: params)
        let conversationID = UUID(uuidString: sessionID)

        let reply = await namuAI.send(content, conversationID: conversationID)

        // Publish event so subscribers know a reply was produced
        eventBus.publish(event: .workspaceChange, params: [
            "ai_event":   .string("reply"),
            "session_id": .string(sessionID),
        ])

        return .success(id: req.id, result: .object([
            "session_id": .string(sessionID),
            "reply":      .string(reply),
        ]))
    }

    // MARK: - ai.status
    //
    // Params: none
    //
    // Returns:
    //   ready        bool
    //   provider     string
    //   model        string
    //   session_count int

    private func status(_ req: JSONRPCRequest) async throws -> JSONRPCResponse {
        let prefs = AIPreferencesStore()
        let hasKey = prefs.hasAPIKey(for: prefs.provider)

        return .success(id: req.id, result: .object([
            "ready":         .bool(hasKey),
            "provider":      .string(prefs.provider.rawValue),
            "model":         .string(prefs.selectedModel),
            "safety_level":  .string(prefs.safetyLevel.rawValue),
            "processing":    .bool(namuAI.isProcessing)
        ]))
    }

    // MARK: - ai.history
    //
    // Params:
    //   session_id   (string, optional) — defaults to active workspace session
    //   limit        (int, optional)    — max turns to return, newest-first; default 50
    //   before_id    (string, optional) — cursor: return turns before this message ID
    //
    // Returns:
    //   session_id   string
    //   turns        array
    //   total        int
    //   has_more     bool

    private func history(_ req: JSONRPCRequest) async throws -> JSONRPCResponse {
        let params = req.params?.object ?? [:]
        let sessionID = resolvedSessionID(from: params)

        // Resolve to a UUID; if not a valid UUID, return empty history
        guard let conversationID = UUID(uuidString: sessionID) else {
            return .success(id: req.id, result: .object([
                "session_id": .string(sessionID),
                "turns":      .array([]),
                "total":      .int(0),
                "has_more":   .bool(false)
            ]))
        }

        let conversation = conversationManager.conversation(for: conversationID)

        let limit: Int
        if let lv = params["limit"], case .int(let l) = lv, l > 0 { limit = min(l, 200) }
        else { limit = 50 }

        var messages = conversation.allMessages().filter { $0.role != .system && $0.role != .tool }

        // Cursor: drop messages at or after the one with matching content prefix (no UUID on Message)
        // Use index-based cursor via before_id interpreted as turn index string
        if let cv = params["before_id"], case .string(let cursorStr) = cv,
           let cursorIdx = Int(cursorStr), cursorIdx > 0 {
            messages = Array(messages.prefix(cursorIdx))
        }

        let total = messages.count
        let sliced = Array(messages.suffix(limit))
        let hasMore = total > sliced.count

        let items: [JSONRPCValue] = sliced.enumerated().map { idx, msg in
            .object([
                "id":      .string("\(idx)"),
                "role":    .string(msg.role == .user ? "user" : "assistant"),
                "content": .string(msg.content)
            ])
        }

        return .success(id: req.id, result: .object([
            "session_id": .string(sessionID),
            "turns":      .array(items),
            "total":      .int(total),
            "has_more":   .bool(hasMore)
        ]))
    }

    // MARK: - Session helpers

    private func resolvedSessionID(from params: [String: JSONRPCValue]) -> String {
        if let sv = params["session_id"], case .string(let id) = sv, !id.isEmpty {
            return id
        }
        return workspaceManager.selectedWorkspaceID?.uuidString ?? "default"
    }
}

// MARK: - Helpers

private extension JSONRPCResponse {
    static func notAvailable(_ req: JSONRPCRequest) -> JSONRPCResponse {
        .failure(id: req.id, error: .internalError("AI service unavailable"))
    }
}
