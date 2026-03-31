import Foundation
import Security

// MARK: - AIProviderEntry

struct AIProviderEntry: Codable {
    var enabled: Bool
    var apiKey: String
    var baseURL: String?

    static func disabled() -> AIProviderEntry {
        AIProviderEntry(enabled: false, apiKey: "", baseURL: nil)
    }
}

// MARK: - AIProviderConfig

/// Shared configuration for all AI providers.
/// Persists a per-provider dictionary of enable/apiKey/baseURL to Keychain.
final class AIProviderConfig {

    static let shared = AIProviderConfig()

    private(set) var providers: [String: AIProviderEntry] = [:]

    private static let keychainService = "xyz.omlabs.namu.apikey"
    private static let keychainAccount = "multi-provider-config"

    static let didChangeNotification = Notification.Name("namu.aiProviderConfigDidChange")

    private init() {
        load()
    }

    // MARK: - Access

    func entry(for type: AIProviderType) -> AIProviderEntry {
        providers[type.configKey] ?? .disabled()
    }

    func setEntry(for type: AIProviderType, entry: AIProviderEntry) {
        providers[type.configKey] = entry
        save()
        NotificationCenter.default.post(name: Self.didChangeNotification, object: nil)
    }

    /// All provider types that are enabled and have an API key (or are custom with a base URL).
    var enabledProviders: [AIProviderType] {
        AIProviderType.allCases.filter { type in
            let e = entry(for: type)
            guard e.enabled else { return false }
            if type == .custom { return true }
            return !e.apiKey.trimmingCharacters(in: .whitespaces).isEmpty
        }
    }

    /// Whether at least one provider is configured and enabled.
    var hasAnyEnabled: Bool {
        !enabledProviders.isEmpty
    }

    // MARK: - Persistence

    func save() {
        guard let data = try? JSONEncoder().encode(providers) else { return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
            kSecAttrAccount as String: Self.keychainAccount,
        ]
        SecItemDelete(query as CFDictionary)
        var add = query
        add[kSecValueData as String] = data
        SecItemAdd(add as CFDictionary, nil)
    }

    func load() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
            kSecAttrAccount as String: Self.keychainAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let decoded = try? JSONDecoder().decode([String: AIProviderEntry].self, from: data)
        else {
            migrateFromLegacy()
            return
        }
        providers = decoded
    }

    // MARK: - Legacy Migration

    /// Migrate from the old single-provider Keychain format.
    private func migrateFromLegacy() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
            kSecAttrAccount as String: "provider-config",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let legacy = try? JSONDecoder().decode(LegacyConfig.self, from: data)
        else { return }

        if let type = AIProviderType(rawValue: legacy.provider) {
            let entry = AIProviderEntry(
                enabled: true,
                apiKey: legacy.apiKey,
                baseURL: legacy.baseURL
            )
            providers[type.configKey] = entry
            save()
        }
    }

    private struct LegacyConfig: Codable {
        let provider: String
        let apiKey: String
        let model: String
        let baseURL: String?
    }
}

// MARK: - AIProviderType + Config Key

extension AIProviderType {
    /// Stable key for dictionary serialization (lowercase).
    var configKey: String {
        switch self {
        case .claude:  return "claude"
        case .openai:  return "openai"
        case .gemini:  return "gemini"
        case .custom:  return "custom"
        }
    }

    var icon: String {
        switch self {
        case .claude:  return "brain.head.profile"
        case .openai:  return "circle.hexagongrid"
        case .gemini:  return "diamond"
        case .custom:  return "server.rack"
        }
    }

    var defaultModel: String {
        switch self {
        case .claude:  return "claude-opus-4-6"
        case .openai:  return "gpt-5.4"
        case .gemini:  return "gemini-3.1-pro"
        case .custom:  return "llama3"
        }
    }

    var models: [String] {
        switch self {
        case .claude:
            return ["claude-opus-4-6", "claude-sonnet-4-6", "claude-haiku-4-5"]
        case .openai:
            return ["gpt-5.4", "gpt-5.4-mini", "gpt-5.4-nano", "gpt-5.3-codex"]
        case .gemini:
            return ["gemini-3.1-pro", "gemini-3.1-flash", "gemini-3.1-flash-lite"]
        case .custom:
            return []
        }
    }

    var apiKeyPlaceholder: String {
        switch self {
        case .claude:  return "Paste Claude API key"
        case .openai:  return "Paste OpenAI API key"
        case .gemini:  return "AIza..."
        case .custom:  return "API key (optional)"
        }
    }
}
