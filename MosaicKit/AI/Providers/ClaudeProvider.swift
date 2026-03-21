import Foundation

// MARK: - ClaudeProvider

final class ClaudeProvider: LLMProvider {
    private let apiKey: String
    private let model: String
    private let session: URLSession
    private static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    private static let anthropicVersion = "2023-06-01"

    init(apiKey: String, model: String = "claude-opus-4-6", session: URLSession = .shared) {
        self.apiKey = apiKey
        self.model = model
        self.session = session
    }

    // MARK: - LLMProvider

    func complete(messages: [Message], tools: [Tool]) async throws -> LLMResponse {
        let requestBody = buildRequest(messages: messages, tools: tools)
        let data = try JSONSerialization.data(withJSONObject: requestBody)

        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.httpBody = data
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue(Self.anthropicVersion, forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.timeoutInterval = 120

        let (responseData, httpResponse): (Data, URLResponse)
        do {
            (responseData, httpResponse) = try await session.data(for: request)
        } catch let urlError as URLError where urlError.code == .timedOut {
            throw LLMError.timeout
        }

        guard let http = httpResponse as? HTTPURLResponse else {
            throw LLMError.invalidResponse("Non-HTTP response")
        }

        switch http.statusCode {
        case 200:
            return try parseResponse(responseData)
        case 401:
            throw LLMError.authenticationFailed
        case 429:
            throw LLMError.rateLimitExceeded
        default:
            let body = String(data: responseData, encoding: .utf8) ?? ""
            throw LLMError.httpError(statusCode: http.statusCode, body: body)
        }
    }

    // MARK: - Request Building

    private func buildRequest(messages: [Message], tools: [Tool]) -> [String: Any] {
        var body: [String: Any] = [
            "model": model,
            "max_tokens": 4096,
            "messages": messages.compactMap { mapMessage($0) },
        ]

        // System message is top-level in Anthropic API
        if let systemMsg = messages.first(where: { $0.role == .system }) {
            body["system"] = systemMsg.content
        }

        if !tools.isEmpty {
            body["tools"] = tools.map { mapTool($0) }
        }

        return body
    }

    private func mapMessage(_ message: Message) -> [String: Any]? {
        switch message.role {
        case .system:
            // System handled separately at top level
            return nil
        case .user:
            return ["role": "user", "content": message.content]
        case .assistant:
            return ["role": "assistant", "content": message.content]
        case .tool:
            guard let toolUseID = message.toolUseID else { return nil }
            return [
                "role": "user",
                "content": [
                    [
                        "type": "tool_result",
                        "tool_use_id": toolUseID,
                        "content": message.content,
                    ]
                ],
            ]
        }
    }

    private func mapTool(_ tool: Tool) -> [String: Any] {
        [
            "name": tool.name,
            "description": tool.description,
            "input_schema": tool.inputSchema,
        ]
    }

    // MARK: - Response Parsing

    private func parseResponse(_ data: Data) throws -> LLMResponse {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let contentBlocks = json["content"] as? [[String: Any]]
        else {
            throw LLMError.invalidResponse("Missing 'content' array in response")
        }

        var textContent = ""
        var toolUses: [ToolUse] = []

        for block in contentBlocks {
            guard let type = block["type"] as? String else { continue }

            switch type {
            case "text":
                if let text = block["text"] as? String {
                    textContent += text
                }
            case "tool_use":
                guard
                    let id = block["id"] as? String,
                    let name = block["name"] as? String,
                    let input = block["input"] as? [String: Any]
                else { continue }
                toolUses.append(ToolUse(id: id, name: name, input: input))
            default:
                break
            }
        }

        return LLMResponse(content: textContent, toolUses: toolUses)
    }
}
