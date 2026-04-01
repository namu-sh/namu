import AppKit
import Combine
import Foundation
import WebKit

// MARK: - BrowserPanel

/// Concrete panel that wraps a NamuWebView for in-pane browser rendering.
/// Conforms to Panel so it can coexist with TerminalPanel in the same pane tree.
final class BrowserPanel: Panel, ObservableObject {

    // MARK: - Identity

    let id: UUID
    let panelType: PanelType = .browser

    // MARK: - Published state

    /// Display title — mirrors the web page title after navigation.
    @Published private(set) var title: String

    /// Current URL of the loaded page.
    @Published private(set) var url: URL?

    /// User-supplied custom title for this panel (overrides page title in sidebar).
    @Published var customTitle: String?

    // MARK: - View

    /// The browser profile used for cookie/cache isolation.
    let profile: BrowserProfile

    /// Persistent WKWebView for this panel. Starts nil and is created on first access
    /// so that `switchProfile` can replace it.
    private var _webView: NamuWebView?

    /// The active NamuWebView. Created lazily on first access using the current data store.
    private(set) var webView: NamuWebView {
        get {
            if let existing = _webView { return existing }
            let view = makeWebView(dataStore: currentDataStore)
            _webView = view
            return view
        }
        set {
            _webView = newValue
        }
    }

    /// The resolved website data store for this panel's profile.
    private var currentDataStore: WKWebsiteDataStore

    // MARK: - Init

    /// Optional SOCKS5 proxy endpoint for remote workspaces. When non-nil, the browser
    /// will route all traffic through this proxy.
    var proxyEndpoint: RemoteProxyEndpoint? {
        didSet {
            guard oldValue != proxyEndpoint else { return }
            // Rebuild the webview so the new proxy config takes effect.
            if _webView != nil {
                let newView = makeWebView(dataStore: currentDataStore)
                if let currentURL = url {
                    newView.load(URLRequest(url: currentURL))
                }
                _webView?.stopLoading()
                _webView?.removeFromSuperview()
                _webView?.namuDelegate = nil
                _webView = newView
            }
        }
    }

    init(id: UUID = UUID(), url: URL? = nil, profile: BrowserProfile? = nil,
         dataStore: WKWebsiteDataStore? = nil, proxyEndpoint: RemoteProxyEndpoint? = nil) {
        let resolvedProfile = profile ?? BrowserProfile(name: "Default", isDefault: true)
        self.id = id
        self.url = url
        self.title = String(localized: "browser.panel.default.title", defaultValue: "Browser")
        self.profile = resolvedProfile
        self.proxyEndpoint = proxyEndpoint
        // Use the explicitly provided data store, or default for the default profile,
        // or non-persistent for named profiles (caller should pass the correct store).
        if let ds = dataStore {
            self.currentDataStore = ds
        } else if resolvedProfile.isDefault {
            self.currentDataStore = .default()
        } else {
            if #available(macOS 14.0, *) {
                self.currentDataStore = WKWebsiteDataStore(forIdentifier: resolvedProfile.id)
            } else {
                self.currentDataStore = .nonPersistent()
            }
        }
    }

    // MARK: - Private helpers

    private func makeWebView(dataStore: WKWebsiteDataStore) -> NamuWebView {
        var config = NamuWebView.Config()
        config.websiteDataStore = dataStore
        if let endpoint = proxyEndpoint {
            config.proxyHost = endpoint.host
            config.proxyPort = endpoint.port
        }
        let view = NamuWebView(frame: .zero, namuConfig: config)
        view.namuDelegate = self
        return view
    }

    // MARK: - State accessors for persistence

    /// Current page zoom magnification level (1.0 = 100%).
    var zoom: Double {
        webView.magnification
    }

    /// Whether the Web Inspector is currently attached and visible.
    /// WKWebView exposes no public API for this; we track it via our own toggle calls.
    private(set) var devToolsVisible: Bool = false

    /// When true, re-open devtools after the next webview attach completes (used after profile switch).
    var requestDeveloperToolsRefreshAfterNextAttach: Bool = false

    /// Back-navigation history URLs (oldest first, not including current page).
    var backHistory: [String] {
        webView.backForwardList.backList.map { $0.url.absoluteString }
    }

    /// Forward-navigation history URLs (oldest first).
    var forwardHistory: [String] {
        webView.backForwardList.forwardList.map { $0.url.absoluteString }
    }

    // MARK: - Navigation

    func load(url: URL) {
        self.url = url
        webView.load(URLRequest(url: url))
    }

    /// Apply persisted zoom level.
    func applyZoom(_ zoom: Double) {
        guard zoom > 0 else { return }
        webView.magnification = zoom
    }

    /// Toggle and track the Web Inspector visibility.
    func toggleDevTools() {
        devToolsVisible.toggle()
        webView.toggleDeveloperTools()
    }

    /// Mark the Web Inspector as visible without toggling (used during restore).
    func showDevToolsIfNeeded(_ visible: Bool) {
        guard visible, !devToolsVisible else { return }
        devToolsVisible = true
        webView.toggleDeveloperTools()
    }

    /// Replace the panel's webview with one bound to a new profile's data store.
    /// If devtools was open, sets `requestDeveloperToolsRefreshAfterNextAttach` so it
    /// re-opens once the new webview finishes its first navigation.
    func switchProfile(to newProfile: BrowserProfile, dataStore: WKWebsiteDataStore) {
        if devToolsVisible {
            requestDeveloperToolsRefreshAfterNextAttach = true
            devToolsVisible = false
        }

        // Tear down current webview.
        if let old = _webView {
            old.stopLoading()
            old.removeFromSuperview()
            old.namuDelegate = nil
        }

        // Build a new webview bound to the new data store.
        currentDataStore = dataStore
        let newWebView = makeWebView(dataStore: dataStore)
        _webView = newWebView

        // Reload current URL in the new webview.
        if let currentURL = url {
            newWebView.load(URLRequest(url: currentURL))
        }
    }

    // MARK: - Panel protocol

    func handleFocus(_ intent: FocusIntent) {
        switch intent {
        case .capture:
            DispatchQueue.main.async { [weak self] in
                self?.webView.window?.makeFirstResponder(self?.webView)
            }
        case .resign:
            break
        }
    }

    func close() {
        webView.stopLoading()
        webView.removeFromSuperview()
    }
}

// MARK: - NamuWebViewDelegate

extension BrowserPanel: NamuWebViewDelegate {
    func namuWebView(_ webView: NamuWebView, didNavigateTo url: URL) {
        self.url = url
        // Record the visit in the per-profile history store.
        // If the navigation was user-typed (address bar), track it for frecency scoring.
        let isTyped = webView.nextNavigationIsTyped
        webView.nextNavigationIsTyped = false
        NamuMetrics.browserNavigation(typed: isTyped)
        Task { @MainActor in
            let store = BrowserProfileStore.shared.historyStore(for: profile)
            let title = self.title.isEmpty ? nil : self.title
            if isTyped {
                store.recordTypedNavigation(url: url, title: title)
            } else {
                store.recordVisit(url: url, title: title)
            }
        }
        // Re-open devtools if a profile switch requested it.
        if requestDeveloperToolsRefreshAfterNextAttach {
            requestDeveloperToolsRefreshAfterNextAttach = false
            devToolsVisible = true
            webView.toggleDeveloperTools()
        }
    }

    func namuWebView(_ webView: NamuWebView, didChangeTitle title: String) {
        self.title = title.isEmpty
            ? String(localized: "browser.panel.default.title", defaultValue: "Browser")
            : title
    }

    func namuWebView(_ webView: NamuWebView, didStartLoading: Bool) {}

    func namuWebView(_ webView: NamuWebView, didRequestPopup url: URL) -> Bool {
        // Open popups in a new browser tab in the same pane
        return false
    }

    func namuWebView(_ webView: NamuWebView, didStartDownload download: WKDownload) {}
}
