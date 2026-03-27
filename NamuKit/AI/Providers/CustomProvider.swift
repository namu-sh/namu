import Foundation

// MARK: - CustomProvider

/// OpenAI-compatible provider with a configurable base URL.
/// Works with Ollama, LMStudio, Together, Groq, and other OpenAI-compatible APIs.
final class CustomProvider: LLMProvider {
    private let apiKey: String
    private let model: String
    private let baseURL: URL
    private let session: URLSession

    init(
        apiKey: String,
        model: String = "llama3",
        baseURL: String = "http://localhost:11434/v1",
        session: URLSession = .shared
    ) {
        self.apiKey = apiKey
        self.model = model
        self.baseURL = URL(string: baseURL)!.appendingPathComponent("chat/completions")
        self.session = session
    }

    // MARK: - LLMProvider

    func complete(messages: [Message], tools: [Tool]) async throws -> LLMResponse {
        let requestBody = buildRequest(messages: messages, tools: tools)
        let data = try JSONSerialization.data(withJSONObject: requestBody)

        var request = URLRequest(url: baseURL)
        request.httpMethod = "POST"
        request.httpBody = data
        if !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
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
            "messages": messages.map { mapMessage($0) },
        ]

        if !tools.isEmpty {
            body["tools"] = tools.map { mapTool($0) }
            body["tool_choice"] = "auto"
        }

        return body
    }

    private func mapMessage(_ message: Message) -> [String: Any] {
        switch message.role {
        case .system:
            return ["role": "system", "content": message.content]
        case .user:
            return ["role": "user", "content": message.content]
        case .assistant:
            return ["role": "assistant", "content": message.content]
        case .tool:
            return [
                "role": "tool",
                "tool_call_id": message.toolUseID ?? "",
                "content": message.content,
            ]
        }
    }

    private func mapTool(_ tool: Tool) -> [String: Any] {
        [
            "type": "function",
            "function": [
                "name": tool.name,
                "description": tool.description,
                "parameters": tool.inputSchema,
            ] as [String: Any],
        ]
    }

    // MARK: - Response Parsing

    private func parseResponse(_ data: Data) throws -> LLMResponse {
        guard
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let choices = json["choices"] as? [[String: Any]],
            let first = choices.first,
            let messagePart = first["message"] as? [String: Any]
        else {
            throw LLMError.invalidResponse("Missing 'choices' in response")
        }

        let textContent = messagePart["content"] as? String ?? ""
        var toolUses: [ToolUse] = []

        if let toolCalls = messagePart["tool_calls"] as? [[String: Any]] {
            for call in toolCalls {
                guard
                    let id = call["id"] as? String,
                    let function = call["function"] as? [String: Any],
                    let name = function["name"] as? String,
                    let argumentsString = function["arguments"] as? String,
                    let argumentsData = argumentsString.data(using: .utf8),
                    let input = try? JSONSerialization.jsonObject(with: argumentsData) as? [String: Any]
                else { continue }
                toolUses.append(ToolUse(id: id, name: name, input: input))
            }
        }

        return LLMResponse(content: textContent, toolUses: toolUses)
    }
}
