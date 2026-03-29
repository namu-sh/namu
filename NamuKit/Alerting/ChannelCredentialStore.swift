import Foundation
import Security
import os.log

private let logger = Logger(subsystem: "com.namu.app", category: "ChannelCredentialStore")

/// Thread-safe credential storage for alert channels.
/// Secrets (tokens, webhook URLs) go in Keychain; non-secret config in UserDefaults.
actor ChannelCredentialStore {

    private let defaults = UserDefaults.standard
    private let service = "xyz.omlabs.namu.alerting"

    private static let channelCredentialKeys: [String: [String]] = [
        "slack": ["webhookURL"],
        "telegram": ["botToken", "chatID"],
        "discord": ["webhookURL"],
        "webhook": ["url", "bearerToken"],
    ]

    // MARK: - Channel enabled state (UserDefaults)

    func isEnabled(_ channelID: String) -> Bool {
        defaults.bool(forKey: key(channelID, "enabled"))
    }

    func setEnabled(_ channelID: String, enabled: Bool) {
        defaults.set(enabled, forKey: key(channelID, "enabled"))
    }

    /// All channel IDs that have been configured (have at least one credential).
    func configuredChannelIDs() -> [String] {
        let known = ["slack", "telegram", "discord", "webhook"]
        return known.filter { defaults.bool(forKey: key($0, "configured")) || isEnabled($0) }
    }

    // MARK: - Secrets (Keychain)

    func setCredential(_ channelID: String, _ name: String, value: String) {
        let account = "\(channelID).\(name)"
        let data = Data(value.utf8)

        // Delete existing
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        // Add new with proper accessibility
        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked,
        ]
        let status = SecItemAdd(addQuery as CFDictionary, nil)
        if status != errSecSuccess {
            logger.error("Keychain write failed for \(account): \(status)")
        }

        defaults.set(true, forKey: key(channelID, "configured"))
    }

    func credential(_ channelID: String, _ name: String) -> String? {
        let account = "\(channelID).\(name)"
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func removeCredential(_ channelID: String, _ name: String) {
        let account = "\(channelID).\(name)"
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }

    /// Remove all credentials for a specific channel only.
    func removeAllCredentials(_ channelID: String) {
        for name in Self.channelCredentialKeys[channelID] ?? [] {
            removeCredential(channelID, name)
        }
        defaults.removeObject(forKey: key(channelID, "configured"))
        defaults.removeObject(forKey: key(channelID, "enabled"))
    }

    // MARK: - Private

    private func key(_ channelID: String, _ name: String) -> String {
        "namu.alerting.\(channelID).\(name)"
    }
}
