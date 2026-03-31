import Foundation
import SQLite3

// MARK: - BrowserImport

/// Detects installed browsers and reads their history/bookmarks from SQLite databases.
/// Copies databases to a temp directory before reading to avoid file-lock issues.
struct BrowserImport {

    // MARK: - Types

    enum BrowserType: String, CaseIterable {
        // Tier 1
        case safari              = "Safari"
        case chrome              = "Chrome"
        case firefox             = "Firefox"
        case arc                 = "Arc"
        case edge                = "Edge"
        case brave               = "Brave"
        // Tier 2
        case zenBrowser          = "Zen Browser"
        case vivaldi             = "Vivaldi"
        case opera               = "Opera"
        case operaGX             = "Opera GX"
        case orion               = "Orion"
        // Tier 3
        case perplexityComet     = "Perplexity Comet"
        case floorp              = "Floorp"
        case waterfox            = "Waterfox"
        case sigmaOS             = "SigmaOS"
        case sidekick            = "Sidekick"
        case helium              = "Helium"
        case chromium            = "Chromium"
        case ungoogledChromium   = "Ungoogled Chromium"
        // Tier 4
        case dia                 = "Dia"
        case atlas               = "Atlas"
        case ladybird            = "Ladybird"
        case thorium             = "Thorium"
    }

    /// Represents a single browser profile (Chromium User Data subdirectory or Firefox profile).
    struct BrowserProfile {
        let browser: BrowserType
        /// Human-readable profile directory name (e.g. "Default", "Profile 1", "xyz.default-release")
        let name: String
        /// Full path to the profile's History (Chromium) or places.sqlite (Firefox) database
        let historyPath: URL
    }

    struct HistoryEntry: Identifiable {
        let id: UUID = UUID()
        let browser: BrowserType
        let profile: String?
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
        BrowserType.allCases.filter { !profiles(for: $0).isEmpty }
    }

    // MARK: - Multi-profile discovery

    /// Returns all discoverable profiles for the given browser.
    static func profiles(for browser: BrowserType) -> [BrowserProfile] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let lib  = home.appendingPathComponent("Library")

        switch browserFamily(browser) {
        case .safari:
            let p = lib.appendingPathComponent("Safari")
            let historyDB = p.appendingPathComponent("History.db")
            guard FileManager.default.fileExists(atPath: historyDB.path) else { return [] }
            return [BrowserProfile(browser: browser, name: "Default", historyPath: historyDB)]

        case .chromium:
            guard let userDataDir = chromiumUserDataDir(browser: browser, lib: lib) else { return [] }
            return chromiumProfiles(browser: browser, userDataDir: userDataDir)

        case .firefox:
            return firefoxProfiles(browser: browser, lib: lib)
        }
    }

    // MARK: - History

    /// Read visit history for one or all browsers, sorted newest-first.
    /// Pass a specific `profile` name to restrict to one profile per browser.
    static func history(
        from browsers: [BrowserType]? = nil,
        profile: String? = nil,
        limit: Int = 200
    ) -> [HistoryEntry] {
        let targets = browsers ?? installedBrowsers()
        return targets.flatMap { readHistory(browser: $0, profile: profile, limit: limit) }
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

    private static func readHistory(browser: BrowserType, profile: String?, limit: Int) -> [HistoryEntry] {
        switch browserFamily(browser) {
        case .safari:
            return safariHistory(browser: browser, limit: limit)
        case .chromium:
            let allProfiles = profiles(for: browser)
            let filtered = profile.map { name in allProfiles.filter { $0.name == name } } ?? allProfiles
            return filtered.flatMap { chromiumHistoryFromProfile($0, limit: limit) }
        case .firefox:
            let allProfiles = profiles(for: browser)
            let filtered = profile.map { name in allProfiles.filter { $0.name == name } } ?? allProfiles
            return filtered.flatMap { firefoxHistoryFromProfile($0, limit: limit) }
        }
    }

    private static func readBookmarks(browser: BrowserType) -> [Bookmark] {
        switch browser {
        case .safari:   return safariBookmarks()
        case .chrome, .arc, .edge, .brave, .vivaldi, .opera, .operaGX,
             .sigmaOS, .sidekick, .helium, .chromium, .ungoogledChromium,
             .zenBrowser, .perplexityComet, .dia, .atlas, .thorium:
            return chromiumBookmarks(browser: browser)
        case .firefox, .floorp, .waterfox:
            return firefoxBookmarks(browser: browser)
        case .orion, .ladybird:
            return [] // WebKit/custom internals; no accessible bookmarks file
        }
    }

    // MARK: - Browser family classification

    private enum BrowserFamily { case safari, chromium, firefox }

    private static func browserFamily(_ browser: BrowserType) -> BrowserFamily {
        switch browser {
        case .safari, .orion, .ladybird:
            return .safari
        case .chrome, .arc, .edge, .brave, .vivaldi, .opera, .operaGX,
             .sigmaOS, .sidekick, .helium, .chromium, .ungoogledChromium,
             .zenBrowser, .perplexityComet, .dia, .atlas, .thorium:
            return .chromium
        case .firefox, .floorp, .waterfox:
            return .firefox
        }
    }

    // MARK: - Chromium User Data directory resolution

    private static func chromiumUserDataDir(browser: BrowserType, lib: URL) -> URL? {
        let candidates: [String]
        switch browser {
        case .chrome:
            candidates = ["Application Support/Google/Chrome"]
        case .arc:
            candidates = ["Application Support/Arc/User Data"]
        case .edge:
            candidates = ["Application Support/Microsoft Edge"]
        case .brave:
            candidates = ["Application Support/BraveSoftware/Brave-Browser"]
        case .vivaldi:
            candidates = ["Application Support/Vivaldi"]
        case .opera:
            candidates = [
                "Application Support/com.operasoftware.Opera",
                "Application Support/Opera",
            ]
        case .operaGX:
            candidates = [
                "Application Support/com.operasoftware.OperaGX",
                "Application Support/Opera GX Stable",
            ]
        case .zenBrowser:
            // Zen is Firefox-based; handled by firefoxProfiles
            return nil
        case .perplexityComet:
            candidates = ["Application Support/Comet"]
        case .sigmaOS:
            candidates = ["Application Support/SigmaOS"]
        case .sidekick:
            candidates = ["Application Support/Sidekick"]
        case .helium:
            candidates = [
                "Application Support/net.imput.helium",
                "Application Support/Helium",
            ]
        case .chromium:
            candidates = ["Application Support/Chromium"]
        case .ungoogledChromium:
            candidates = ["Application Support/Chromium"]
        case .dia:
            candidates = ["Application Support/Dia"]
        case .atlas:
            candidates = [
                "Application Support/Atlas Browser",
                "Application Support/Atlas",
            ]
        case .thorium:
            candidates = ["Application Support/Thorium"]
        default:
            return nil
        }

        let fm = FileManager.default
        for rel in candidates {
            let url = lib.appendingPathComponent(rel)
            if fm.fileExists(atPath: url.path) { return url }
        }
        return nil
    }

    // MARK: - Chromium multi-profile discovery

    private static func chromiumProfiles(browser: BrowserType, userDataDir: URL) -> [BrowserProfile] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: userDataDir,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var result: [BrowserProfile] = []
        for entry in entries {
            let name = entry.lastPathComponent
            let isProfileDir = (name == "Default" || name.hasPrefix("Profile "))
            guard isProfileDir else { continue }
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: entry.path, isDirectory: &isDir), isDir.boolValue else { continue }
            let historyPath = entry.appendingPathComponent("History")
            guard fm.fileExists(atPath: historyPath.path) else { continue }
            result.append(BrowserProfile(browser: browser, name: name, historyPath: historyPath))
        }
        return result
    }

    // MARK: - Firefox profile discovery

    private static func firefoxAppSupportDir(browser: BrowserType) -> String {
        switch browser {
        case .firefox:   return "Firefox"
        case .floorp:    return "Floorp"
        case .waterfox:  return "Waterfox"
        case .zenBrowser: return "zen"
        default:         return browser.rawValue
        }
    }

    private static func firefoxProfiles(browser: BrowserType, lib: URL) -> [BrowserProfile] {
        let appSupportName = firefoxAppSupportDir(browser: browser)
        let candidates = [
            lib.appendingPathComponent("Application Support/\(appSupportName)/Profiles"),
            lib.appendingPathComponent("Application Support/\(appSupportName.lowercased())/Profiles"),
        ]
        let fm = FileManager.default
        for profilesBase in candidates {
            guard let entries = try? fm.contentsOfDirectory(
                at: profilesBase,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) else { continue }
            let profiles = entries.compactMap { entry -> BrowserProfile? in
                let historyPath = entry.appendingPathComponent("places.sqlite")
                guard fm.fileExists(atPath: historyPath.path) else { return nil }
                return BrowserProfile(browser: browser, name: entry.lastPathComponent, historyPath: historyPath)
            }
            if !profiles.isEmpty { return profiles }
        }
        return []
    }

    // MARK: - Safari

    private static func safariHistory(browser: BrowserType, limit: Int) -> [HistoryEntry] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let dbPath = home.appendingPathComponent("Library/Safari/History.db")
        guard FileManager.default.fileExists(atPath: dbPath.path),
              let tmpPath = copyToTemp(source: dbPath) else { return [] }
        defer { try? FileManager.default.removeItem(at: tmpPath) }

        var entries: [HistoryEntry] = []
        var db: OpaquePointer?
        guard sqlite3_open_v2(tmpPath.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_close(db) }

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

        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let rawURL = sqlite3_column_text(stmt, 0).map({ String(cString: $0) }),
                  let url = URL(string: rawURL) else { continue }
            let title     = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? rawURL
            let macTime   = sqlite3_column_double(stmt, 2)
            let visitDate = Date(timeIntervalSinceReferenceDate: macTime)
            entries.append(HistoryEntry(browser: browser, profile: nil, url: url, title: title, visitDate: visitDate))
        }
        return entries
    }

    private static func safariBookmarks() -> [Bookmark] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let plistPath = home.appendingPathComponent("Library/Safari/Bookmarks.plist")
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

    // MARK: - Chromium-based browsers

    private static func chromiumHistoryFromProfile(_ profile: BrowserProfile, limit: Int) -> [HistoryEntry] {
        guard let tmpPath = copyToTemp(source: profile.historyPath) else { return [] }
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

        let chromiumEpochOffset: TimeInterval = 11644473600.0
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let rawURL = sqlite3_column_text(stmt, 0).map({ String(cString: $0) }),
                  let url = URL(string: rawURL) else { continue }
            let title        = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? rawURL
            let chromiumTime = sqlite3_column_int64(stmt, 2)
            let unixSeconds  = Double(chromiumTime) / 1_000_000.0 - chromiumEpochOffset
            let visitDate    = Date(timeIntervalSince1970: unixSeconds)
            entries.append(HistoryEntry(
                browser: profile.browser,
                profile: profile.name,
                url: url,
                title: title,
                visitDate: visitDate
            ))
        }
        return entries
    }

    private static func chromiumBookmarks(browser: BrowserType) -> [Bookmark] {
        let allProfiles = profiles(for: browser)
        guard let firstProfile = allProfiles.first else { return [] }
        // Bookmarks file lives next to History in the profile dir
        let jsonPath = firstProfile.historyPath.deletingLastPathComponent()
            .appendingPathComponent("Bookmarks")
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

    // MARK: - Firefox-based browsers

    private static func firefoxHistoryFromProfile(_ profile: BrowserProfile, limit: Int) -> [HistoryEntry] {
        guard let tmpPath = copyToTemp(source: profile.historyPath) else { return [] }
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

        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let rawURL = sqlite3_column_text(stmt, 0).map({ String(cString: $0) }),
                  let url = URL(string: rawURL) else { continue }
            let title     = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? rawURL
            let microtime = sqlite3_column_int64(stmt, 2)
            let visitDate = Date(timeIntervalSince1970: Double(microtime) / 1_000_000.0)
            entries.append(HistoryEntry(
                browser: profile.browser,
                profile: profile.name,
                url: url,
                title: title,
                visitDate: visitDate
            ))
        }
        return entries
    }

    private static func firefoxBookmarks(browser: BrowserType) -> [Bookmark] {
        let allProfiles = profiles(for: browser)
        guard let firstProfile = allProfiles.first else { return [] }
        guard let tmpPath = copyToTemp(source: firstProfile.historyPath) else { return [] }
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
            bookmarks.append(Bookmark(browser: browser, url: url, title: title, folder: folder))
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
