import Foundation
import SQLite3

// MARK: - BrowserImport

/// Detects installed browsers and reads their history/bookmarks from SQLite databases.
/// Copies databases to a temp directory before reading to avoid file-lock issues.
struct BrowserImport {

    // MARK: - Types

    enum BrowserType: String, CaseIterable {
        case safari   = "Safari"
        case chrome   = "Chrome"
        case firefox  = "Firefox"
        case arc      = "Arc"
        case edge     = "Edge"
        case brave    = "Brave"
    }

    struct HistoryEntry: Identifiable {
        let id: UUID = UUID()
        let browser: BrowserType
        let url: URL
        let title: String
        let visitDate: Date
    }

    struct Bookmark: Identifiable {
        let id: UUID = UUID()
        let browser: BrowserType
        let url: URL
        let title: String
        let folder: String?
    }

    // MARK: - Detection

    /// Returns which browsers are installed (their profile dirs exist).
    static func installedBrowsers() -> [BrowserType] {
        BrowserType.allCases.filter { profileDirectory(for: $0) != nil }
    }

    // MARK: - History

    /// Read visit history for one or all browsers, sorted newest-first.
    static func history(from browsers: [BrowserType]? = nil, limit: Int = 200) -> [HistoryEntry] {
        let targets = browsers ?? installedBrowsers()
        return targets.flatMap { readHistory(browser: $0, limit: limit) }
                      .sorted { $0.visitDate > $1.visitDate }
                      .prefix(limit)
                      .map { $0 }
    }

    // MARK: - Bookmarks

    /// Read bookmarks for one or all browsers.
    static func bookmarks(from browsers: [BrowserType]? = nil) -> [Bookmark] {
        let targets = browsers ?? installedBrowsers()
        return targets.flatMap { readBookmarks(browser: $0) }
    }

    // MARK: - Private: per-browser readers

    private static func readHistory(browser: BrowserType, limit: Int) -> [HistoryEntry] {
        switch browser {
        case .safari:   return safariHistory(limit: limit)
        case .chrome:   return chromiumHistory(browser: .chrome,  limit: limit)
        case .arc:      return chromiumHistory(browser: .arc,     limit: limit)
        case .edge:     return chromiumHistory(browser: .edge,    limit: limit)
        case .brave:    return chromiumHistory(browser: .brave,   limit: limit)
        case .firefox:  return firefoxHistory(limit: limit)
        }
    }

    private static func readBookmarks(browser: BrowserType) -> [Bookmark] {
        switch browser {
        case .safari:   return safariBookmarks()
        case .chrome:   return chromiumBookmarks(browser: .chrome)
        case .arc:      return chromiumBookmarks(browser: .arc)
        case .edge:     return chromiumBookmarks(browser: .edge)
        case .brave:    return chromiumBookmarks(browser: .brave)
        case .firefox:  return firefoxBookmarks()
        }
    }

    // MARK: - Profile directory resolution

    private static func profileDirectory(for browser: BrowserType) -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let lib  = home.appendingPathComponent("Library")

        switch browser {
        case .safari:
            let p = lib.appendingPathComponent("Safari")
            return FileManager.default.fileExists(atPath: p.path) ? p : nil

        case .chrome:
            let p = lib.appendingPathComponent("Application Support/Google/Chrome/Default")
            return FileManager.default.fileExists(atPath: p.path) ? p : nil

        case .arc:
            let p = lib.appendingPathComponent("Application Support/Arc/User Data/Default")
            return FileManager.default.fileExists(atPath: p.path) ? p : nil

        case .edge:
            let p = lib.appendingPathComponent("Application Support/Microsoft Edge/Default")
            return FileManager.default.fileExists(atPath: p.path) ? p : nil

        case .brave:
            let p = lib.appendingPathComponent("Application Support/BraveSoftware/Brave-Browser/Default")
            return FileManager.default.fileExists(atPath: p.path) ? p : nil

        case .firefox:
            let profilesBase = lib.appendingPathComponent("Application Support/Firefox/Profiles")
            guard let entries = try? FileManager.default.contentsOfDirectory(
                at: profilesBase,
                includingPropertiesForKeys: nil
            ) else { return nil }
            // Use the first profile that contains a places.sqlite
            return entries.first { FileManager.default.fileExists(
                atPath: $0.appendingPathComponent("places.sqlite").path
            ) }
        }
    }

    // MARK: - Safari (plist-based history, no SQLite)

    private static func safariHistory(limit: Int) -> [HistoryEntry] {
        guard let profileDir = profileDirectory(for: .safari) else { return [] }
        let dbPath = profileDir.appendingPathComponent("History.db")
        guard FileManager.default.fileExists(atPath: dbPath.path),
              let tmpPath = copyToTemp(source: dbPath) else { return [] }
        defer { try? FileManager.default.removeItem(at: tmpPath) }

        var entries: [HistoryEntry] = []
        var db: OpaquePointer?
        guard sqlite3_open_v2(tmpPath.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_close(db) }

        // Safari History.db uses history_visits joined with history_items
        let sql = """
            SELECT hi.url, hv.title, hv.visit_time
            FROM history_visits hv
            JOIN history_items hi ON hv.history_item = hi.id
            ORDER BY hv.visit_time DESC
            LIMIT ?;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int(stmt, 1, Int32(limit))

        // Safari stores time as Mac absolute time (seconds since 2001-01-01)
        let epoch = Date(timeIntervalSinceReferenceDate: 0)
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let rawURL = sqlite3_column_text(stmt, 0).map({ String(cString: $0) }),
                  let url = URL(string: rawURL) else { continue }
            let title     = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? rawURL
            let macTime   = sqlite3_column_double(stmt, 2)
            let visitDate = Date(timeIntervalSinceReferenceDate: macTime)
            _ = epoch // silence unused warning
            entries.append(HistoryEntry(browser: .safari, url: url, title: title, visitDate: visitDate))
        }
        return entries
    }

    private static func safariBookmarks() -> [Bookmark] {
        guard let profileDir = profileDirectory(for: .safari) else { return [] }
        let plistPath = profileDir.appendingPathComponent("Bookmarks.plist")
        guard let data = try? Data(contentsOf: plistPath),
              let root = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return [] }

        var bookmarks: [Bookmark] = []
        traverseSafariBookmarks(root, folder: nil, into: &bookmarks)
        return bookmarks
    }

    private static func traverseSafariBookmarks(
        _ node: [String: Any],
        folder: String?,
        into bookmarks: inout [Bookmark]
    ) {
        let type = node["WebBookmarkType"] as? String
        if type == "WebBookmarkTypeLeaf" {
            guard let urlString = node["URLString"] as? String,
                  let url = URL(string: urlString),
                  let uriDict = node["URIDictionary"] as? [String: Any],
                  let title = uriDict["title"] as? String
            else { return }
            bookmarks.append(Bookmark(browser: .safari, url: url, title: title, folder: folder))
        } else if type == "WebBookmarkTypeList" {
            let folderTitle = (node["Title"] as? String) ?? folder
            let children = node["Children"] as? [[String: Any]] ?? []
            for child in children {
                traverseSafariBookmarks(child, folder: folderTitle, into: &bookmarks)
            }
        }
    }

    // MARK: - Chromium-based browsers (Chrome, Arc, Edge, Brave)

    private static func chromiumHistory(browser: BrowserType, limit: Int) -> [HistoryEntry] {
        guard let profileDir = profileDirectory(for: browser) else { return [] }
        let dbPath = profileDir.appendingPathComponent("History")
        guard FileManager.default.fileExists(atPath: dbPath.path),
              let tmpPath = copyToTemp(source: dbPath) else { return [] }
        defer { try? FileManager.default.removeItem(at: tmpPath) }

        var entries: [HistoryEntry] = []
        var db: OpaquePointer?
        guard sqlite3_open_v2(tmpPath.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_close(db) }

        let sql = """
            SELECT u.url, u.title, v.visit_time
            FROM visits v
            JOIN urls u ON v.url = u.id
            ORDER BY v.visit_time DESC
            LIMIT ?;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int(stmt, 1, Int32(limit))

        // Chromium stores time as microseconds since 1601-01-01
        let chromiumEpochOffset: TimeInterval = 11644473600.0
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let rawURL = sqlite3_column_text(stmt, 0).map({ String(cString: $0) }),
                  let url = URL(string: rawURL) else { continue }
            let title       = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? rawURL
            let chromiumTime = sqlite3_column_int64(stmt, 2)
            let unixSeconds  = Double(chromiumTime) / 1_000_000.0 - chromiumEpochOffset
            let visitDate    = Date(timeIntervalSince1970: unixSeconds)
            entries.append(HistoryEntry(browser: browser, url: url, title: title, visitDate: visitDate))
        }
        return entries
    }

    private static func chromiumBookmarks(browser: BrowserType) -> [Bookmark] {
        guard let profileDir = profileDirectory(for: browser) else { return [] }
        let jsonPath = profileDir.appendingPathComponent("Bookmarks")
        guard let data = try? Data(contentsOf: jsonPath),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rootsDict = root["roots"] as? [String: Any]
        else { return [] }

        var bookmarks: [Bookmark] = []
        for (folderKey, node) in rootsDict {
            if let nodeDict = node as? [String: Any] {
                traverseChromiumBookmarks(nodeDict, folder: folderKey, browser: browser, into: &bookmarks)
            }
        }
        return bookmarks
    }

    private static func traverseChromiumBookmarks(
        _ node: [String: Any],
        folder: String?,
        browser: BrowserType,
        into bookmarks: inout [Bookmark]
    ) {
        let type = node["type"] as? String
        if type == "url" {
            guard let urlString = node["url"] as? String,
                  let url = URL(string: urlString),
                  let title = node["name"] as? String
            else { return }
            bookmarks.append(Bookmark(browser: browser, url: url, title: title, folder: folder))
        } else if type == "folder" {
            let folderTitle = (node["name"] as? String) ?? folder
            let children    = node["children"] as? [[String: Any]] ?? []
            for child in children {
                traverseChromiumBookmarks(child, folder: folderTitle, browser: browser, into: &bookmarks)
            }
        }
    }

    // MARK: - Firefox

    private static func firefoxHistory(limit: Int) -> [HistoryEntry] {
        guard let profileDir = profileDirectory(for: .firefox) else { return [] }
        let dbPath = profileDir.appendingPathComponent("places.sqlite")
        guard FileManager.default.fileExists(atPath: dbPath.path),
              let tmpPath = copyToTemp(source: dbPath) else { return [] }
        defer { try? FileManager.default.removeItem(at: tmpPath) }

        var entries: [HistoryEntry] = []
        var db: OpaquePointer?
        guard sqlite3_open_v2(tmpPath.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_close(db) }

        let sql = """
            SELECT p.url, p.title, h.visit_date
            FROM moz_historyvisits h
            JOIN moz_places p ON h.place_id = p.id
            ORDER BY h.visit_date DESC
            LIMIT ?;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int(stmt, 1, Int32(limit))

        // Firefox stores time as microseconds since Unix epoch
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let rawURL = sqlite3_column_text(stmt, 0).map({ String(cString: $0) }),
                  let url = URL(string: rawURL) else { continue }
            let title     = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? rawURL
            let microtime = sqlite3_column_int64(stmt, 2)
            let visitDate = Date(timeIntervalSince1970: Double(microtime) / 1_000_000.0)
            entries.append(HistoryEntry(browser: .firefox, url: url, title: title, visitDate: visitDate))
        }
        return entries
    }

    private static func firefoxBookmarks() -> [Bookmark] {
        guard let profileDir = profileDirectory(for: .firefox) else { return [] }
        let dbPath = profileDir.appendingPathComponent("places.sqlite")
        guard FileManager.default.fileExists(atPath: dbPath.path),
              let tmpPath = copyToTemp(source: dbPath) else { return [] }
        defer { try? FileManager.default.removeItem(at: tmpPath) }

        var bookmarks: [Bookmark] = []
        var db: OpaquePointer?
        guard sqlite3_open_v2(tmpPath.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_close(db) }

        let sql = """
            SELECT p.url, b.title, parent.title as folder
            FROM moz_bookmarks b
            JOIN moz_places p ON b.fk = p.id
            LEFT JOIN moz_bookmarks parent ON b.parent = parent.id
            WHERE b.type = 1
            ORDER BY b.dateAdded DESC;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }

        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let rawURL = sqlite3_column_text(stmt, 0).map({ String(cString: $0) }),
                  let url = URL(string: rawURL) else { continue }
            let title  = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? rawURL
            let folder = sqlite3_column_text(stmt, 2).map { String(cString: $0) }
            bookmarks.append(Bookmark(browser: .firefox, url: url, title: title, folder: folder))
        }
        return bookmarks
    }

    // MARK: - Temp copy helper

    /// Copy `source` to a uniquely named file in the system temp directory.
    /// Returns the temp URL on success, nil on failure.
    private static func copyToTemp(source: URL) -> URL? {
        let dest = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("namu_browser_\(UUID().uuidString)_\(source.lastPathComponent)")
        do {
            try FileManager.default.copyItem(at: source, to: dest)
            return dest
        } catch {
            return nil
        }
    }
}
