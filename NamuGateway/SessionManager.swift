import Foundation

// MARK: - Desktop Session

/// Represents a connected Namu desktop instance.
public final class DesktopSession {
    public let id: UUID
    public let pairingTokenId: UUID
    public var lastHeartbeat: Date
    public var telegramChatIds: Set<String>  // Telegram chat IDs linked to this session
    public var metadata: [String: String]    // arbitrary key-value (hostname, version, etc.)

    // WebSocket send closure — set by the HTTP server when connection is established
    public var sendData: ((Data) -> Void)?

    public init(id: UUID = UUID(), pairingTokenId: UUID) {
        self.id = id
        self.pairingTokenId = pairingTokenId
        self.lastHeartbeat = Date()
        self.telegramChatIds = []
        self.metadata = [:]
    }

    public var isStale: Bool {
        Date().timeIntervalSince(lastHeartbeat) > SessionManager.staleThreshold
    }
}

// MARK: - SessionManager

/// Tracks connected Namu desktop sessions, heartbeats, and Telegram chat mappings.
public final class SessionManager {
    static let heartbeatInterval: TimeInterval = 30
    static let staleThreshold: TimeInterval = 300  // 5 minutes

    private var sessions: [UUID: DesktopSession] = [:]
    private var chatToSession: [String: UUID] = [:]   // telegramChatId → sessionId
    private let queue = DispatchQueue(label: "com.namu.gateway.sessions", attributes: .concurrent)
    private var cleanupTimer: Timer?

    public init() {
        startCleanupTimer()
    }

    deinit {
        cleanupTimer?.invalidate()
    }

    // MARK: - Session Lifecycle

    public func addSession(_ session: DesktopSession) {
        queue.async(flags: .barrier) { [weak self] in
            self?.sessions[session.id] = session
            print("[SessionManager] Session added: \(session.id)")
        }
    }

    public func removeSession(id: UUID) {
        queue.async(flags: .barrier) { [weak self] in
            guard let self = self else { return }
            if let session = self.sessions[id] {
                for chatId in session.telegramChatIds {
                    self.chatToSession.removeValue(forKey: chatId)
                }
            }
            self.sessions.removeValue(forKey: id)
            print("[SessionManager] Session removed: \(id)")
        }
    }

    public func session(for id: UUID) -> DesktopSession? {
        queue.sync { sessions[id] }
    }

    public var allSessions: [DesktopSession] {
        queue.sync { Array(sessions.values) }
    }

    // MARK: - Heartbeat

    public func recordHeartbeat(sessionId: UUID) {
        queue.async(flags: .barrier) { [weak self] in
            self?.sessions[sessionId]?.lastHeartbeat = Date()
        }
    }

    // MARK: - Telegram Chat Mapping

    /// Link a Telegram chat ID to a desktop session.
    public func linkChat(_ chatId: String, to sessionId: UUID) {
        queue.async(flags: .barrier) { [weak self] in
            guard let self = self else { return }
            self.chatToSession[chatId] = sessionId
            self.sessions[sessionId]?.telegramChatIds.insert(chatId)
        }
    }

    /// Unlink a Telegram chat ID from its session.
    public func unlinkChat(_ chatId: String) {
        queue.async(flags: .barrier) { [weak self] in
            guard let self = self else { return }
            if let sessionId = self.chatToSession[chatId] {
                self.sessions[sessionId]?.telegramChatIds.remove(chatId)
            }
            self.chatToSession.removeValue(forKey: chatId)
        }
    }

    /// Find the desktop session associated with a Telegram chat ID.
    public func session(forChatId chatId: String) -> DesktopSession? {
        queue.sync {
            guard let sessionId = chatToSession[chatId] else { return nil }
            return sessions[sessionId]
        }
    }

    // MARK: - Stale Cleanup

    private func startCleanupTimer() {
        let timer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            self?.cleanupStaleSessions()
        }
        RunLoop.main.add(timer, forMode: .common)
        cleanupTimer = timer
    }

    private func cleanupStaleSessions() {
        queue.async(flags: .barrier) { [weak self] in
            guard let self = self else { return }
            let stale = self.sessions.values.filter { $0.isStale }
            for session in stale {
                print("[SessionManager] Cleaning up stale session: \(session.id)")
                for chatId in session.telegramChatIds {
                    self.chatToSession.removeValue(forKey: chatId)
                }
                self.sessions.removeValue(forKey: session.id)
            }
        }
    }
}
