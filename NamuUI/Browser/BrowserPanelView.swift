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

            // Find-in-page overlay
            if showSearch, let wv = viewModel.namuWebView {
                BrowserSearchOverlay(isVisible: $showSearch, webView: wv)
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
            .help("Back")

            Button(action: { viewModel.goForward() }) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(.plain)
            .foregroundStyle(viewModel.canGoForward ? .primary : .tertiary)
            .disabled(!viewModel.canGoForward)
            .help("Forward")

            Button(action: { viewModel.reload() }) {
                Image(systemName: viewModel.isLoading ? "xmark" : "arrow.clockwise")
                    .font(.system(size: 11, weight: .medium))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help(viewModel.isLoading ? "Stop" : "Reload")

            TextField("Enter URL...", text: $viewModel.urlText)
                .textFieldStyle(.plain)
                .font(.system(size: 12, design: .monospaced))
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.white.opacity(0.06))
                )
                .onSubmit { viewModel.navigate() }

            // Find button
            Button(action: {
                withAnimation(.easeInOut(duration: 0.15)) { showSearch.toggle() }
            }) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(showSearch ? .primary : .secondary)
            }
            .buttonStyle(.plain)
            .help("Find in Page")
        }
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
                let encoded = resolved.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? resolved
                resolved = "https://www.google.com/search?q=\(encoded)"
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
            }
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
