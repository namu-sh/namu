import SwiftUI
import WebKit

// MARK: - BrowserPanelView

/// Embeddable browser panel with URL bar, navigation controls, find-in-page, and popup handling.
/// Can be placed as a pane leaf via PaneLeafView when panelType == .browser.
struct BrowserPanelView: View {
    /// The pane ID this panel lives in — must be set by the parent (PaneLeafView or similar).
    let paneID: UUID

    @StateObject private var viewModel = BrowserViewModel()
    @State private var showSearch: Bool = false
    @State private var suggestions: [String] = []
    @State private var showSuggestions: Bool = false
    @State private var suggestTask: Task<Void, Never>? = nil

    /// History store for the panel's profile — resolved lazily on first use.
    @StateObject private var historyStore = BrowserHistoryStore(profileID: UUID())

    var body: some View {
        ZStack(alignment: .top) {
            VStack(spacing: 0) {
                // Omnibar
                omnibar
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color.black.opacity(0.3))

                // Separator
                Rectangle()
                    .fill(Color.white.opacity(0.08))
                    .frame(height: 1)

                // WebView
                BrowserWebView(viewModel: viewModel)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .background(Color.black)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("namu-browser-panel")

            // Suggestion dropdown overlay
            if showSuggestions && !suggestions.isEmpty {
                VStack(spacing: 0) {
                    // Offset to align below omnibar (~44 pts for padding + field)
                    Color.clear.frame(height: 44)
                    VStack(spacing: 0) {
                        ForEach(suggestions, id: \.self) { suggestion in
                            Button(action: {
                                viewModel.urlText = suggestion
                                viewModel.navigate(to: suggestion)
                                showSuggestions = false
                                suggestions = []
                            }) {
                                Text(suggestion)
                                    .font(.system(size: 12))
                                    .foregroundStyle(.primary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 7)
                            }
                            .buttonStyle(.plain)
                            .background(Color.white.opacity(0.04))
                            if suggestion != suggestions.last {
                                Divider().opacity(0.2)
                            }
                        }
                    }
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color(nsColor: .windowBackgroundColor).opacity(0.96))
                            .shadow(color: .black.opacity(0.35), radius: 8, y: 4)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .padding(.horizontal, 10)
                    Spacer()
                }
                .zIndex(20)
                .transition(.opacity)
                .animation(.easeInOut(duration: 0.12), value: showSuggestions)
            }

            // Find-in-page overlay
            if showSearch, let wv = viewModel.namuWebView {
                BrowserSearchOverlay(isVisible: $showSearch, webView: wv, onQueryChange: { q in
                    viewModel.currentFindQuery = q.isEmpty ? nil : q
                })
                .padding(.top, 8)
                .zIndex(10)
                .animation(.easeInOut(duration: 0.15), value: showSearch)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .toggleFindOverlayBrowser)) { _ in
            withAnimation(.easeInOut(duration: 0.15)) { showSearch.toggle() }
        }
        .onAppear {
            viewModel.paneID = paneID
        }
        .onDisappear {
            suggestTask?.cancel()
            viewModel.unregister()
        }
    }

    // MARK: - Omnibar

    private var omnibar: some View {
        HStack(spacing: 6) {
            Button(action: { viewModel.goBack() }) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(.plain)
            .foregroundStyle(viewModel.canGoBack ? .primary : .tertiary)
            .disabled(!viewModel.canGoBack)
            .help(String(localized: "browser.back.tooltip", defaultValue: "Back"))
            .accessibilityLabel(String(localized: "browser.back.accessibility", defaultValue: "Go Back"))

            Button(action: { viewModel.goForward() }) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(.plain)
            .foregroundStyle(viewModel.canGoForward ? .primary : .tertiary)
            .disabled(!viewModel.canGoForward)
            .help(String(localized: "browser.forward.tooltip", defaultValue: "Forward"))
            .accessibilityLabel(String(localized: "browser.forward.accessibility", defaultValue: "Go Forward"))

            Button(action: { viewModel.reload() }) {
                Image(systemName: viewModel.isLoading ? "xmark" : "arrow.clockwise")
                    .font(.system(size: 11, weight: .medium))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help(viewModel.isLoading ? String(localized: "browser.stop.tooltip", defaultValue: "Stop") : String(localized: "browser.reload.tooltip", defaultValue: "Reload"))
            .accessibilityLabel(viewModel.isLoading ? String(localized: "browser.stop.accessibility", defaultValue: "Stop Loading") : String(localized: "browser.reload.accessibility", defaultValue: "Reload Page"))

            TextField(String(localized: "browser.urlbar.placeholder", defaultValue: "Enter URL..."), text: $viewModel.urlText)
                .textFieldStyle(.plain)
                .font(.system(size: 12, design: .monospaced))
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.white.opacity(0.06))
                )
                .onSubmit {
                    viewModel.navigate()
                    showSuggestions = false
                    suggestions = []
                }
                .onChange(of: viewModel.urlText) { _, newValue in
                    fetchSuggestions(for: newValue)
                }
                .onAppear {
                    showSuggestions = false
                }

            // Find button
            Button(action: {
                withAnimation(.easeInOut(duration: 0.15)) { showSearch.toggle() }
            }) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(showSearch ? .primary : .secondary)
            }
            .buttonStyle(.plain)
            .help(String(localized: "browser.findInPage.tooltip", defaultValue: "Find in Page"))
            .accessibilityLabel(String(localized: "browser.findInPage.accessibility", defaultValue: "Find in Page"))
        }
    }

    // MARK: - Suggestion fetching

    private func fetchSuggestions(for query: String) {
        suggestTask?.cancel()
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        // Only suggest for plain text queries (not full URLs already being navigated).
        guard !trimmed.isEmpty,
              !trimmed.hasPrefix("http://"),
              !trimmed.hasPrefix("https://") else {
            suggestions = []
            showSuggestions = false
            return
        }

        // Local history matches — scored and sorted by relevance.
        let localEntries = historyStore.search(query: trimmed)
        let scoredLocal = localEntries
            .map { entry -> (String, Double) in
                let url = entry.url.absoluteString
                let score = suggestionScore(query: trimmed, url: url,
                                            title: entry.title ?? "",
                                            visitDate: entry.visitDate)
                return (url, score)
            }
            .sorted { $0.1 > $1.1 }
            .prefix(4)
            .map { $0.0 }

        // Collect suggest URLs for Google, DuckDuckGo, and Bing in parallel.
        let suggestEngines: [BrowserSearchEngine] = [.google, .duckduckgo, .bing]
        let suggestURLs = suggestEngines.compactMap { $0.suggestURL(for: trimmed) }

        guard !suggestURLs.isEmpty else {
            suggestions = Array(scoredLocal)
            showSuggestions = !suggestions.isEmpty
            return
        }

        let localMatches = Array(scoredLocal)

        suggestTask = Task { @MainActor in
            // 150 ms debounce
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard !Task.isCancelled else { return }

            // Race: fetch all suggest APIs in parallel, return first non-empty result.
            let remoteItems: [String] = await withTaskGroup(of: [String].self) { group in
                for url in suggestURLs {
                    group.addTask {
                        guard let (data, _) = try? await URLSession.shared.data(from: url) else {
                            return []
                        }
                        if let root = try? JSONSerialization.jsonObject(with: data) as? [Any],
                           root.count >= 2,
                           let items = root[1] as? [String],
                           !items.isEmpty {
                            return Array(items.prefix(8))
                        }
                        return []
                    }
                }
                for await result in group {
                    if !result.isEmpty {
                        group.cancelAll()
                        return result
                    }
                }
                return []
            }

            guard !Task.isCancelled else { return }

            // Merge: local first, then remote items not already present in local.
            let localSet = Set(localMatches)
            let merged = localMatches + remoteItems.filter { !localSet.contains($0) }
            suggestions = Array(merged.prefix(8))
            showSuggestions = !suggestions.isEmpty
        }
    }

    /// Relevance score for a local history entry against the current query.
    private func suggestionScore(query: String, url: String, title: String, visitDate: Date) -> Double {
        let q = query.lowercased()
        let urlLower = url.lowercased()
        let titleLower = title.lowercased()
        var score: Double = 0

        // Exact URL prefix match
        if urlLower.hasPrefix(q) { score += 100 }
        // Title contains query
        if titleLower.contains(q) { score += 50 }
        // URL contains query (but not prefix — already counted above)
        if urlLower.contains(q) { score += 30 }

        // Recency bonus: +20 scaled linearly over 30 days, capped at 0 minimum
        let daysSince = Date().timeIntervalSince(visitDate) / 86_400
        let recency = max(0.0, 1.0 - daysSince / 30.0)
        score += 20.0 * recency

        return score
    }
}

// MARK: - BrowserViewModel

@MainActor
final class BrowserViewModel: ObservableObject, BrowserControlling {
    @Published var urlText: String = "https://www.google.com"
    @Published var canGoBack: Bool = false
    @Published var canGoForward: Bool = false
    @Published var isLoading: Bool = false
    @Published var pageTitle: String = ""

    /// Last active find-in-page query; restored after navigation completes.
    var currentFindQuery: String?

    // MARK: BrowserControlling

    /// The pane ID this browser occupies — set externally when the panel is placed in a pane.
    var paneID: UUID = UUID()
    var currentURL: String { urlText }
    var currentTitle: String { pageTitle }

    /// The NamuWebView instance, set by BrowserWebView coordinator on creation.
    private(set) weak var namuWebView: NamuWebView?

    /// Automation coordinator, lazily created once the webView is available.
    private var automation: BrowserAutomation?
    /// Popup window manager.
    private var popupController: BrowserPopupWindowController?

    func setWebView(_ wv: NamuWebView) {
        namuWebView = wv
        automation = BrowserAutomation(webView: wv)
        popupController = BrowserPopupWindowController(parentConfiguration: wv.configuration)
        BrowserRegistry.shared.register(self)
    }

    func unregister() {
        BrowserRegistry.shared.unregister(paneID: paneID)
    }

    // MARK: - Find-in-page restoration

    func restoreFindQuery() {
        guard let query = currentFindQuery, !query.isEmpty else { return }
        if #available(macOS 13.0, *) {
            namuWebView?.find(query) { _ in }
        }
    }

    // MARK: - Theme mode

    func applyThemeMode() {
        let mode = UserDefaults.standard.string(forKey: "namu.browserThemeMode") ?? "system"
        switch mode {
        case "light":
            namuWebView?.appearance = NSAppearance(named: .aqua)
        case "dark":
            namuWebView?.appearance = NSAppearance(named: .darkAqua)
        default:
            namuWebView?.appearance = nil
        }

        let colorScheme: String
        switch mode {
        case "light": colorScheme = "'light'"
        case "dark": colorScheme = "'dark'"
        default: colorScheme = "null"
        }

        let js = """
        (() => {
            const root = document.documentElement || document.body;
            const scheme = \(colorScheme);
            if (scheme) {
                root.style.setProperty('color-scheme', scheme, 'important');
                let meta = document.querySelector('meta[name="color-scheme"]');
                if (!meta) { meta = document.createElement('meta'); meta.name = 'color-scheme'; (document.head || root).appendChild(meta); }
                meta.content = scheme;
            } else {
                root.style.removeProperty('color-scheme');
                const meta = document.querySelector('meta[name="color-scheme"]');
                if (meta) meta.remove();
            }
        })()
        """
        namuWebView?.evaluateJavaScript(js, completionHandler: nil)
    }

    // MARK: - Navigation

    func navigate() {
        navigate(to: urlText)
    }

    func navigate(to urlString: String) {
        var resolved = urlString.trimmingCharacters(in: .whitespaces)
        guard !resolved.isEmpty else { return }

        if !resolved.hasPrefix("http://") && !resolved.hasPrefix("https://") {
            if resolved.contains(".") && !resolved.contains(" ") {
                resolved = "https://\(resolved)"
            } else {
                let engine = BrowserSearchSettings.shared.selectedEngine
                let encoded = resolved.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? resolved
                resolved = engine.searchURLTemplate.replacingOccurrences(of: "%s", with: encoded)
            }
        }
        urlText = resolved
        guard let url = URL(string: resolved) else { return }
        namuWebView?.load(URLRequest(url: url))
    }

    func goBack()    { namuWebView?.goBack() }
    func goForward() { namuWebView?.goForward() }

    func reload() {
        if isLoading { namuWebView?.stopLoading() } else { namuWebView?.reload() }
    }

    // MARK: - BrowserControlling JS methods

    func evaluateJS(_ script: String) async throws -> String {
        guard let wv = namuWebView else { throw BrowserError.javascriptError("No web view") }
        return try await wv.evaluateJS(script)
    }

    func click(selector: String) async throws -> String {
        guard let wv = namuWebView else { throw BrowserError.javascriptError("No web view") }
        return try await wv.click(selector: selector)
    }

    func type(selector: String, text: String) async throws -> String {
        guard let wv = namuWebView else { throw BrowserError.javascriptError("No web view") }
        return try await wv.type(selector: selector, text: text)
    }

    func hover(selector: String) async throws -> String {
        guard let wv = namuWebView else { throw BrowserError.javascriptError("No web view") }
        return try await wv.hover(selector: selector)
    }

    func getText(selector: String) async throws -> String {
        guard let wv = namuWebView else { throw BrowserError.javascriptError("No web view") }
        return try await wv.getText(selector: selector)
    }

    func getAttribute(selector: String, attribute: String) async throws -> String {
        guard let wv = namuWebView else { throw BrowserError.javascriptError("No web view") }
        return try await wv.getAttribute(selector: selector, attribute: attribute)
    }

    func takeScreenshot() async throws -> Data {
        guard let wv = namuWebView else { throw BrowserError.screenshotFailed }
        return try await wv.takeScreenshot()
    }

    func findText(_ text: String) async throws -> String {
        guard let wv = namuWebView else { throw BrowserError.javascriptError("No web view") }
        return try await wv.findText(text)
    }

    func waitForSelector(_ selector: String, timeout: TimeInterval) async throws -> String {
        guard let wv = namuWebView else { throw BrowserError.javascriptError("No web view") }
        return try await wv.waitForSelector(selector, timeout: timeout)
    }

    func waitForNavigation(timeout: TimeInterval) async throws {
        guard let wv = namuWebView else { throw BrowserError.javascriptError("No web view") }
        try await wv.waitForNavigation(timeout: timeout)
    }

    func dismissDialog(accept: Bool, text: String?) async throws {
        guard let wv = namuWebView else { throw BrowserError.javascriptError("No web view") }
        wv.dismissDialog(accept: accept, text: text)
    }

    func consoleLogs() async throws -> [ConsoleMessage] {
        guard let wv = namuWebView else { throw BrowserError.javascriptError("No web view") }
        return try await wv.consoleLogs()
    }

    func getCookies(url: URL?) async throws -> [[String: String]] {
        guard let wv = namuWebView else { throw BrowserError.javascriptError("No web view") }
        let cookies = await wv.getCookies(url: url)
        return cookies.map { cookie in
            var props: [String: String] = [
                "name": cookie.name,
                "value": cookie.value,
                "domain": cookie.domain,
                "path": cookie.path,
            ]
            if let expires = cookie.expiresDate {
                props["expires"] = String(expires.timeIntervalSince1970)
            }
            return props
        }
    }

    func setCookieProperties(_ props: [String: String]) async throws {
        guard let wv = namuWebView else { throw BrowserError.javascriptError("No web view") }
        guard let name = props["name"], let value = props["value"],
              let domain = props["domain"] else {
            throw BrowserError.javascriptError("setCookie requires name, value, domain")
        }
        var cookieProps: [HTTPCookiePropertyKey: Any] = [
            .name: name, .value: value, .domain: domain, .path: props["path"] ?? "/"
        ]
        if let expiresStr = props["expires"], let ts = Double(expiresStr) {
            cookieProps[.expires] = Date(timeIntervalSince1970: ts)
        }
        if let cookie = HTTPCookie(properties: cookieProps) {
            await wv.setCookie(cookie)
        }
    }

    func deleteCookie(name: String, domain: String) async throws {
        guard let wv = namuWebView else { throw BrowserError.javascriptError("No web view") }
        await wv.deleteCookie(name: name, domain: domain)
    }

    func deleteAllCookies() async throws {
        guard let wv = namuWebView else { throw BrowserError.javascriptError("No web view") }
        await wv.clearCookies()
    }

    func getStorageItem(key: String) async throws -> String {
        guard let wv = namuWebView else { throw BrowserError.javascriptError("No web view") }
        return try await wv.getStorageItem(key: key)
    }

    func setStorageItem(key: String, value: String) async throws {
        guard let wv = namuWebView else { throw BrowserError.javascriptError("No web view") }
        try await wv.setStorageItem(key: key, value: value)
    }

    func clearStorage() async throws {
        guard let wv = namuWebView else { throw BrowserError.javascriptError("No web view") }
        try await wv.clearStorage()
    }

    func setViewportSize(width: Int, height: Int) async throws {
        guard let wv = namuWebView else { throw BrowserError.javascriptError("No web view") }
        wv.setViewportSize(width: width, height: height)
    }

    // MARK: - BrowserControlling V2 methods

    func scroll(x: Double, y: Double) async throws -> String {
        guard let wv = namuWebView else { throw BrowserError.javascriptError("No web view") }
        return try await wv.scroll(x: x, y: y)
    }

    func scrollIntoView(selector: String) async throws -> String {
        guard let wv = namuWebView else { throw BrowserError.javascriptError("No web view") }
        return try await wv.scrollIntoView(selector: selector)
    }

    func press(selector: String, key: String) async throws -> String {
        guard let wv = namuWebView else { throw BrowserError.javascriptError("No web view") }
        return try await wv.press(selector: selector, key: key)
    }

    func check(selector: String) async throws -> String {
        guard let wv = namuWebView else { throw BrowserError.javascriptError("No web view") }
        return try await wv.check(selector: selector)
    }

    func uncheck(selector: String) async throws -> String {
        guard let wv = namuWebView else { throw BrowserError.javascriptError("No web view") }
        return try await wv.uncheck(selector: selector)
    }

    func selectOption(selector: String, value: String) async throws -> String {
        guard let wv = namuWebView else { throw BrowserError.javascriptError("No web view") }
        return try await wv.selectOption(selector: selector, value: value)
    }

    func selectFrame(_ selector: String?) {
        namuWebView?.selectFrame(selector)
    }

    func focusElement(selector: String) async throws -> String {
        guard let wv = namuWebView else { throw BrowserError.javascriptError("No web view") }
        return try await wv.focusElement(selector: selector)
    }

    func clearConsoleLogs() {
        namuWebView?.clearConsoleLogs()
    }

    func addInitScript(_ script: String) {
        namuWebView?.addInitScript(script)
    }

    func addInitStyle(_ css: String) {
        namuWebView?.addInitStyle(css)
    }

    // MARK: - Developer tools transition queueing

    /// True while a devtools toggle is in-flight; a second call queues one pending toggle.
    private var devToolsTransitionInFlight: Bool = false
    /// Whether a second toggle was requested while a transition was in-flight.
    private var devToolsTransitionPending: Bool = false

    func toggleDeveloperTools() {
        guard !devToolsTransitionInFlight else {
            // Queue at most one pending toggle; discard extras.
            devToolsTransitionPending = true
            return
        }
        devToolsTransitionInFlight = true
        namuWebView?.toggleDeveloperTools()
        // Allow a short settle window before accepting another toggle.
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard let self else { return }
            self.devToolsTransitionInFlight = false
            if self.devToolsTransitionPending {
                self.devToolsTransitionPending = false
                self.toggleDeveloperTools()
            }
        }
    }

    func showDeveloperToolsConsole() {
        namuWebView?.showDeveloperToolsConsole()
    }

    // MARK: - BrowserControlling V3 methods (US-017)

    func dblclick(selector: String) async throws -> String {
        guard let wv = namuWebView else { throw BrowserError.javascriptError("No web view") }
        return try await wv.dblclick(selector: selector)
    }

    func fill(selector: String, text: String) async throws -> String {
        guard let wv = namuWebView else { throw BrowserError.javascriptError("No web view") }
        return try await wv.fill(selector: selector, text: text)
    }

    func keydown(selector: String, key: String) async throws -> String {
        guard let wv = namuWebView else { throw BrowserError.javascriptError("No web view") }
        return try await wv.keydown(selector: selector, key: key)
    }

    func keyup(selector: String, key: String) async throws -> String {
        guard let wv = namuWebView else { throw BrowserError.javascriptError("No web view") }
        return try await wv.keyup(selector: selector, key: key)
    }

    func getInnerHTML(selector: String) async throws -> String {
        guard let wv = namuWebView else { throw BrowserError.javascriptError("No web view") }
        return try await wv.getInnerHTML(selector: selector)
    }

    func getInputValue(selector: String) async throws -> String {
        guard let wv = namuWebView else { throw BrowserError.javascriptError("No web view") }
        return try await wv.getInputValue(selector: selector)
    }

    func countElements(selector: String) async throws -> Int {
        guard let wv = namuWebView else { throw BrowserError.javascriptError("No web view") }
        return try await wv.countElements(selector: selector)
    }

    func getBoundingBox(selector: String) async throws -> String {
        guard let wv = namuWebView else { throw BrowserError.javascriptError("No web view") }
        return try await wv.getBoundingBox(selector: selector)
    }

    func getComputedStyles(selector: String) async throws -> String {
        guard let wv = namuWebView else { throw BrowserError.javascriptError("No web view") }
        return try await wv.getComputedStyles(selector: selector)
    }

    func isVisible(selector: String) async throws -> Bool {
        guard let wv = namuWebView else { throw BrowserError.javascriptError("No web view") }
        return try await wv.isVisible(selector: selector)
    }

    func isEnabled(selector: String) async throws -> Bool {
        guard let wv = namuWebView else { throw BrowserError.javascriptError("No web view") }
        return try await wv.isEnabled(selector: selector)
    }

    func isChecked(selector: String) async throws -> Bool {
        guard let wv = namuWebView else { throw BrowserError.javascriptError("No web view") }
        return try await wv.isChecked(selector: selector)
    }

    func findByRole(_ role: String) async throws -> String {
        guard let wv = namuWebView else { throw BrowserError.javascriptError("No web view") }
        return try await wv.findByRole(role)
    }

    func findByText(_ text: String) async throws -> String {
        guard let wv = namuWebView else { throw BrowserError.javascriptError("No web view") }
        return try await wv.findByText(text)
    }

    func findByLabel(_ text: String) async throws -> String {
        guard let wv = namuWebView else { throw BrowserError.javascriptError("No web view") }
        return try await wv.findByLabel(text)
    }

    func findByPlaceholder(_ text: String) async throws -> String {
        guard let wv = namuWebView else { throw BrowserError.javascriptError("No web view") }
        return try await wv.findByPlaceholder(text)
    }

    func findByAlt(_ text: String) async throws -> String {
        guard let wv = namuWebView else { throw BrowserError.javascriptError("No web view") }
        return try await wv.findByAlt(text)
    }

    func findByTitle(_ text: String) async throws -> String {
        guard let wv = namuWebView else { throw BrowserError.javascriptError("No web view") }
        return try await wv.findByTitle(text)
    }

    func findByTestId(_ testId: String) async throws -> String {
        guard let wv = namuWebView else { throw BrowserError.javascriptError("No web view") }
        return try await wv.findByTestId(testId)
    }

    func findFirst(selector: String) async throws -> String {
        guard let wv = namuWebView else { throw BrowserError.javascriptError("No web view") }
        return try await wv.findFirst(selector: selector)
    }

    func findLast(selector: String) async throws -> String {
        guard let wv = namuWebView else { throw BrowserError.javascriptError("No web view") }
        return try await wv.findLast(selector: selector)
    }

    func findNth(selector: String, index: Int) async throws -> String {
        guard let wv = namuWebView else { throw BrowserError.javascriptError("No web view") }
        return try await wv.findNth(selector: selector, index: index)
    }

    func acceptDialog(text: String?) async throws {
        guard let wv = namuWebView else { throw BrowserError.javascriptError("No web view") }
        wv.acceptDialog(text: text)
    }

    func clearAllCookies() async throws {
        guard let wv = namuWebView else { throw BrowserError.javascriptError("No web view") }
        await wv.clearAllCookies()
    }

    func highlight(selector: String) async throws -> String {
        guard let wv = namuWebView else { throw BrowserError.javascriptError("No web view") }
        return try await wv.highlight(selector: selector)
    }

    func savePageState() async throws -> String {
        guard let wv = namuWebView else { throw BrowserError.javascriptError("No web view") }
        return try await wv.savePageState()
    }

    func loadPageState(_ state: String) async throws -> String {
        guard let wv = namuWebView else { throw BrowserError.javascriptError("No web view") }
        return try await wv.loadPageState(state)
    }

    func networkRequests() async throws -> String {
        guard let wv = namuWebView else { throw BrowserError.javascriptError("No web view") }
        return try await wv.networkRequests()
    }

    func startNetworkTrace() async throws {
        guard let wv = namuWebView else { throw BrowserError.javascriptError("No web view") }
        try await wv.startNetworkTrace()
    }

    func stopNetworkTrace() async throws -> String {
        guard let wv = namuWebView else { throw BrowserError.javascriptError("No web view") }
        return try await wv.stopNetworkTrace()
    }

    // MARK: - Automation access

    func runAutomation(_ actions: [BrowserAutomation.Action]) async -> [BrowserAutomation.AutomationResult] {
        guard let automation else { return [] }
        return await automation.run(actions)
    }

    // MARK: - Popup delegate

    func createPopup(
        with configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        popupController?.createPopup(
            with: configuration,
            for: navigationAction,
            windowFeatures: windowFeatures
        )
    }
}

// MARK: - BrowserWebView

struct BrowserWebView: NSViewRepresentable {
    @ObservedObject var viewModel: BrowserViewModel

    func makeCoordinator() -> Coordinator {
        Coordinator(viewModel: viewModel)
    }

    func makeNSView(context: Context) -> NamuWebView {
        let webView = NamuWebView(frame: .zero, namuConfig: NamuWebView.Config())
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.namuDelegate = context.coordinator

        viewModel.setWebView(webView)

        // Load initial URL
        if let url = URL(string: viewModel.urlText) {
            webView.load(URLRequest(url: url))
        }

        return webView
    }

    func updateNSView(_ nsView: NamuWebView, context: Context) {
        context.coordinator.viewModel = viewModel
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, NamuWebViewDelegate {
        var viewModel: BrowserViewModel

        init(viewModel: BrowserViewModel) {
            self.viewModel = viewModel
        }

        // MARK: WKNavigationDelegate

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            DispatchQueue.main.async { [weak self] in
                self?.viewModel.isLoading = true
                self?.syncState(webView)
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            // Forward to NamuWebView so waitForNavigation continuation is resumed.
            if let nwv = webView as? NamuWebView {
                nwv.handleNavigationDidFinish(navigation)
            }
            DispatchQueue.main.async { [weak self] in
                self?.viewModel.isLoading = false
                self?.syncState(webView)
                self?.viewModel.restoreFindQuery()
                self?.viewModel.applyThemeMode()
            }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            // Forward to NamuWebView so waitForNavigation continuation is resumed.
            if let nwv = webView as? NamuWebView {
                nwv.handleNavigationDidFail(navigation, error: error)
            }
            DispatchQueue.main.async { [weak self] in
                self?.viewModel.isLoading = false
                self?.syncState(webView)
                self?.viewModel.restoreFindQuery()
            }
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            // Reset loading state on provisional navigation failure.
            DispatchQueue.main.async { [weak self] in
                self?.viewModel.isLoading = false
                self?.syncState(webView)
            }
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            webView.reload()
        }

        // MARK: WKUIDelegate (popup support + dialog forwarding)

        func webView(
            _ webView: WKWebView,
            createWebViewWith configuration: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction,
            windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            viewModel.createPopup(
                with: configuration,
                for: navigationAction,
                windowFeatures: windowFeatures
            )
        }

        // Forward JS dialog handling to NamuWebView so dismissDialog() works.

        func webView(
            _ webView: WKWebView,
            runJavaScriptAlertPanelWithMessage message: String,
            initiatedByFrame frame: WKFrameInfo,
            completionHandler: @escaping () -> Void
        ) {
            guard let nwv = webView as? NamuWebView else { completionHandler(); return }
            nwv.webView(webView, runJavaScriptAlertPanelWithMessage: message, initiatedByFrame: frame, completionHandler: completionHandler)
        }

        func webView(
            _ webView: WKWebView,
            runJavaScriptConfirmPanelWithMessage message: String,
            initiatedByFrame frame: WKFrameInfo,
            completionHandler: @escaping (Bool) -> Void
        ) {
            guard let nwv = webView as? NamuWebView else { completionHandler(false); return }
            nwv.webView(webView, runJavaScriptConfirmPanelWithMessage: message, initiatedByFrame: frame, completionHandler: completionHandler)
        }

        func webView(
            _ webView: WKWebView,
            runJavaScriptTextInputPanelWithPrompt prompt: String,
            defaultText: String?,
            initiatedByFrame frame: WKFrameInfo,
            completionHandler: @escaping (String?) -> Void
        ) {
            guard let nwv = webView as? NamuWebView else { completionHandler(nil); return }
            nwv.webView(webView, runJavaScriptTextInputPanelWithPrompt: prompt, defaultText: defaultText, initiatedByFrame: frame, completionHandler: completionHandler)
        }

        // MARK: NamuWebViewDelegate

        func namuWebView(_ webView: NamuWebView, didNavigateTo url: URL) {
            DispatchQueue.main.async { [weak self] in
                self?.viewModel.urlText = url.absoluteString
            }
        }

        func namuWebView(_ webView: NamuWebView, didChangeTitle title: String) {
            DispatchQueue.main.async { [weak self] in
                self?.viewModel.pageTitle = title
            }
        }

        func namuWebView(_ webView: NamuWebView, didStartLoading: Bool) {
            DispatchQueue.main.async { [weak self] in
                self?.viewModel.isLoading = didStartLoading
            }
        }

        func namuWebView(_ webView: NamuWebView, didRequestPopup url: URL) -> Bool {
            // Let the WKUIDelegate createWebViewWith handle it
            return true
        }

        func namuWebView(_ webView: NamuWebView, didStartDownload download: WKDownload) {
            Task { @MainActor in
                BrowserDownloadTracker.shared.trackDownload(download)
            }
        }

        // MARK: Helpers

        private func syncState(_ webView: WKWebView) {
            viewModel.canGoBack    = webView.canGoBack
            viewModel.canGoForward = webView.canGoForward
            viewModel.pageTitle    = webView.title ?? ""
            if let url = webView.url?.absoluteString {
                viewModel.urlText = url
            }
        }
    }
}

// MARK: - Notification names

extension Notification.Name {
    /// Posted to toggle the find-in-page overlay within the browser panel.
    static let toggleFindOverlayBrowser = Notification.Name("namu.browser.toggleFindOverlay")
}
