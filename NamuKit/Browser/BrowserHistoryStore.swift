import Foundation

// MARK: - HistoryEntry

/// A single browser history record.
struct HistoryEntry: Identifiable, Codable, Equatable {
    let id: UUID
    let url: URL
    var title: String?
    var visitDate: Date

    init(id: UUID = UUID(), url: URL, title: String?, visitDate: Date = Date()) {
        self.id = id
        self.url = url
        self.title = title
        self.visitDate = visitDate
    }
}

// MARK: - BrowserHistoryStore

/// Per-profile browser history. Persists to UserDefaults as JSON.
/// Keeps the most recent 1000 entries, deduped by URL (most recent visit wins).
@MainActor
final class BrowserHistoryStore: ObservableObject {

    // MARK: - Published state

    @Published private(set) var entries: [HistoryEntry] = []

    // MARK: - Constants

    private static let maxEntries = 1000

    // MARK: - Persistence

    private let defaultsKey: String

    // MARK: - Init

    init(profileID: UUID) {
        self.defaultsKey = "namu.browser.history.\(profileID.uuidString)"
        load()
    }

    // MARK: - Public API

    /// Record a visit. Dedupes by URL — if the URL already exists, updates title and
    /// visitDate in-place and re-sorts. Trims to the last 1000 entries.
    func recordVisit(url: URL, title: String?) {
        if let idx = entries.firstIndex(where: { $0.url == url }) {
            entries[idx].visitDate = Date()
            if let title, !title.isEmpty {
                entries[idx].title = title
            }
        } else {
            let entry = HistoryEntry(url: url, title: title)
            entries.append(entry)
        }

        // Sort newest first, then trim.
        entries.sort { $0.visitDate > $1.visitDate }
        if entries.count > Self.maxEntries {
            entries = Array(entries.prefix(Self.maxEntries))
        }
        persist()
    }

    /// Relevance score for a history entry against the given query.
    func suggestionScore(query: String, entry: HistoryEntry) -> Double {
        let q = query.lowercased()
        let urlStr = entry.url.absoluteString.lowercased()
        let titleStr = (entry.title ?? "").lowercased()
        var score: Double = 0

        // URL/title prefix matches score higher than contains matches.
        if urlStr.hasPrefix(q)   { score += 100 }
        if titleStr.hasPrefix(q) { score += 80 }
        if urlStr.contains(q)    { score += 40 }
        if titleStr.contains(q)  { score += 30 }

        // Recency bonus: +20 scaled linearly over 30 days.
        let daysSince = Date().timeIntervalSince(entry.visitDate) / 86_400
        score += 20.0 * max(0.0, 1.0 - daysSince / 30.0)

        return score
    }

    /// Fuzzy search over URL absolute strings and titles.
    /// Returns matches sorted by relevance score, capped at 10 results.
    func search(query: String) -> [HistoryEntry] {
        let q = query.lowercased()
        guard !q.isEmpty else { return [] }
        let matched = entries.filter { entry in
            entry.url.absoluteString.lowercased().contains(q) ||
            (entry.title?.lowercased().contains(q) ?? false)
        }
        let sorted = matched.sorted { suggestionScore(query: query, entry: $0) > suggestionScore(query: query, entry: $1) }
        return Array(sorted.prefix(10))
    }

    // MARK: - Persistence

    private func persist() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        UserDefaults.standard.set(data, forKey: defaultsKey)
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let decoded = try? JSONDecoder().decode([HistoryEntry].self, from: data) else { return }
        entries = decoded
    }
}
