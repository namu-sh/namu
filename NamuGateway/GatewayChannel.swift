import Foundation

// MARK: - Outbound Message

/// A message sent from the Gateway to a messaging platform user.
public struct OutboundMessage {
    public let chatId: String
    public let text: String
    public let inlineKeyboard: [[InlineKeyboardButton]]?

    public init(chatId: String, text: String, inlineKeyboard: [[InlineKeyboardButton]]? = nil) {
        self.chatId = chatId
        self.text = text
        self.inlineKeyboard = inlineKeyboard
    }
}

/// A button in a Telegram-style inline keyboard.
public struct InlineKeyboardButton {
    public let text: String
    public let callbackData: String

    public init(text: String, callbackData: String) {
        self.text = text
        self.callbackData = callbackData
    }
}

// MARK: - Inbound Message

/// A message received from a user on a messaging platform.
public struct InboundMessage {
    public let messageId: String
    public let chatId: String
    public let userId: String
    public let text: String?
    public let callbackData: String?  // set for inline keyboard callbacks
    public let timestamp: Date

    public init(
        messageId: String,
        chatId: String,
        userId: String,
        text: String?,
        callbackData: String? = nil,
        timestamp: Date = Date()
    ) {
        self.messageId = messageId
        self.chatId = chatId
        self.userId = userId
        self.text = text
        self.callbackData = callbackData
        self.timestamp = timestamp
    }
}

// MARK: - GatewayChannel Protocol

/// Abstract adapter for a messaging platform (Telegram, WhatsApp, iMessage, etc.).
public protocol GatewayChannel: AnyObject {
    /// Human-readable name for this channel (e.g., "Telegram").
    var channelName: String { get }

    /// Send a message to a user on this channel.
    func sendMessage(_ message: OutboundMessage, completion: @escaping (Result<Void, Error>) -> Void)

    /// Called by the router when an inbound message arrives for this channel.
    func onMessageReceived(_ message: InboundMessage)

    /// Register a handler that is called whenever a message is received.
    func setMessageHandler(_ handler: @escaping (InboundMessage) -> Void)
}

// MARK: - Channel Error

public enum ChannelError: Error, LocalizedError {
    case notConfigured(String)
    case sendFailed(String)
    case rateLimitExceeded
    case invalidPayload(String)

    public var errorDescription: String? {
        switch self {
        case .notConfigured(let msg): return "Channel not configured: \(msg)"
        case .sendFailed(let msg): return "Send failed: \(msg)"
        case .rateLimitExceeded: return "Rate limit exceeded"
        case .invalidPayload(let msg): return "Invalid payload: \(msg)"
        }
    }
}
