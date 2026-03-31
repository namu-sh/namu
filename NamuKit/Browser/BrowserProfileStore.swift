import Foundation
import WebKit

// MARK: - BrowserThemeMode

/// The appearance mode to apply to the browser web view.
enum BrowserThemeMode: String, Codable, CaseIterable {
    case system
    case light
    case dark
}

// MARK: - BrowserProfile

/// Represents an isolated browser profile with its own cookie and cache storage.
struct BrowserProfile: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String
    var isDefault: Bool
    /// Timestamp of the most recent time this profile was selected/activated.
    var lastUsedAt: Date?

    init(id: UUID = UUID(), name: String, isDefault: Bool = false, lastUsedAt: Date? = nil) {
        self.id = id
        self.name = name
        self.isDefault = isDefault
        self.lastUsedAt = lastUsedAt
    }
}

// MARK: - BrowserProfileStore

/// Manages browser profiles and theme mode. Each profile gets isolated website data storage.
/// Profiles are persisted in UserDefaults as JSON.
@MainActor
final class BrowserProfileStore: ObservableObject {

    // MARK: - Keys

    private enum Keys {
        static let profiles  = "namu.browser.profiles"
        static let themeMode = "namu.browser.themeMode"
    }

    // MARK: - Published state

    @Published private(set) var profiles: [BrowserProfile] = []
    @Published var themeMode: BrowserThemeMode = .system {
        didSet { persistThemeMode() }
    }

    // MARK: - Private state

    /// In-memory cache of non-persistent data stores keyed by profile id.
    /// Persistent profiles use WKWebsiteDataStore(forIdentifier:) when available,
    /// otherwise fall back to non-persistent stores.
    private var dataStores: [UUID: WKWebsiteDataStore] = [:]

    /// Per-profile history stores, created on demand and cached.
    var historyStores: [UUID: BrowserHistoryStore] = [:]

    // MARK: - Singleton

    static let shared = BrowserProfileStore()

    // MARK: - Init

    private init() {
        loadProfiles()
        loadThemeMode()
        if profiles.isEmpty {
            let defaultProfile = BrowserProfile(name: "Default", isDefault: true)
            profiles = [defaultProfile]
            persistProfiles()
        }
    }

    // MARK: - Profile management

    /// Create a new profile with the given name and persist it.
    @discardableResult
    func createProfile(name: String) -> BrowserProfile {
        let profile = BrowserProfile(name: name, isDefault: false)
        profiles.append(profile)
        persistProfiles()
        return profile
    }

    /// Delete the profile with the given id. The default profile cannot be deleted.
    func deleteProfile(id: UUID) {
        guard let profile = profiles.first(where: { $0.id == id }), !profile.isDefault else { return }
        profiles.removeAll { $0.id == id }
        dataStores.removeValue(forKey: id)
        persistProfiles()
    }

    /// Set the default profile by id. Clears any previous default.
    func setDefault(id: UUID) {
        profiles = profiles.map { p in
            var copy = p
            copy.isDefault = (p.id == id)
            return copy
        }
        persistProfiles()
    }

    /// Return the default profile, or the first profile if none is marked default.
    var defaultProfile: BrowserProfile {
        profiles.first(where: { $0.isDefault }) ?? profiles[0]
    }

    // MARK: - Usage tracking

    /// Record that the profile with the given id was selected/activated.
    /// Updates `lastUsedAt` to the current date and persists the change.
    func recordUsed(id: UUID) {
        guard let idx = profiles.firstIndex(where: { $0.id == id }) else { return }
        profiles[idx].lastUsedAt = Date()
        persistProfiles()
    }

    // MARK: - Debug

    /// Returns a human-readable summary of a profile's data store statistics.
    /// Includes estimated data store size and a cookie count snapshot (async).
    /// Intended for debug/diagnostic views only.
    func debugInfo(for profile: BrowserProfile) async -> String {
        var lines: [String] = [
            "Profile: \(profile.name) [\(profile.id)]",
            "Default: \(profile.isDefault)",
            "Last used: \(profile.lastUsedAt.map { $0.formatted() } ?? "never")",
        ]

        let store = dataStore(for: profile)
        let cookies = await store.httpCookieStore.allCookies()
        lines.append("Cookies: \(cookies.count)")

        // Approximate data store disk usage by summing website data record sizes.
        // WKWebsiteDataStore reports sizes asynchronously only for specific data types.
        let dataTypes = WKWebsiteDataStore.allWebsiteDataTypes()
        let records = await store.dataRecords(ofTypes: dataTypes)
        lines.append("Data records: \(records.count)")

        return lines.joined(separator: "\n")
    }

    // MARK: - History store resolution

    /// Return the `BrowserHistoryStore` for the given profile, creating one on demand.
    func historyStore(for profile: BrowserProfile) -> BrowserHistoryStore {
        if let cached = historyStores[profile.id] {
            return cached
        }
        let store = BrowserHistoryStore(profileID: profile.id)
        historyStores[profile.id] = store
        return store
    }

    // MARK: - Data store resolution

    /// Return the `WKWebsiteDataStore` for the given profile.
    /// - Default profile: uses `WKWebsiteDataStore.default()` for persistence.
    /// - Other profiles: uses a named persistent store on macOS 14+; falls back to non-persistent.
    func dataStore(for profile: BrowserProfile) -> WKWebsiteDataStore {
        if profile.isDefault {
            return .default()
        }

        if let cached = dataStores[profile.id] {
            return cached
        }

        let store: WKWebsiteDataStore
        if #available(macOS 14.0, *) {
            store = WKWebsiteDataStore(forIdentifier: profile.id)
        } else {
            store = .nonPersistent()
        }
        dataStores[profile.id] = store
        return store
    }

    // MARK: - Persistence

    private func persistProfiles() {
        guard let data = try? JSONEncoder().encode(profiles) else { return }
        UserDefaults.standard.set(data, forKey: Keys.profiles)
    }

    private func loadProfiles() {
        guard let data = UserDefaults.standard.data(forKey: Keys.profiles),
              let decoded = try? JSONDecoder().decode([BrowserProfile].self, from: data) else { return }
        profiles = decoded
    }

    private func persistThemeMode() {
        UserDefaults.standard.set(themeMode.rawValue, forKey: Keys.themeMode)
    }

    private func loadThemeMode() {
        guard let raw = UserDefaults.standard.string(forKey: Keys.themeMode),
              let mode = BrowserThemeMode(rawValue: raw) else { return }
        themeMode = mode
    }
}
