import Foundation

// MARK: - Telegram API Models

private struct TelegramUpdate: Decodable {
    let updateId: Int
    let message: TelegramMessage?
    let callbackQuery: TelegramCallbackQuery?

    enum CodingKeys: String, CodingKey {
        case updateId = "update_id"
        case message
        case callbackQuery = "callback_query"
    }
}

private struct TelegramMessage: Decodable {
    let messageId: Int
    let from: TelegramUser?
    let chat: TelegramChat
    let text: String?
    let date: Int

    enum CodingKeys: String, CodingKey {
        case messageId = "message_id"
        case from, chat, text, date
    }
}

private struct TelegramCallbackQuery: Decodable {
    let id: String
    let from: TelegramUser
    let message: TelegramMessage?
    let data: String?
}

private struct TelegramUser: Decodable {
    let id: Int
    let username: String?
    let firstName: String

    enum CodingKeys: String, CodingKey {
        case id
        case username
        case firstName = "first_name"
    }
}

private struct TelegramChat: Decodable {
    let id: Int
    let type: String
}

// MARK: - Rate Limiter

/// Tracks per-chat message timestamps to enforce Telegram's 30 msg/sec limit.
private final class RateLimiter {
    private let maxMessages: Int
    private let window: TimeInterval
    private var buckets: [String: [Date]] = [:]
    private let lock = NSLock()

    init(maxMessages: Int = 30, window: TimeInterval = 1.0) {
        self.maxMessages = maxMessages
        self.window = window
    }

    func isAllowed(chatId: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let now = Date()
        var timestamps = buckets[chatId, default: []]
        timestamps = timestamps.filter { now.timeIntervalSince($0) < window }
        guard timestamps.count < maxMessages else { return false }
        timestamps.append(now)
        buckets[chatId] = timestamps
        return true
    }
}

// MARK: - TelegramChannel

/// GatewayChannel implementation for the Telegram Bot API using webhooks.
public final class TelegramChannel: GatewayChannel {
    public let channelName = "Telegram"

    private let token: String
    private let apiBase: String
    private let rateLimiter = RateLimiter()
    private let sessionManager: SessionManager
    private var messageHandler: ((InboundMessage) -> Void)?
    private let urlSession: URLSession

    public init(token: String, sessionManager: SessionManager) {
        self.token = token
        self.apiBase = "https://api.telegram.org/bot\(token)"
        self.sessionManager = sessionManager
        self.urlSession = URLSession(configuration: .default)
    }

    // MARK: - GatewayChannel

    public func sendMessage(_ message: OutboundMessage, completion: @escaping (Result<Void, Error>) -> Void) {
        guard rateLimiter.isAllowed(chatId: message.chatId) else {
            completion(.failure(ChannelError.rateLimitExceeded))
            return
        }

        var body: [String: Any] = [
            "chat_id": message.chatId,
            "text": message.text,
            "parse_mode": "Markdown"
        ]

        if let keyboard = message.inlineKeyboard, !keyboard.isEmpty {
            let buttons = keyboard.map { row in
                row.map { btn -> [String: String] in
                    ["text": btn.text, "callback_data": btn.callbackData]
                }
            }
            body["reply_markup"] = ["inline_keyboard": buttons]
        }

        postToTelegram(method: "sendMessage", body: body, completion: completion)
    }

    public func onMessageReceived(_ message: InboundMessage) {
        messageHandler?(message)
    }

    public func setMessageHandler(_ handler: @escaping (InboundMessage) -> Void) {
        messageHandler = handler
    }

    // MARK: - Webhook Handling

    /// Parse a raw webhook JSON payload and dispatch to onMessageReceived.
    public func handleWebhookPayload(_ data: Data) {
        guard let update = try? JSONDecoder().decode(TelegramUpdate.self, from: data) else {
            print("[TelegramChannel] Failed to decode update")
            return
        }

        if let msg = update.message {
            let inbound = InboundMessage(
                messageId: "\(msg.messageId)",
                chatId: "\(msg.chat.id)",
                userId: "\(msg.from?.id ?? 0)",
                text: msg.text,
                callbackData: nil,
                timestamp: Date(timeIntervalSince1970: TimeInterval(msg.date))
            )
            onMessageReceived(inbound)
        } else if let cb = update.callbackQuery {
            let chatId = cb.message.map { "\($0.chat.id)" } ?? ""
            let inbound = InboundMessage(
                messageId: cb.id,
                chatId: chatId,
                userId: "\(cb.from.id)",
                text: nil,
                callbackData: cb.data,
                timestamp: Date()
            )
            // Answer the callback query to remove loading indicator
            answerCallbackQuery(queryId: cb.id)
            onMessageReceived(inbound)
        }
    }

    // MARK: - Private Helpers

    private func answerCallbackQuery(queryId: String) {
        postToTelegram(method: "answerCallbackQuery", body: ["callback_query_id": queryId]) { _ in }
    }

    private func postToTelegram(
        method: String,
        body: [String: Any],
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        guard let url = URL(string: "\(apiBase)/\(method)") else {
            completion(.failure(ChannelError.notConfigured("Invalid URL for method: \(method)")))
            return
        }

        guard let bodyData = try? JSONSerialization.data(withJSONObject: body) else {
            completion(.failure(ChannelError.invalidPayload("Could not serialize body")))
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = bodyData

        urlSession.dataTask(with: request) { data, response, error in
            if let error = error {
                completion(.failure(ChannelError.sendFailed(error.localizedDescription)))
                return
            }
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                let code = (response as? HTTPURLResponse)?.statusCode ?? -1
                completion(.failure(ChannelError.sendFailed("HTTP \(code)")))
                return
            }
            completion(.success(()))
        }.resume()
    }
}
