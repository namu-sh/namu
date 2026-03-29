import Foundation

/// Sends alerts to a Telegram chat via Bot API.
struct TelegramChannel: AlertChannel, Sendable {
    let id = "telegram"
    let displayName = "Telegram"

    private let botToken: String
    private let chatID: String

    init(botToken: String, chatID: String) {
        self.botToken = botToken
        self.chatID = chatID
    }

    func send(_ payload: AlertPayload) async throws {
        guard let url = URL(string: "https://api.telegram.org/bot\(botToken)/sendMessage") else {
            throw AlertChannelError.notConfigured("Telegram bot token is invalid")
        }

        let body: [String: Any] = [
            "chat_id": chatID,
            "text": payload.markdownBody,
            "parse_mode": "Markdown",
            "disable_web_page_preview": true
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw AlertChannelError.sendFailed("Telegram", underlyingError: nil)
        }

        if http.statusCode == 429 {
            throw AlertChannelError.rateLimited
        }

        guard (200..<300).contains(http.statusCode) else {
            let detail = String(data: data, encoding: .utf8) ?? ""
            throw AlertChannelError.sendFailed("Telegram", underlyingError: NSError(
                domain: "TelegramAPI", code: http.statusCode,
                userInfo: [NSLocalizedDescriptionKey: detail]
            ))
        }
    }
}
