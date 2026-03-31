import Foundation

// MARK: - BrowserSearchEngine

enum BrowserSearchEngine: String, CaseIterable, Codable, Identifiable {
    case google
    case duckduckgo
    case bing
    case kagi
    case startpage

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .google:     return "Google"
        case .duckduckgo: return "DuckDuckGo"
        case .bing:       return "Bing"
        case .kagi:       return "Kagi"
        case .startpage:  return "Startpage"
        }
    }

    /// URL template where `%s` is replaced with the percent-encoded query string.
    var searchURLTemplate: String {
        switch self {
        case .google:     return "https://www.google.com/search?q=%s"
        case .duckduckgo: return "https://duckduckgo.com/?q=%s"
        case .bing:       return "https://www.bing.com/search?q=%s"
        case .kagi:       return "https://kagi.com/search?q=%s"
        case .startpage:  return "https://www.startpage.com/search?q=%s"
        }
    }

    /// URL template for the search engine's suggest API.
    /// `%s` is replaced with the percent-encoded query. nil = no suggest API available.
    var suggestURLTemplate: String? {
        switch self {
        case .google:     return "http://suggestqueries.google.com/complete/search?output=firefox&q=%s"
        case .duckduckgo: return "https://duckduckgo.com/ac/?q=%s&type=list"
        case .bing:       return "https://api.bing.com/osjson.aspx?query=%s"
        case .kagi:       return nil
        case .startpage:  return nil
        }
    }

    /// Build a suggest URL for the given query, returning nil if not supported or encoding fails.
    func suggestURL(for query: String) -> URL? {
        guard let template = suggestURLTemplate,
              let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else {
            return nil
        }
        return URL(string: template.replacingOccurrences(of: "%s", with: encoded))
    }

    /// Build a search URL for the given query, returning nil if encoding fails.
    func searchURL(for query: String) -> URL? {
        guard let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else {
            return nil
        }
        let urlString = searchURLTemplate.replacingOccurrences(of: "%s", with: encoded)
        return URL(string: urlString)
    }
}

// MARK: - BrowserSearchSettings

/// Persists the user's chosen search engine in UserDefaults.
final class BrowserSearchSettings {

    static let shared = BrowserSearchSettings()

    private static let defaultsKey = "namu.browser.searchEngine"

    var selectedEngine: BrowserSearchEngine {
        get {
            guard let raw = UserDefaults.standard.string(forKey: Self.defaultsKey),
                  let engine = BrowserSearchEngine(rawValue: raw) else {
                return .google
            }
            return engine
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: Self.defaultsKey)
        }
    }

    private init() {}
}
