import Foundation

// MARK: - Pairing Entry

private struct PairingEntry: Codable {
    let chatID: Int64
    let pairingToken: String
    let linkedAt: Date
}

// MARK: - Pending Code

private struct PendingCode {
    let code: String
    let expiresAt: Date
    let chatID: Int64
}

// MARK: - Pending Confirmation

struct PendingConfirmation {
    let id: String
    let chatID: Int64
    let command: String
    let reason: String
    let expiresAt: Date
    var continuation: CheckedContinuation<Bool, Never>?
}

// MARK: - UserLinkService

/// Manages Telegram chat ID ↔ Mosaic pairing token associations.
///
/// Flow:
/// 1. User sends /start to Telegram bot
/// 2. Bot calls `generatePairingCode(chatID:)` → returns 6-digit code (5 min expiry)
/// 3. User enters code in Mosaic desktop settings along with their pairing token
/// 4. Desktop POST /link { code, pairingToken } → Gateway calls `validateAndLink(code:pairingToken:)`
/// 5. Gateway stores chatID ↔ pairingToken mapping in JSON file
final class UserLinkService: @unchecked Sendable {

    // MARK: - Storage

    private let storageURL: URL
    private let lock = NSLock()

    /// chatID → PairingEntry
    private var pairings: [Int64: PairingEntry] = [:]

    /// 6-digit code → PendingCode (cleared after use or expiry)
    private var pendingCodes: [String: PendingCode] = [:]

    /// confirmationID → PendingConfirmation
    private var pendingConfirmations: [String: PendingConfirmation] = [:]

    // MARK: - Init

    init(storageURL: URL? = nil) {
        if let url = storageURL {
            self.storageURL = url
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: "/tmp")
            self.storageURL = appSupport
                .appendingPathComponent("MosaicGateway", isDirectory: true)
                .appendingPathComponent("pairings.json")
        }
        loadPairings()
    }

    // MARK: - /start — Generate pairing code

    /// Called when user sends /start to the Telegram bot.
    /// Returns a 6-digit code that expires in 5 minutes.
    func generatePairingCode(chatID: Int64) -> String {
        lock.lock()
        defer { lock.unlock() }

        // Remove any previous pending code for this chatID
        pendingCodes = pendingCodes.filter { $0.value.chatID != chatID }

        let code = String(format: "%06d", Int.random(in: 0..<1_000_000))
        let expiry = Date().addingTimeInterval(5 * 60)
        pendingCodes[code] = PendingCode(code: code, expiresAt: expiry, chatID: chatID)

        print("[UserLinkService] Generated pairing code \(code) for chatID \(chatID), expires \(expiry)")
        return code
    }

    // MARK: - Desktop validation — Link chatID to pairingToken

    enum LinkResult {
        case linked(chatID: Int64)
        case invalidCode
        case expiredCode
        case alreadyLinked
    }

    /// Called by the desktop after the user enters the 6-digit code.
    /// Validates the code and permanently links `chatID` to `pairingToken`.
    func validateAndLink(code: String, pairingToken: String) -> LinkResult {
        lock.lock()
        defer { lock.unlock() }

        guard let pending = pendingCodes[code] else {
            return .invalidCode
        }

        guard pending.expiresAt > Date() else {
            pendingCodes.removeValue(forKey: code)
            return .expiredCode
        }

        let chatID = pending.chatID
        pendingCodes.removeValue(forKey: code)

        if pairings[chatID] != nil {
            // Already linked — overwrite (re-link is allowed)
            print("[UserLinkService] Re-linking chatID \(chatID)")
        }

        let entry = PairingEntry(chatID: chatID, pairingToken: pairingToken, linkedAt: Date())
        pairings[chatID] = entry
        savePairings()

        print("[UserLinkService] Linked chatID \(chatID) to token \(String(pairingToken.prefix(8)))...")
        return .linked(chatID: chatID)
    }

    // MARK: - /unlink

    /// Called when user sends /unlink to the bot.
    /// Returns true if a pairing existed and was removed.
    @discardableResult
    func unlink(chatID: Int64) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        guard pairings[chatID] != nil else { return false }
        pairings.removeValue(forKey: chatID)
        savePairings()
        print("[UserLinkService] Unlinked chatID \(chatID)")
        return true
    }

    // MARK: - Lookup

    /// Returns the pairing token for a given Telegram chatID, if linked.
    func pairingToken(for chatID: Int64) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return pairings[chatID]?.pairingToken
    }

    /// Returns the chatID for a given pairing token, if linked.
    func chatID(for pairingToken: String) -> Int64? {
        lock.lock()
        defer { lock.unlock() }
        return pairings.values.first(where: { $0.pairingToken == pairingToken })?.chatID
    }

    func isLinked(chatID: Int64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return pairings[chatID] != nil
    }

    // MARK: - Dangerous Command Confirmation

    /// Called by the Gateway when CommandSafety returns `.requiresConfirmation`.
    ///
    /// Sends an inline keyboard to the Telegram user and suspends until:
    /// - User taps Yes → returns true
    /// - User taps No → returns false
    /// - 60-second timeout → returns false
    ///
    /// - Parameters:
    ///   - chatID: The Telegram chat to send the prompt to.
    ///   - command: The command name being confirmed.
    ///   - reason: The safety reason string from CommandSafety.
    ///   - sendMessage: Async closure that sends a Telegram message with inline keyboard.
    ///                  Receives (chatID, text, callbackData) → returns message_id or nil.
    func requestConfirmation(
        chatID: Int64,
        command: String,
        reason: String,
        sendInlineKeyboard: @escaping @Sendable (Int64, String, String) async -> Void
    ) async -> Bool {
        let confirmationID = UUID().uuidString
        let expiry = Date().addingTimeInterval(60)

        return await withCheckedContinuation { continuation in
            lock.lock()
            pendingConfirmations[confirmationID] = PendingConfirmation(
                id: confirmationID,
                chatID: chatID,
                command: command,
                reason: reason,
                expiresAt: expiry,
                continuation: continuation
            )
            lock.unlock()

            Task {
                // Send Telegram inline keyboard prompt
                let text = "Allow command?\n\n`\(command)`\nReason: \(reason)"
                let callbackData = confirmationID
                await sendInlineKeyboard(chatID, text, callbackData)

                // Schedule 60s timeout
                try? await Task.sleep(for: .seconds(60))
                self.expireConfirmation(id: confirmationID)
            }
        }
    }

    /// Called by TelegramChannel when a callback_query arrives for an inline keyboard button.
    ///
    /// - Parameters:
    ///   - confirmationID: The callback_data value (our confirmation UUID).
    ///   - approved: true if user tapped Yes, false for No.
    /// - Returns: true if the confirmation was found and resolved, false if expired/unknown.
    @discardableResult
    func resolveConfirmation(id confirmationID: String, approved: Bool) -> Bool {
        lock.lock()
        guard var pending = pendingConfirmations[confirmationID] else {
            lock.unlock()
            return false
        }

        guard pending.expiresAt > Date() else {
            pendingConfirmations.removeValue(forKey: confirmationID)
            lock.unlock()
            return false
        }

        let continuation = pending.continuation
        pending.continuation = nil
        pendingConfirmations.removeValue(forKey: confirmationID)
        lock.unlock()

        continuation?.resume(returning: approved)
        print("[UserLinkService] Confirmation \(confirmationID) resolved: \(approved ? "approved" : "rejected")")
        return true
    }

    // MARK: - Private Helpers

    private func expireConfirmation(id: String) {
        lock.lock()
        guard let pending = pendingConfirmations[id] else {
            lock.unlock()
            return
        }
        let continuation = pending.continuation
        pendingConfirmations.removeValue(forKey: id)
        lock.unlock()

        continuation?.resume(returning: false)
        print("[UserLinkService] Confirmation \(id) expired (60s timeout)")
    }

    // MARK: - JSON Persistence

    private func loadPairings() {
        guard FileManager.default.fileExists(atPath: storageURL.path) else { return }
        do {
            let data = try Data(contentsOf: storageURL)
            let entries = try JSONDecoder().decode([PairingEntry].self, from: data)
            pairings = Dictionary(uniqueKeysWithValues: entries.map { ($0.chatID, $0) })
            print("[UserLinkService] Loaded \(pairings.count) pairing(s)")
        } catch {
            print("[UserLinkService] Failed to load pairings: \(error)")
        }
    }

    private func savePairings() {
        do {
            let dir = storageURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(Array(pairings.values))
            try data.write(to: storageURL, options: .atomic)
        } catch {
            print("[UserLinkService] Failed to save pairings: \(error)")
        }
    }
}
