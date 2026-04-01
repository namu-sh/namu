import Foundation

// MARK: - HistoryEntry

/// A single browser history record with frecency tracking.
struct HistoryEntry: Identifiable, Codable, Equatable {
    let id: UUID
    let url: URL
    var title: String?
    var visitDate: Date
    var visitCount: Int
    var typedCount: Int
    var lastTypedAt: Date?

    init(id: UUID = UUID(), url: URL, title: String?, visitDate: Date = Date(),
         visitCount: Int = 1, typedCount: Int = 0, lastTypedAt: Date? = nil) {
        self.id = id
        self.url = url
        self.title = title
        self.visitDate = visitDate
        self.visitCount = visitCount
        self.typedCount = typedCount
        self.lastTypedAt = lastTypedAt
    }

    // Backward-compatible decoding — old entries lack frecency fields.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        url = try c.decode(URL.self, forKey: .url)
        title = try c.decodeIfPresent(String.self, forKey: .title)
        visitDate = try c.decode(Date.self, forKey: .visitDate)
        visitCount = try c.decodeIfPresent(Int.self, forKey: .visitCount) ?? 1
        typedCount = try c.decodeIfPresent(Int.self, forKey: .typedCount) ?? 0
        lastTypedAt = try c.decodeIfPresent(Date.self, forKey: .lastTypedAt)
    }
}

// MARK: - BrowserHistoryStore

/// Per-profile browser history with frecency-based suggestion scoring.
/// Tracks visit count, typed-navigation count, and recency to produce
/// address-bar suggestions weighted by frequency + recency (frecency).
@MainActor
final class BrowserHistoryStore: ObservableObject {

    // MARK: - Published state

    @Published private(set) var entries: [HistoryEntry] = []

    // MARK: - Constants

    static let maxEntries = 2000

    // MARK: - Persistence

    private let defaultsKey: String

    // MARK: - Init

    init(profileID: UUID) {
        self.defaultsKey = "namu.browser.history.\(profileID.uuidString)"
        load()
    }

    // MARK: - Public API

    /// Record an implicit visit (link click, redirect, JS navigation, etc.).
    func recordVisit(url: URL, title: String?) {
        upsert(url: url, title: title, isTyped: false)
    }

    /// Record a typed navigation — the user explicitly entered this URL in the address bar.
    func recordTypedNavigation(url: URL, title: String? = nil) {
        upsert(url: url, title: title, isTyped: true)
    }

    /// Relevance score for a history entry against the given query.
    /// Returns nil if the entry doesn't match at all.
    func suggestionScore(query: String, entry: HistoryEntry, now: Date = Date()) -> Double? {
        let q = query.lowercased()
        let candidate = SuggestionCandidate(entry: entry)
        let tokens = Self.tokenize(q)
        return score(candidate: candidate, query: q, queryTokens: tokens, now: now)
    }

    /// Search history for entries matching `query`. Returns matches sorted by
    /// frecency-weighted relevance, capped at `limit` results.
    func search(query: String, limit: Int = 10) -> [HistoryEntry] {
        let q = query.lowercased()
        guard !q.isEmpty else { return recentSuggestions(limit: limit) }

        let tokens = Self.tokenize(q)
        let now = Date()

        var scored: [(entry: HistoryEntry, score: Double)] = []
        for entry in entries {
            let candidate = SuggestionCandidate(entry: entry)
            if let s = score(candidate: candidate, query: q, queryTokens: tokens, now: now) {
                scored.append((entry, s))
            }
        }

        scored.sort { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            if lhs.entry.visitDate != rhs.entry.visitDate { return lhs.entry.visitDate > rhs.entry.visitDate }
            if lhs.entry.visitCount != rhs.entry.visitCount { return lhs.entry.visitCount > rhs.entry.visitCount }
            return lhs.entry.url.absoluteString < rhs.entry.url.absoluteString
        }

        return Array(scored.prefix(limit).map(\.entry))
    }

    /// Top recent entries for empty-query suggestions, ranked by typed frequency then recency.
    func recentSuggestions(limit: Int = 10) -> [HistoryEntry] {
        let ranked = entries.sorted { lhs, rhs in
            if lhs.typedCount != rhs.typedCount { return lhs.typedCount > rhs.typedCount }
            let lDate = lhs.lastTypedAt ?? .distantPast
            let rDate = rhs.lastTypedAt ?? .distantPast
            if lDate != rDate { return lDate > rDate }
            if lhs.visitDate != rhs.visitDate { return lhs.visitDate > rhs.visitDate }
            if lhs.visitCount != rhs.visitCount { return lhs.visitCount > rhs.visitCount }
            return lhs.url.absoluteString < rhs.url.absoluteString
        }
        return Array(ranked.prefix(limit))
    }

    // MARK: - Private: Upsert

    private func upsert(url: URL, title: String?, isTyped: Bool) {
        if let idx = entries.firstIndex(where: { $0.url == url }) {
            entries[idx].visitDate = Date()
            entries[idx].visitCount += 1
            if let title, !title.isEmpty {
                entries[idx].title = title
            }
            if isTyped {
                entries[idx].typedCount += 1
                entries[idx].lastTypedAt = Date()
            }
        } else {
            let entry = HistoryEntry(
                url: url, title: title,
                visitCount: 1,
                typedCount: isTyped ? 1 : 0,
                lastTypedAt: isTyped ? Date() : nil
            )
            entries.append(entry)
        }

        entries.sort { $0.visitDate > $1.visitDate }
        if entries.count > Self.maxEntries {
            entries = Array(entries.prefix(Self.maxEntries))
        }
        persist()
    }

    // MARK: - Private: Suggestion Scoring

    /// Pre-computed lowercase URL components for efficient matching.
    private struct SuggestionCandidate {
        let entry: HistoryEntry
        let urlLower: String
        let urlSansSchemeLower: String
        let hostLower: String
        let pathAndQueryLower: String
        let titleLower: String

        init(entry: HistoryEntry) {
            self.entry = entry
            let urlStr = entry.url.absoluteString.lowercased()
            self.urlLower = urlStr
            if let range = urlStr.range(of: "://") {
                self.urlSansSchemeLower = String(urlStr[range.upperBound...])
            } else {
                self.urlSansSchemeLower = urlStr
            }
            self.hostLower = (entry.url.host ?? "").lowercased()
            var pq = entry.url.path.lowercased()
            if let query = entry.url.query?.lowercased() { pq += "?" + query }
            self.pathAndQueryLower = pq
            self.titleLower = (entry.title ?? "").lowercased()
        }
    }

    /// Split query into tokens on whitespace, punctuation, and symbols.
    private static func tokenize(_ query: String) -> [String] {
        query.components(separatedBy: CharacterSet.whitespacesAndNewlines
            .union(.punctuationCharacters).union(.symbols))
            .map { $0.lowercased() }
            .filter { !$0.isEmpty }
    }

    /// Core scoring: tiered text matching + frecency (frequency × recency).
    private func score(candidate: SuggestionCandidate, query: String,
                       queryTokens: [String], now: Date) -> Double? {
        let queryIncludesScheme = query.hasPrefix("http://") || query.hasPrefix("https://")
        let urlMatch = queryIncludesScheme ? candidate.urlLower : candidate.urlSansSchemeLower

        // Single-char queries require a strong prefix match.
        if query.count == 1 {
            let strong = candidate.hostLower.hasPrefix(query) ||
                candidate.titleLower.hasPrefix(query) ||
                urlMatch.hasPrefix(query)
            guard strong else { return nil }
        }

        // Must match as whole query or all tokens.
        let queryMatches = urlMatch.contains(query) ||
            candidate.hostLower.contains(query) ||
            candidate.pathAndQueryLower.contains(query) ||
            candidate.titleLower.contains(query)

        let tokenMatches = !queryTokens.isEmpty && queryTokens.allSatisfy { token in
            candidate.urlSansSchemeLower.contains(token) ||
            candidate.hostLower.contains(token) ||
            candidate.pathAndQueryLower.contains(token) ||
            candidate.titleLower.contains(token)
        }

        guard queryMatches || tokenMatches else { return nil }

        // --- Tiered text-match scoring ---
        var s = 0.0

        // Exact and prefix matches (primary differentiators)
        if urlMatch == query                            { s += 1200 }
        if candidate.hostLower == query                 { s += 980 }
        if candidate.hostLower.hasPrefix(query)         { s += 680 }
        if urlMatch.hasPrefix(query)                    { s += 560 }
        if candidate.titleLower.hasPrefix(query)        { s += 420 }
        if candidate.pathAndQueryLower.hasPrefix(query) { s += 300 }

        // Contains matches (secondary)
        if candidate.hostLower.contains(query)            { s += 210 }
        if candidate.pathAndQueryLower.contains(query)    { s += 165 }
        if candidate.titleLower.contains(query)           { s += 145 }

        // Token-based matching (for multi-word queries)
        for token in queryTokens {
            if candidate.hostLower == token                     { s += 260 }
            else if candidate.hostLower.hasPrefix(token)        { s += 170 }
            else if candidate.hostLower.contains(token)         { s += 110 }

            if candidate.pathAndQueryLower.hasPrefix(token)     { s += 80 }
            else if candidate.pathAndQueryLower.contains(token) { s += 52 }

            if candidate.titleLower.hasPrefix(token)            { s += 74 }
            else if candidate.titleLower.contains(token)        { s += 48 }
        }

        // --- Frecency: recency + frequency blend ---
        let ageHours = max(0, now.timeIntervalSince(candidate.entry.visitDate) / 3600)
        s += max(0, 110 - (ageHours / 3))                                          // recency: decays over ~14 days

        s += min(120, log1p(Double(max(1, candidate.entry.visitCount))) * 38)       // visit frequency (log scale)
        s += min(190, log1p(Double(max(0, candidate.entry.typedCount))) * 80)       // typed frequency (weighted higher)

        if let lastTyped = candidate.entry.lastTypedAt {
            let typedAge = max(0, now.timeIntervalSince(lastTyped) / 3600)
            s += max(0, 85 - (typedAge / 4))                                       // typed recency
        }

        return s
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
