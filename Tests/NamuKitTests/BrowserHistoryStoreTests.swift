import XCTest
@testable import Namu

@MainActor
final class BrowserHistoryStoreTests: XCTestCase {

    // Use a unique profile ID per test to avoid cross-contamination.
    private func makeStore() -> BrowserHistoryStore {
        BrowserHistoryStore(profileID: UUID())
    }

    private func url(_ string: String) -> URL { URL(string: string)! }

    // MARK: - HistoryEntry Codable

    func testHistoryEntryBackwardCompatibleDecoding() throws {
        // Old entries lack visitCount, typedCount, lastTypedAt — they should decode with defaults.
        let json = """
        {"id":"00000000-0000-0000-0000-000000000001","url":"https:\\/\\/example.com","title":"Example","visitDate":0}
        """
        let entry = try JSONDecoder().decode(HistoryEntry.self, from: Data(json.utf8))
        XCTAssertEqual(entry.url, url("https://example.com"))
        XCTAssertEqual(entry.visitCount, 1)
        XCTAssertEqual(entry.typedCount, 0)
        XCTAssertNil(entry.lastTypedAt)
    }

    func testHistoryEntryRoundTrip() throws {
        let entry = HistoryEntry(url: url("https://test.dev"), title: "Test",
                                  visitCount: 5, typedCount: 3, lastTypedAt: Date())
        let data = try JSONEncoder().encode(entry)
        let decoded = try JSONDecoder().decode(HistoryEntry.self, from: data)
        XCTAssertEqual(decoded, entry)
    }

    // MARK: - recordVisit

    func testRecordVisitCreatesNewEntry() {
        let store = makeStore()
        store.recordVisit(url: url("https://a.com"), title: "A")
        XCTAssertEqual(store.entries.count, 1)
        XCTAssertEqual(store.entries[0].visitCount, 1)
        XCTAssertEqual(store.entries[0].typedCount, 0)
        XCTAssertNil(store.entries[0].lastTypedAt)
    }

    func testRecordVisitIncrementsVisitCount() {
        let store = makeStore()
        store.recordVisit(url: url("https://a.com"), title: "A")
        store.recordVisit(url: url("https://a.com"), title: "A Updated")
        XCTAssertEqual(store.entries.count, 1)
        XCTAssertEqual(store.entries[0].visitCount, 2)
        XCTAssertEqual(store.entries[0].title, "A Updated")
    }

    func testRecordVisitDoesNotSetTypedFields() {
        let store = makeStore()
        store.recordVisit(url: url("https://a.com"), title: nil)
        store.recordVisit(url: url("https://a.com"), title: nil)
        XCTAssertEqual(store.entries[0].typedCount, 0)
        XCTAssertNil(store.entries[0].lastTypedAt)
    }

    // MARK: - recordTypedNavigation

    func testRecordTypedNavigationSetsTypedFields() {
        let store = makeStore()
        store.recordTypedNavigation(url: url("https://typed.com"))
        XCTAssertEqual(store.entries.count, 1)
        XCTAssertEqual(store.entries[0].visitCount, 1)
        XCTAssertEqual(store.entries[0].typedCount, 1)
        XCTAssertNotNil(store.entries[0].lastTypedAt)
    }

    func testRecordTypedNavigationIncrementsTypedCount() {
        let store = makeStore()
        store.recordTypedNavigation(url: url("https://typed.com"))
        store.recordTypedNavigation(url: url("https://typed.com"))
        XCTAssertEqual(store.entries[0].visitCount, 2)
        XCTAssertEqual(store.entries[0].typedCount, 2)
    }

    func testMixedVisitsAndTyped() {
        let store = makeStore()
        store.recordVisit(url: url("https://mix.com"), title: "Mix")
        store.recordTypedNavigation(url: url("https://mix.com"))
        store.recordVisit(url: url("https://mix.com"), title: nil)
        XCTAssertEqual(store.entries[0].visitCount, 3)
        XCTAssertEqual(store.entries[0].typedCount, 1)
    }

    // MARK: - Deduplication & Sorting

    func testEntriesSortedByVisitDateNewestFirst() {
        let store = makeStore()
        store.recordVisit(url: url("https://old.com"), title: "Old")
        Thread.sleep(forTimeInterval: 0.01)
        store.recordVisit(url: url("https://new.com"), title: "New")
        XCTAssertEqual(store.entries[0].url, url("https://new.com"))
        XCTAssertEqual(store.entries[1].url, url("https://old.com"))
    }

    func testMaxEntriesTrimming() {
        let store = makeStore()
        for i in 0..<(BrowserHistoryStore.maxEntries + 100) {
            store.recordVisit(url: url("https://site\(i).com"), title: nil)
        }
        XCTAssertEqual(store.entries.count, BrowserHistoryStore.maxEntries)
    }

    // MARK: - Suggestion Scoring

    func testExactURLMatchScoresHighest() {
        let store = makeStore()
        let entry = HistoryEntry(url: url("https://example.com"), title: "Example",
                                  visitCount: 1, typedCount: 0)
        let score = store.suggestionScore(query: "example.com", entry: entry)
        XCTAssertNotNil(score)
        // URL sans scheme == query should hit the 1200 bonus
        XCTAssertGreaterThan(score!, 1200)
    }

    func testHostPrefixMatchScoresHigherThanContains() {
        let store = makeStore()
        let now = Date()
        let prefixEntry = HistoryEntry(url: url("https://github.com/user"), title: "GitHub",
                                        visitDate: now, visitCount: 1, typedCount: 0)
        let containsEntry = HistoryEntry(url: url("https://my-github-page.com"), title: "My Page",
                                          visitDate: now, visitCount: 1, typedCount: 0)
        let prefixScore = store.suggestionScore(query: "github", entry: prefixEntry, now: now)
        let containsScore = store.suggestionScore(query: "github", entry: containsEntry, now: now)
        XCTAssertNotNil(prefixScore)
        XCTAssertNotNil(containsScore)
        XCTAssertGreaterThan(prefixScore!, containsScore!)
    }

    func testNonMatchReturnsNil() {
        let store = makeStore()
        let entry = HistoryEntry(url: url("https://example.com"), title: "Example")
        let score = store.suggestionScore(query: "zzzznotfound", entry: entry)
        XCTAssertNil(score)
    }

    func testSingleCharQueryRequiresStrongPrefix() {
        let store = makeStore()
        // "e" should match "example.com" (host prefix)
        let matching = HistoryEntry(url: url("https://example.com"), title: "Example")
        XCTAssertNotNil(store.suggestionScore(query: "e", entry: matching))

        // "z" should NOT match "example.com"
        let nonMatching = HistoryEntry(url: url("https://example.com"), title: "Example")
        XCTAssertNil(store.suggestionScore(query: "z", entry: nonMatching))
    }

    // MARK: - Frecency

    func testTypedNavigationBoostsFrecency() {
        let store = makeStore()
        let now = Date()
        let typedEntry = HistoryEntry(url: url("https://typed.com"), title: "Typed",
                                       visitDate: now, visitCount: 5, typedCount: 5, lastTypedAt: now)
        let clickedEntry = HistoryEntry(url: url("https://clicked.com"), title: "Clicked",
                                         visitDate: now, visitCount: 5, typedCount: 0)
        let typedScore = store.suggestionScore(query: "com", entry: typedEntry, now: now)
        let clickedScore = store.suggestionScore(query: "com", entry: clickedEntry, now: now)
        XCTAssertNotNil(typedScore)
        XCTAssertNotNil(clickedScore)
        XCTAssertGreaterThan(typedScore!, clickedScore!)
    }

    func testRecencyDecaysOverTime() {
        let store = makeStore()
        let now = Date()
        let recentEntry = HistoryEntry(url: url("https://recent.com"), title: "Recent",
                                        visitDate: now, visitCount: 1, typedCount: 0)
        let oldEntry = HistoryEntry(url: url("https://old.com"), title: "Old",
                                     visitDate: now.addingTimeInterval(-14 * 24 * 3600), // 14 days ago
                                     visitCount: 1, typedCount: 0)
        let recentScore = store.suggestionScore(query: "com", entry: recentEntry, now: now)
        let oldScore = store.suggestionScore(query: "com", entry: oldEntry, now: now)
        XCTAssertNotNil(recentScore)
        XCTAssertNotNil(oldScore)
        XCTAssertGreaterThan(recentScore!, oldScore!)
    }

    func testHighVisitCountBoostsFrecency() {
        let store = makeStore()
        let now = Date()
        let frequentEntry = HistoryEntry(url: url("https://frequent.com"), title: "Frequent",
                                          visitDate: now, visitCount: 100, typedCount: 0)
        let rareEntry = HistoryEntry(url: url("https://rare.com"), title: "Rare",
                                      visitDate: now, visitCount: 1, typedCount: 0)
        let frequentScore = store.suggestionScore(query: "com", entry: frequentEntry, now: now)
        let rareScore = store.suggestionScore(query: "com", entry: rareEntry, now: now)
        XCTAssertNotNil(frequentScore)
        XCTAssertNotNil(rareScore)
        XCTAssertGreaterThan(frequentScore!, rareScore!)
    }

    // MARK: - search()

    func testSearchReturnsMatchesSortedByScore() {
        let store = makeStore()
        store.recordVisit(url: url("https://github.com"), title: "GitHub")
        store.recordVisit(url: url("https://my-github-mirror.org"), title: "Mirror")
        // Record typed navigation so github.com scores higher
        store.recordTypedNavigation(url: url("https://github.com"))

        let results = store.search(query: "github")
        XCTAssertGreaterThanOrEqual(results.count, 1)
        XCTAssertEqual(results[0].url, url("https://github.com"))
    }

    func testSearchLimitRespected() {
        let store = makeStore()
        for i in 0..<20 {
            store.recordVisit(url: url("https://site\(i).example.com"), title: "Site \(i)")
        }
        let results = store.search(query: "example", limit: 5)
        XCTAssertEqual(results.count, 5)
    }

    func testSearchNoMatchReturnsEmpty() {
        let store = makeStore()
        store.recordVisit(url: url("https://example.com"), title: "Example")
        let results = store.search(query: "zzzznotfound")
        XCTAssertTrue(results.isEmpty)
    }

    // MARK: - recentSuggestions

    func testRecentSuggestionsPrioritizesTyped() {
        let store = makeStore()
        store.recordVisit(url: url("https://visited.com"), title: "Visited")
        store.recordTypedNavigation(url: url("https://typed.com"))

        let recent = store.recentSuggestions(limit: 10)
        XCTAssertGreaterThanOrEqual(recent.count, 2)
        XCTAssertEqual(recent[0].url, url("https://typed.com"))
    }

    func testEmptyQuerySearchReturnsRecentSuggestions() {
        let store = makeStore()
        store.recordTypedNavigation(url: url("https://typed.com"))
        store.recordVisit(url: url("https://visited.com"), title: "V")

        let results = store.search(query: "")
        XCTAssertFalse(results.isEmpty)
        XCTAssertEqual(results[0].url, url("https://typed.com"))
    }

    // MARK: - Multi-word Query Tokenization

    func testMultiWordQueryMatchesTokens() {
        let store = makeStore()
        let entry = HistoryEntry(url: url("https://github.com/user/repo"), title: "My Cool Repo")
        // "cool repo" should match via tokens against the title
        let score = store.suggestionScore(query: "cool repo", entry: entry)
        XCTAssertNotNil(score)
    }

    func testTokensMatchAcrossURLAndTitle() {
        let store = makeStore()
        let entry = HistoryEntry(url: url("https://docs.swift.org/guide"), title: "Swift Guide")
        // "swift guide" — "swift" in host and title, "guide" in path and title
        let score = store.suggestionScore(query: "swift guide", entry: entry)
        XCTAssertNotNil(score)
    }

    // MARK: - Tie-breaking

    func testTieBreakingByVisitDateThenCount() {
        let store = makeStore()
        let now = Date()
        // Two entries with identical match profiles but different visit dates
        store.recordVisit(url: url("https://alpha.example.com"), title: "Alpha")
        Thread.sleep(forTimeInterval: 0.01)
        store.recordVisit(url: url("https://bravo.example.com"), title: "Bravo")

        let results = store.search(query: "example.com")
        // Bravo visited more recently, should rank first (with similar scores)
        XCTAssertGreaterThanOrEqual(results.count, 2)
        XCTAssertEqual(results[0].url, url("https://bravo.example.com"))
    }
}
