import XCTest
@testable import Namu

final class BrowserImportTests: XCTestCase {

    // MARK: - BrowserType

    func testAllBrowserTypesExist() {
        let types = BrowserImport.BrowserType.allCases
        XCTAssertTrue(types.contains(.safari))
        XCTAssertTrue(types.contains(.chrome))
        XCTAssertTrue(types.contains(.firefox))
        XCTAssertTrue(types.contains(.arc))
        XCTAssertTrue(types.contains(.edge))
        XCTAssertTrue(types.contains(.brave))
    }

    func testBrowserTypeRawValues() {
        XCTAssertEqual(BrowserImport.BrowserType.safari.rawValue, "Safari")
        XCTAssertEqual(BrowserImport.BrowserType.chrome.rawValue, "Chrome")
        XCTAssertEqual(BrowserImport.BrowserType.firefox.rawValue, "Firefox")
    }

    // MARK: - HistoryEntry

    func testHistoryEntryHasUniqueIDs() {
        let entry1 = BrowserImport.HistoryEntry(
            browser: .chrome,
            profile: nil,
            url: URL(string: "https://example.com")!,
            title: "Example",
            visitDate: Date()
        )
        let entry2 = BrowserImport.HistoryEntry(
            browser: .chrome,
            profile: nil,
            url: URL(string: "https://example.com")!,
            title: "Example",
            visitDate: Date()
        )
        XCTAssertNotEqual(entry1.id, entry2.id)
    }

    // MARK: - Bookmark

    func testBookmarkWithFolder() {
        let bookmark = BrowserImport.Bookmark(
            browser: .safari,
            url: URL(string: "https://apple.com")!,
            title: "Apple",
            folder: "Tech"
        )
        XCTAssertEqual(bookmark.folder, "Tech")
        XCTAssertEqual(bookmark.title, "Apple")
        XCTAssertEqual(bookmark.browser, .safari)
    }

    func testBookmarkWithoutFolder() {
        let bookmark = BrowserImport.Bookmark(
            browser: .chrome,
            url: URL(string: "https://google.com")!,
            title: "Google",
            folder: nil
        )
        XCTAssertNil(bookmark.folder)
    }

    // MARK: - installedBrowsers (smoke test)

    func testInstalledBrowsersReturnsSubset() {
        // Just verify it doesn't crash and returns a subset of all cases
        let installed = BrowserImport.installedBrowsers()
        for browser in installed {
            XCTAssertTrue(BrowserImport.BrowserType.allCases.contains(browser))
        }
    }

    // MARK: - history / bookmarks (live, non-crashing smoke tests)

    func testHistoryDoesNotCrash() {
        // This reads from disk — may return empty on CI but should not crash
        let entries = BrowserImport.history(limit: 5)
        // Each entry should have a valid URL
        for entry in entries {
            XCTAssertFalse(entry.url.absoluteString.isEmpty)
        }
    }

    func testBookmarksDoesNotCrash() {
        let bookmarks = BrowserImport.bookmarks()
        for bookmark in bookmarks {
            XCTAssertFalse(bookmark.url.absoluteString.isEmpty)
        }
    }

    func testHistoryLimitRespected() {
        let limit = 3
        let entries = BrowserImport.history(limit: limit)
        XCTAssertLessThanOrEqual(entries.count, limit)
    }

    func testHistorySortedNewestFirst() {
        let entries = BrowserImport.history(limit: 50)
        for i in 1..<entries.count {
            XCTAssertGreaterThanOrEqual(entries[i - 1].visitDate, entries[i].visitDate)
        }
    }
}
