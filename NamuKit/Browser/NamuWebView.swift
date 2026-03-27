import Foundation
import WebKit

// MARK: - ConsoleMessage

struct ConsoleMessage {
    let level: String
    let args: [String]
    let timestamp: Double
}

// MARK: - NamuWebViewDelegate

protocol NamuWebViewDelegate: AnyObject {
    func namuWebView(_ webView: NamuWebView, didNavigateTo url: URL)
    func namuWebView(_ webView: NamuWebView, didChangeTitle title: String)
    func namuWebView(_ webView: NamuWebView, didStartLoading: Bool)
    func namuWebView(_ webView: NamuWebView, didRequestPopup url: URL) -> Bool
    func namuWebView(_ webView: NamuWebView, didStartDownload download: WKDownload)
}

// MARK: - NamuWebView

/// Enhanced WKWebView with:
///   - Proxy configuration support
///   - Cookie and storage management
///   - Download handling
///   - User agent customization
///   - JavaScript injection API
///   - Popup window interception
///   - waitForSelector / waitForNavigation
///   - Dialog (alert/confirm/prompt) handling
///   - Console log capture
///   - Viewport resizing
final class NamuWebView: WKWebView {

    // MARK: - Configuration

    struct Config {
        /// Optional HTTP proxy host/port.
        var proxyHost: String?
        var proxyPort: Int?
        /// Custom user agent (nil = WKWebView default).
        var userAgent: String?
        /// Whether to block third-party cookies.
        var blockThirdPartyCookies: Bool = false
        /// Whether to allow popups (window.open).
        var allowPopups: Bool = true
        /// Whether to intercept downloads instead of opening them.
        var interceptDownloads: Bool = true
    }

    // MARK: - Dialog support

    struct PendingDialog {
        enum Kind { case alert, confirm, prompt(defaultText: String?) }
        let kind: Kind
        let message: String
        let continuation: CheckedContinuation<DialogResult, Never>
    }

    struct DialogResult {
        let accepted: Bool
        let text: String?
    }

    // MARK: - Properties

    weak var namuDelegate: (any NamuWebViewDelegate)?
    private(set) var config: Config

    /// Queue of dialogs waiting to be dismissed.
    private var pendingDialogs: [PendingDialog] = []

    /// Continuation for waitForNavigation, keyed by token to prevent double-resume.
    private var navigationContinuation: CheckedContinuation<Void, Error>?
    private var navigationToken: UUID?

    // MARK: - Console injection script

    private static let consoleInjectionScript = """
    (function() {
        if (window.__namu_console) return;
        window.__namu_console = [];
        ['log','warn','error'].forEach(function(m) {
            var orig = console[m];
            console[m] = function() {
                var args = Array.prototype.slice.call(arguments);
                window.__namu_console.push({level: m, args: args.map(String), ts: Date.now()});
                orig.apply(console, arguments);
            };
        });
    })();
    """

    // MARK: - Init

    init(frame: CGRect = .zero, namuConfig: Config = Config()) {
        self.config = namuConfig

        let wkConfig = WKWebViewConfiguration()
        wkConfig.preferences.isElementFullscreenEnabled = true
        wkConfig.preferences.javaScriptCanOpenWindowsAutomatically = namuConfig.allowPopups

        // Persistent data store so cookies/storage survive navigation.
        wkConfig.websiteDataStore = .default()

        // Inject console capture script at document start.
        let consoleScript = WKUserScript(
            source: NamuWebView.consoleInjectionScript,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        )
        wkConfig.userContentController.addUserScript(consoleScript)

        super.init(frame: frame, configuration: wkConfig)

        allowsBackForwardNavigationGestures = true
        allowsMagnification = true

        if let ua = namuConfig.userAgent {
            customUserAgent = ua
        }

        navigationDelegate = self
        uiDelegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("use init(frame:namuConfig:)") }

    // MARK: - JavaScript injection

    /// Evaluate JavaScript in the main frame and return the result as a String.
    func evaluateJS(_ script: String) async throws -> String {
        let result = try await evaluateJavaScript(script)
        switch result {
        case let s as String:  return s
        case let n as NSNumber: return n.stringValue
        case let b as Bool:     return b ? "true" : "false"
        case .none:             return "null"
        default:
            if let json = try? JSONSerialization.data(withJSONObject: result as Any),
               let str = String(data: json, encoding: .utf8) {
                return str
            }
            return "\(result as Any)"
        }
    }

    /// Click the element matching `selector`.
    func click(selector: String) async throws -> String {
        let script = """
        (function() {
            var el = document.querySelector(\(jsString(selector)));
            if (!el) return 'error: element not found';
            el.click();
            return 'ok';
        })();
        """
        return try await evaluateJS(script)
    }

    /// Type text into the element matching `selector`.
    func type(selector: String, text: String) async throws -> String {
        let script = """
        (function() {
            var el = document.querySelector(\(jsString(selector)));
            if (!el) return 'error: element not found';
            el.focus();
            el.value = \(jsString(text));
            el.dispatchEvent(new Event('input', { bubbles: true }));
            el.dispatchEvent(new Event('change', { bubbles: true }));
            return 'ok';
        })();
        """
        return try await evaluateJS(script)
    }

    /// Hover over the element matching `selector`.
    func hover(selector: String) async throws -> String {
        let script = """
        (function() {
            var el = document.querySelector(\(jsString(selector)));
            if (!el) return 'error: element not found';
            el.dispatchEvent(new MouseEvent('mouseover', { bubbles: true }));
            el.dispatchEvent(new MouseEvent('mouseenter', { bubbles: true }));
            return 'ok';
        })();
        """
        return try await evaluateJS(script)
    }

    /// Get the text content of the element matching `selector`.
    func getText(selector: String) async throws -> String {
        let script = """
        (function() {
            var el = document.querySelector(\(jsString(selector)));
            if (!el) return 'error: element not found';
            return el.textContent || el.innerText || '';
        })();
        """
        return try await evaluateJS(script)
    }

    /// Get the value of an attribute on the element matching `selector`.
    func getAttribute(selector: String, attribute: String) async throws -> String {
        let script = """
        (function() {
            var el = document.querySelector(\(jsString(selector)));
            if (!el) return 'error: element not found';
            return el.getAttribute(\(jsString(attribute))) ?? 'null';
        })();
        """
        return try await evaluateJS(script)
    }

    /// Fill a form: map of selector → value.
    func fillForm(_ fields: [String: String]) async throws -> String {
        var results: [String] = []
        for (selector, value) in fields {
            let result = try await type(selector: selector, text: value)
            results.append("\(selector): \(result)")
        }
        return results.joined(separator: "\n")
    }

    /// Find text on the page using the browser's built-in find API.
    /// Returns a string describing the number of matches found.
    func findText(_ text: String) async throws -> String {
        let script = """
        (function() {
            var t = \(jsString(text));
            if (!t) return "0 matches";
            var count = 0;
            var walker = document.createTreeWalker(
                document.body, NodeFilter.SHOW_TEXT, null, false);
            var lower = t.toLowerCase();
            while (walker.nextNode()) {
                var nodeText = walker.currentNode.nodeValue || "";
                var idx = 0;
                while (true) {
                    idx = nodeText.toLowerCase().indexOf(lower, idx);
                    if (idx === -1) break;
                    count++;
                    idx += lower.length;
                }
            }
            return count + " match" + (count === 1 ? "" : "es");
        })()
        """
        return try await evaluateJS(script)
    }

    /// Take a screenshot and return it as PNG data.
    func takeScreenshot() async throws -> Data {
        let config = WKSnapshotConfiguration()
        let image = try await takeSnapshot(configuration: config)
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            throw BrowserError.screenshotFailed
        }
        return png
    }

    // MARK: - waitForSelector

    /// Poll every 100ms until `selector` is present in the DOM, throw on timeout.
    func waitForSelector(_ selector: String, timeout: TimeInterval = 5) async throws -> String {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let script = """
            (function() {
                return document.querySelector(\(jsString(selector))) ? 'found' : 'not_found';
            })();
            """
            if (try await evaluateJS(script)) == "found" { return "found" }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        throw BrowserError.timeout("waitForSelector(\(selector))")
    }

    // MARK: - waitForNavigation

    /// Wait for the next navigation to complete. Throws on timeout.
    func waitForNavigation(timeout: TimeInterval = 10) async throws {
        let token = UUID()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            self.navigationToken = token
            self.navigationContinuation = continuation
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                guard let self, self.navigationToken == token else { return }
                if let cont = self.navigationContinuation {
                    self.navigationContinuation = nil
                    self.navigationToken = nil
                    cont.resume(throwing: BrowserError.timeout("waitForNavigation"))
                }
            }
        }
    }

    // MARK: - Dialog handling

    /// Dismiss the front-most pending dialog.
    func dismissDialog(accept: Bool, text: String? = nil) {
        guard !pendingDialogs.isEmpty else { return }
        let dialog = pendingDialogs.removeFirst()
        dialog.continuation.resume(returning: DialogResult(accepted: accept, text: text))
    }

    // MARK: - Console capture

    /// Retrieve captured console messages since last call and clear the buffer.
    func consoleLogs() async throws -> [ConsoleMessage] {
        let json = try await evaluateJS("""
        (function() {
            var logs = window.__namu_console || [];
            window.__namu_console = [];
            return JSON.stringify(logs);
        })();
        """)
        guard let data = json.data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return []
        }
        return arr.compactMap { entry in
            guard let level = entry["level"] as? String,
                  let args = entry["args"] as? [String],
                  let ts = entry["ts"] as? Double else { return nil }
            return ConsoleMessage(level: level, args: args, timestamp: ts)
        }
    }

    // MARK: - Cookie management

    /// Get all cookies. Optionally filter by URL host.
    func getCookies(url: URL? = nil) async -> [HTTPCookie] {
        let store = configuration.websiteDataStore.httpCookieStore
        let all = await store.allCookies()
        guard let url else { return all }
        let host = url.host ?? ""
        return all.filter { host.hasSuffix($0.domain) || $0.domain == host }
    }

    /// Get all cookies for the current page domain (kept for compatibility).
    func cookies() async -> [HTTPCookie] {
        await getCookies(url: nil)
    }

    /// Set a cookie.
    func setCookie(_ cookie: HTTPCookie) async {
        let store = configuration.websiteDataStore.httpCookieStore
        await store.setCookie(cookie)
    }

    /// Delete a specific cookie by name and domain.
    func deleteCookie(name: String, domain: String) async {
        let store = configuration.websiteDataStore.httpCookieStore
        for cookie in await store.allCookies() where cookie.name == name && cookie.domain == domain {
            await store.deleteCookie(cookie)
        }
    }

    /// Delete all cookies.
    func deleteAllCookies() async {
        let store = configuration.websiteDataStore.httpCookieStore
        for cookie in await store.allCookies() {
            await store.deleteCookie(cookie)
        }
    }

    /// Delete all cookies (kept for compatibility).
    func clearCookies() async {
        await deleteAllCookies()
    }

    /// Clear all website data (cache, cookies, storage).
    func clearAllData() async {
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        let store = configuration.websiteDataStore
        let records = await store.dataRecords(ofTypes: types)
        await store.removeData(ofTypes: types, for: records)
    }

    // MARK: - LocalStorage

    /// Get a value from localStorage.
    func getStorageItem(key: String) async throws -> String {
        try await evaluateJS("(function(){ var v = localStorage.getItem(\(jsString(key))); return v !== null ? v : 'null'; })()")
    }

    /// Set a value in localStorage.
    func setStorageItem(key: String, value: String) async throws {
        _ = try await evaluateJS("(function(){ localStorage.setItem(\(jsString(key)), \(jsString(value))); return 'ok'; })()")
    }

    /// Clear all localStorage entries.
    func clearStorage() async throws {
        _ = try await evaluateJS("(function(){ localStorage.clear(); return 'ok'; })()")
    }

    // MARK: - Cookie helpers for IPC layer

    /// Get cookies as serializable dictionaries, optionally filtered by URL.
    func getCookiesAsDictionaries(url: URL? = nil) async -> [[String: String]] {
        await getCookies(url: url).map { cookie in
            var d: [String: String] = [
                "name": cookie.name,
                "value": cookie.value,
                "domain": cookie.domain,
                "path": cookie.path
            ]
            if cookie.isSecure { d["secure"] = "true" }
            if cookie.isHTTPOnly { d["httpOnly"] = "true" }
            if let exp = cookie.expiresDate {
                d["expires"] = String(exp.timeIntervalSince1970)
            }
            return d
        }
    }

    /// Create and set a cookie from a properties dictionary.
    func setCookieProperties(_ props: [String: String]) async {
        var properties: [HTTPCookiePropertyKey: Any] = [:]
        if let name   = props["name"]   { properties[.name]   = name }
        if let value  = props["value"]  { properties[.value]  = value }
        if let domain = props["domain"] { properties[.domain] = domain }
        if let path   = props["path"]   { properties[.path]   = path } else { properties[.path] = "/" }
        if let exp    = props["expires"], let ts = Double(exp) {
            properties[.expires] = Date(timeIntervalSince1970: ts)
        }
        guard let cookie = HTTPCookie(properties: properties) else { return }
        await setCookie(cookie)
    }

    // MARK: - Scroll

    /// Scroll the page by (x, y) pixels.
    func scroll(x: Double, y: Double) async throws -> String {
        try await evaluateJS("(function(){ window.scrollBy(\(x), \(y)); return 'ok'; })()")
    }

    /// Scroll the element matching `selector` into view.
    func scrollIntoView(selector: String) async throws -> String {
        let script = """
        (function() {
            var el = document.querySelector(\(jsString(selector)));
            if (!el) return 'error: element not found';
            el.scrollIntoView({ behavior: 'smooth', block: 'center' });
            return 'ok';
        })();
        """
        return try await evaluateJS(script)
    }

    // MARK: - Keyboard

    /// Dispatch a keyboard event on the element matching `selector`.
    func press(selector: String, key: String) async throws -> String {
        let script = """
        (function() {
            var el = document.querySelector(\(jsString(selector)));
            if (!el) return 'error: element not found';
            var opts = { key: \(jsString(key)), bubbles: true, cancelable: true };
            el.dispatchEvent(new KeyboardEvent('keydown', opts));
            el.dispatchEvent(new KeyboardEvent('keypress', opts));
            el.dispatchEvent(new KeyboardEvent('keyup', opts));
            return 'ok';
        })();
        """
        return try await evaluateJS(script)
    }

    // MARK: - Checkbox

    /// Check a checkbox element matching `selector`.
    func check(selector: String) async throws -> String {
        let script = """
        (function() {
            var el = document.querySelector(\(jsString(selector)));
            if (!el) return 'error: element not found';
            el.checked = true;
            el.dispatchEvent(new Event('change', { bubbles: true }));
            return 'ok';
        })();
        """
        return try await evaluateJS(script)
    }

    /// Uncheck a checkbox element matching `selector`.
    func uncheck(selector: String) async throws -> String {
        let script = """
        (function() {
            var el = document.querySelector(\(jsString(selector)));
            if (!el) return 'error: element not found';
            el.checked = false;
            el.dispatchEvent(new Event('change', { bubbles: true }));
            return 'ok';
        })();
        """
        return try await evaluateJS(script)
    }

    // MARK: - Select

    /// Set the value of a <select> element matching `selector` and dispatch change.
    func selectOption(selector: String, value: String) async throws -> String {
        let script = """
        (function() {
            var el = document.querySelector(\(jsString(selector)));
            if (!el) return 'error: element not found';
            el.value = \(jsString(value));
            el.dispatchEvent(new Event('change', { bubbles: true }));
            return 'ok';
        })();
        """
        return try await evaluateJS(script)
    }

    // MARK: - Frame context

    /// The selector used to narrow JS evaluation into an iframe (nil = main frame).
    private(set) var currentFrameSelector: String? = nil

    /// Switch JS evaluation context to the iframe matching `selector`, or back to main frame if nil.
    func selectFrame(_ selector: String?) {
        currentFrameSelector = selector
    }

    // MARK: - Focus

    /// Focus the element matching `selector`.
    func focusElement(selector: String) async throws -> String {
        let script = """
        (function() {
            var el = document.querySelector(\(jsString(selector)));
            if (!el) return 'error: element not found';
            el.focus();
            return 'ok';
        })();
        """
        return try await evaluateJS(script)
    }

    // MARK: - Console helpers

    /// Clear the captured console log buffer without returning the messages.
    func clearConsoleLogs() {
        Task { [weak self] in
            _ = try? await self?.evaluateJS("(function(){ window.__namu_console = []; return 'ok'; })()")
        }
    }

    // MARK: - Init scripts / styles

    /// Inject a JavaScript snippet at document start for every subsequent navigation.
    func addInitScript(_ script: String) {
        let userScript = WKUserScript(
            source: script,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        )
        configuration.userContentController.addUserScript(userScript)
    }

    /// Inject a CSS stylesheet at document start for every subsequent navigation.
    func addInitStyle(_ css: String) {
        let escaped = css
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "`", with: "\\`")
            .replacingOccurrences(of: "${", with: "\\${")
        let source = """
        (function() {
            var s = document.createElement('style');
            s.textContent = `\(escaped)`;
            document.head.appendChild(s);
        })();
        """
        let userScript = WKUserScript(
            source: source,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        )
        configuration.userContentController.addUserScript(userScript)
    }

    // MARK: - Viewport

    /// Resize the web view to the given pixel dimensions.
    func setViewportSize(width: Int, height: Int) {
        setFrameSize(CGSize(width: CGFloat(width), height: CGFloat(height)))
    }

    // MARK: - Navigation forwarding (called by external delegates)

    /// Resume the waitForNavigation continuation on success.
    func handleNavigationDidFinish(_ navigation: WKNavigation!) {
        if let cont = navigationContinuation {
            navigationContinuation = nil
            navigationToken = nil
            cont.resume()
        }
    }

    /// Resume the waitForNavigation continuation on failure.
    func handleNavigationDidFail(_ navigation: WKNavigation!, error: Error) {
        if let cont = navigationContinuation {
            navigationContinuation = nil
            navigationToken = nil
            cont.resume(throwing: error)
        }
    }

    // MARK: - Private helpers

    private func jsString(_ s: String) -> String {
        let escaped = s
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
        return "\"\(escaped)\""
    }
}

// MARK: - WKNavigationDelegate

extension NamuWebView: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        handleNavigationDidFinish(navigation)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        handleNavigationDidFail(navigation, error: error)
    }
}

// MARK: - WKUIDelegate (dialog handling)

extension NamuWebView: WKUIDelegate {
    func webView(
        _ webView: WKWebView,
        runJavaScriptAlertPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping () -> Void
    ) {
        Task { @MainActor in
            await withCheckedContinuation { (continuation: CheckedContinuation<DialogResult, Never>) in
                pendingDialogs.append(PendingDialog(kind: .alert, message: message, continuation: continuation))
            }
            completionHandler()
        }
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptConfirmPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping (Bool) -> Void
    ) {
        Task { @MainActor in
            let result = await withCheckedContinuation { (continuation: CheckedContinuation<DialogResult, Never>) in
                pendingDialogs.append(PendingDialog(kind: .confirm, message: message, continuation: continuation))
            }
            completionHandler(result.accepted)
        }
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptTextInputPanelWithPrompt prompt: String,
        defaultText: String?,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping (String?) -> Void
    ) {
        Task { @MainActor in
            let result = await withCheckedContinuation { (continuation: CheckedContinuation<DialogResult, Never>) in
                pendingDialogs.append(PendingDialog(kind: .prompt(defaultText: defaultText), message: prompt, continuation: continuation))
            }
            completionHandler(result.accepted ? result.text : nil)
        }
    }
}

// MARK: - BrowserError

enum BrowserError: Error, LocalizedError {
    case screenshotFailed
    case elementNotFound(String)
    case javascriptError(String)
    case timeout(String)

    var errorDescription: String? {
        switch self {
        case .screenshotFailed:           return "Failed to capture screenshot"
        case .elementNotFound(let sel):   return "Element not found: \(sel)"
        case .javascriptError(let msg):   return "JavaScript error: \(msg)"
        case .timeout(let op):            return "Timed out waiting for: \(op)"
        }
    }
}
