import Foundation

// MARK: - GeminiProvider

final class GeminiProvider: LLMProvider {
    private let apiKey: String
    private let model: String
    private let session: URLSession

    init(apiKey: String, model: String = "gemini-3.1-pro", session: URLSession = .shared) {
        self.apiKey = apiKey
        self.model = model
        self.session = session
    }

    // MARK: - LLMProvider

    func complete(messages: [Message], tools: [Tool]) async throws -> LLMResponse {
        let requestBody = buildRequest(messages: messages, tools: tools)
        let data = try JSONSerialization.data(withJSONObject: requestBody)

        let urlString = "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent?key=\(apiKey)"
        guard let url = URL(string: urlString) else {
            throw LLMError.invalidResponse("Invalid URL for model: \(model)")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = data
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
        case 401, 403:
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
            "contents": messages.compactMap { mapMessage($0) },
        ]

        // System instruction is top-level in Gemini API
        if let systemMsg = messages.first(where: { $0.role == .system }) {
            body["systemInstruction"] = [
                "parts": [["text": systemMsg.content]]
            ]
        }

        if !tools.isEmpty {
            body["tools"] = [
                [
                    "functionDeclarations": tools.map { mapTool($0) }
                ]
            ]
        }

        return body
    }

    private func mapMessage(_ message: Message) -> [String: Any]? {
        switch message.role {
        case .system:
            // System handled separately at top level
            return nil
        case .user:
            return ["role": "user", "parts": [["text": message.content]]]
        case .assistant:
            return ["role": "model", "parts": [["text": message.content]]]
        case .tool:
            guard let toolUseID = message.toolUseID else { return nil }
            return [
                "role": "function",
                "parts": [
                    [
                        "functionResponse": [
                            "name": toolUseID,
                            "response": [
                                "content": message.content,
                            ],
                        ]
                    ]
                ],
            ]
        }
    }

    private func mapTool(_ tool: Tool) -> [String: Any] {
        [
            "name": tool.name,
            "description": tool.description,
            "parameters": tool.inputSchema,
        ]
    }

    // MARK: - Response Parsing

    private func parseResponse(_ data: Data) throws -> LLMResponse {
        guard
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let candidates = json["candidates"] as? [[String: Any]],
            let first = candidates.first,
            let content = first["content"] as? [String: Any],
            let parts = content["parts"] as? [[String: Any]]
        else {
            throw LLMError.invalidResponse("Missing 'candidates' in Gemini response")
        }

        var textContent = ""
        var toolUses: [ToolUse] = []

        for part in parts {
            if let text = part["text"] as? String {
                textContent += text
            } else if let functionCall = part["functionCall"] as? [String: Any],
                      let name = functionCall["name"] as? String {
                let args = functionCall["args"] as? [String: Any] ?? [:]
                let id = UUID().uuidString
                toolUses.append(ToolUse(id: id, name: name, input: args))
            }
        }

        return LLMResponse(content: textContent, toolUses: toolUses)
    }
}
