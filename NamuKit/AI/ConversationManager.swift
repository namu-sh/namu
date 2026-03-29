import Foundation

// MARK: - Conversation

/// A single conversation thread with its own message history.
final class Conversation: @unchecked Sendable {
    let id: UUID
    private(set) var messages: [Message]
    private(set) var lastActivityDate: Date

    private let lock = NSLock()

    init(id: UUID = UUID()) {
        self.id = id
        self.messages = []
        self.lastActivityDate = Date()
    }

    func append(_ message: Message) {
        lock.withLock {
            messages.append(message)
            lastActivityDate = Date()
        }
    }

    func allMessages() -> [Message] {
        lock.withLock { messages }
    }

    func touch() {
        lock.withLock { lastActivityDate = Date() }
    }

    var isExpired: Bool {
        lock.withLock {
            Date().timeIntervalSince(lastActivityDate) > ConversationManager.expiryInterval
        }
    }
}

// MARK: - ConversationManager

/// Manages per-chat conversation state for multi-turn interactions.
/// Conversations expire after 30 minutes of inactivity.
final class ConversationManager: @unchecked Sendable {

    static let expiryInterval: TimeInterval = 30 * 60  // 30 minutes

    private let lock = NSLock()
    private var conversations: [UUID: Conversation] = [:]
    private var cleanupTimer: DispatchSourceTimer?

    init() {
        scheduleCleanup()
    }

    deinit {
        cleanupTimer?.cancel()
    }

    // MARK: - Access

    /// Return the existing conversation for `id`, or create a new one.
    func conversation(for id: UUID) -> Conversation {
        lock.withLock {
            if let existing = conversations[id] {
                existing.touch()
                return existing
            }
            let new = Conversation(id: id)
            conversations[id] = new
            return new
        }
    }

    /// Create a brand-new conversation, returning its ID.
    @discardableResult
    func createConversation() -> UUID {
        let conv = Conversation()
        lock.withLock { conversations[conv.id] = conv }
        return conv.id
    }

    /// Remove the conversation with the given ID.
    func removeConversation(_ id: UUID) {
        lock.withLock { conversations.removeValue(forKey: id) }
    }

    /// All active (non-expired) conversation IDs.
    var activeConversationIDs: [UUID] {
        lock.withLock {
            conversations.values.filter { !$0.isExpired }.map(\.id)
        }
    }

    // MARK: - Cleanup

    private func scheduleCleanup() {
        // Run cleanup every 5 minutes, independent of any RunLoop.
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + 300, repeating: 300)
        timer.setEventHandler { [weak self] in self?.purgeExpired() }
        timer.resume()
        cleanupTimer = timer
    }

    private func purgeExpired() {
        lock.withLock {
            let expired = conversations.filter { $0.value.isExpired }.map(\.key)
            for key in expired {
                conversations.removeValue(forKey: key)
            }
        }
    }
}