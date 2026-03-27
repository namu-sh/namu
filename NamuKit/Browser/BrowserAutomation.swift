import Foundation
import WebKit

// MARK: - BrowserAutomation

/// Coordinates JavaScript-based automation actions on a NamuWebView.
/// Actions are queued and executed sequentially with configurable delays between steps.
@MainActor
final class BrowserAutomation {

    // MARK: - Types

    enum Action {
        case navigate(URL)
        case click(selector: String)
        case type(selector: String, text: String)
        case hover(selector: String)
        case getText(selector: String, into: (String) -> Void)
        case getAttribute(selector: String, attribute: String, into: (String) -> Void)
        case fillForm([String: String])
        case executeJS(String, result: ((String) -> Void)?)
        case wait(seconds: TimeInterval)
        case screenshot(result: (Data) -> Void)
        case waitForSelector(selector: String, timeout: TimeInterval)
        case waitForNavigation(timeout: TimeInterval)
        case dismissDialog(accept: Bool, text: String?)
        case consoleLogs(result: ([ConsoleMessage]) -> Void)
        case getCookies(url: URL?, result: ([[String: String]]) -> Void)
        case setCookie([String: String])
        case deleteCookie(name: String, domain: String)
        case deleteAllCookies
        case getStorageItem(key: String, result: (String) -> Void)
        case setStorageItem(key: String, value: String)
        case clearStorage
        case setViewport(width: Int, height: Int)
        case scroll(x: Double, y: Double)
        case scrollIntoView(selector: String)
        case press(selector: String, key: String)
        case check(selector: String)
        case uncheck(selector: String)
        case selectOption(selector: String, value: String)
        case selectFrame(selector: String?)
        case focusElement(selector: String)
        case clearConsoleLogs
        case addInitScript(String)
        case addInitStyle(String)
        case waitForDownload(timeout: TimeInterval, result: (BrowserDownloadTracker.DownloadEvent) -> Void)
    }

    struct AutomationResult {
        let stepIndex: Int
        let action: String
        let output: String?
        let error: Error?
        var succeeded: Bool { error == nil }
    }

    // MARK: - Properties

    private weak var webView: NamuWebView?
    private var stepDelay: TimeInterval

    /// Callback fired after each action completes.
    var onStepComplete: ((AutomationResult) -> Void)?

    // MARK: - Init

    init(webView: NamuWebView, stepDelay: TimeInterval = 0.3) {
        self.webView = webView
        self.stepDelay = stepDelay
    }

    // MARK: - Execution

    /// Run a sequence of actions, returning the results in order.
    /// Each step fires `onStepComplete` as it finishes.
    @discardableResult
    func run(_ actions: [Action]) async -> [AutomationResult] {
        var results: [AutomationResult] = []

        for (idx, action) in actions.enumerated() {
            guard let webView else { break }
            let result = await execute(action: action, index: idx, webView: webView)
            results.append(result)
            onStepComplete?(result)
            if stepDelay > 0 && idx < actions.count - 1 {
                try? await Task.sleep(nanoseconds: UInt64(stepDelay * 1_000_000_000))
            }
        }
        return results
    }

    // MARK: - Individual action execution

    private func execute(action: Action, index: Int, webView: NamuWebView) async -> AutomationResult {
        let label = actionLabel(action)
        do {
            switch action {
            case .navigate(let url):
                await withCheckedContinuation { continuation in
                    webView.load(URLRequest(url: url))
                    // Give navigation a moment to start before continuing.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        continuation.resume()
                    }
                }
                return AutomationResult(stepIndex: index, action: label, output: url.absoluteString, error: nil)

            case .click(let selector):
                let out = try await webView.click(selector: selector)
                return AutomationResult(stepIndex: index, action: label, output: out, error: nil)

            case .type(let selector, let text):
                let out = try await webView.type(selector: selector, text: text)
                return AutomationResult(stepIndex: index, action: label, output: out, error: nil)

            case .hover(let selector):
                let out = try await webView.hover(selector: selector)
                return AutomationResult(stepIndex: index, action: label, output: out, error: nil)

            case .getText(let selector, let into):
                let out = try await webView.getText(selector: selector)
                into(out)
                return AutomationResult(stepIndex: index, action: label, output: out, error: nil)

            case .getAttribute(let selector, let attribute, let into):
                let out = try await webView.getAttribute(selector: selector, attribute: attribute)
                into(out)
                return AutomationResult(stepIndex: index, action: label, output: out, error: nil)

            case .fillForm(let fields):
                let out = try await webView.fillForm(fields)
                return AutomationResult(stepIndex: index, action: label, output: out, error: nil)

            case .executeJS(let script, let result):
                let out = try await webView.evaluateJS(script)
                result?(out)
                return AutomationResult(stepIndex: index, action: label, output: out, error: nil)

            case .wait(let seconds):
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                return AutomationResult(stepIndex: index, action: label, output: nil, error: nil)

            case .screenshot(let result):
                let data = try await webView.takeScreenshot()
                result(data)
                return AutomationResult(stepIndex: index, action: label, output: "\(data.count) bytes", error: nil)

            case .waitForSelector(let selector, let timeout):
                let out = try await webView.waitForSelector(selector, timeout: timeout)
                return AutomationResult(stepIndex: index, action: label, output: out, error: nil)

            case .waitForNavigation(let timeout):
                try await webView.waitForNavigation(timeout: timeout)
                return AutomationResult(stepIndex: index, action: label, output: "ok", error: nil)

            case .dismissDialog(let accept, let text):
                webView.dismissDialog(accept: accept, text: text)
                return AutomationResult(stepIndex: index, action: label, output: "ok", error: nil)

            case .consoleLogs(let result):
                let logs = try await webView.consoleLogs()
                result(logs)
                return AutomationResult(stepIndex: index, action: label, output: "\(logs.count) messages", error: nil)

            case .getCookies(let url, let result):
                let cookies = await webView.getCookiesAsDictionaries(url: url)
                result(cookies)
                return AutomationResult(stepIndex: index, action: label, output: "\(cookies.count) cookies", error: nil)

            case .setCookie(let props):
                await webView.setCookieProperties(props)
                return AutomationResult(stepIndex: index, action: label, output: "ok", error: nil)

            case .deleteCookie(let name, let domain):
                await webView.deleteCookie(name: name, domain: domain)
                return AutomationResult(stepIndex: index, action: label, output: "ok", error: nil)

            case .deleteAllCookies:
                await webView.deleteAllCookies()
                return AutomationResult(stepIndex: index, action: label, output: "ok", error: nil)

            case .getStorageItem(let key, let result):
                let value = try await webView.getStorageItem(key: key)
                result(value)
                return AutomationResult(stepIndex: index, action: label, output: value, error: nil)

            case .setStorageItem(let key, let value):
                try await webView.setStorageItem(key: key, value: value)
                return AutomationResult(stepIndex: index, action: label, output: "ok", error: nil)

            case .clearStorage:
                try await webView.clearStorage()
                return AutomationResult(stepIndex: index, action: label, output: "ok", error: nil)

            case .setViewport(let width, let height):
                webView.setViewportSize(width: width, height: height)
                return AutomationResult(stepIndex: index, action: label, output: "\(width)x\(height)", error: nil)

            case .scroll(let x, let y):
                let out = try await webView.scroll(x: x, y: y)
                return AutomationResult(stepIndex: index, action: label, output: out, error: nil)

            case .scrollIntoView(let selector):
                let out = try await webView.scrollIntoView(selector: selector)
                return AutomationResult(stepIndex: index, action: label, output: out, error: nil)

            case .press(let selector, let key):
                let out = try await webView.press(selector: selector, key: key)
                return AutomationResult(stepIndex: index, action: label, output: out, error: nil)

            case .check(let selector):
                let out = try await webView.check(selector: selector)
                return AutomationResult(stepIndex: index, action: label, output: out, error: nil)

            case .uncheck(let selector):
                let out = try await webView.uncheck(selector: selector)
                return AutomationResult(stepIndex: index, action: label, output: out, error: nil)

            case .selectOption(let selector, let value):
                let out = try await webView.selectOption(selector: selector, value: value)
                return AutomationResult(stepIndex: index, action: label, output: out, error: nil)

            case .selectFrame(let selector):
                webView.selectFrame(selector)
                return AutomationResult(stepIndex: index, action: label, output: selector ?? "main", error: nil)

            case .focusElement(let selector):
                let out = try await webView.focusElement(selector: selector)
                return AutomationResult(stepIndex: index, action: label, output: out, error: nil)

            case .clearConsoleLogs:
                webView.clearConsoleLogs()
                return AutomationResult(stepIndex: index, action: label, output: "ok", error: nil)

            case .addInitScript(let script):
                webView.addInitScript(script)
                return AutomationResult(stepIndex: index, action: label, output: "ok", error: nil)

            case .addInitStyle(let css):
                webView.addInitStyle(css)
                return AutomationResult(stepIndex: index, action: label, output: "ok", error: nil)

            case .waitForDownload(let timeout, let result):
                let event = try await BrowserDownloadTracker.shared.waitForDownload(timeout: timeout)
                result(event)
                return AutomationResult(stepIndex: index, action: label, output: event.filename ?? "download", error: nil)
            }
        } catch {
            return AutomationResult(stepIndex: index, action: label, output: nil, error: error)
        }
    }

    // MARK: - Helpers

    private func actionLabel(_ action: Action) -> String {
        switch action {
        case .navigate(let url):                    return "navigate(\(url.host ?? url.absoluteString))"
        case .click(let sel):                       return "click(\(sel))"
        case .type(let sel, _):                     return "type(\(sel))"
        case .hover(let sel):                       return "hover(\(sel))"
        case .getText(let sel, _):                  return "getText(\(sel))"
        case .getAttribute(let sel, let attr, _):   return "getAttribute(\(sel), \(attr))"
        case .fillForm(let fields):                 return "fillForm(\(fields.keys.joined(separator: ", ")))"
        case .executeJS(let js, _):                 return "executeJS(\(js.prefix(40)))"
        case .wait(let s):                          return "wait(\(s)s)"
        case .screenshot:                           return "screenshot()"
        case .waitForSelector(let sel, let t):      return "waitForSelector(\(sel), \(t)s)"
        case .waitForNavigation(let t):             return "waitForNavigation(\(t)s)"
        case .dismissDialog(let accept, _):         return "dismissDialog(accept:\(accept))"
        case .consoleLogs:                          return "consoleLogs()"
        case .getCookies:                           return "getCookies()"
        case .setCookie:                            return "setCookie()"
        case .deleteCookie(let n, let d):           return "deleteCookie(\(n), \(d))"
        case .deleteAllCookies:                     return "deleteAllCookies()"
        case .getStorageItem(let k, _):             return "getStorageItem(\(k))"
        case .setStorageItem(let k, _):             return "setStorageItem(\(k))"
        case .clearStorage:                         return "clearStorage()"
        case .setViewport(let w, let h):            return "setViewport(\(w)x\(h))"
        case .scroll(let x, let y):                 return "scroll(\(x), \(y))"
        case .scrollIntoView(let sel):              return "scrollIntoView(\(sel))"
        case .press(let sel, let key):              return "press(\(sel), \(key))"
        case .check(let sel):                       return "check(\(sel))"
        case .uncheck(let sel):                     return "uncheck(\(sel))"
        case .selectOption(let sel, let val):       return "selectOption(\(sel), \(val))"
        case .selectFrame(let sel):                 return "selectFrame(\(sel ?? "main"))"
        case .focusElement(let sel):                return "focusElement(\(sel))"
        case .clearConsoleLogs:                     return "clearConsoleLogs()"
        case .addInitScript:                        return "addInitScript()"
        case .addInitStyle:                         return "addInitStyle()"
        case .waitForDownload(let t, _):            return "waitForDownload(\(t)s)"
        }
    }
}

// MARK: - Recipe helpers

extension BrowserAutomation {
    /// Convenience: navigate then wait for a selector to appear (polls up to `timeout` seconds).
    func navigateAndWaitFor(
        url: URL,
        selector: String,
        timeout: TimeInterval = 10,
        pollInterval: TimeInterval = 0.5
    ) async -> Bool {
        await run([.navigate(url)])
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            guard let wv = webView else { return false }
            if let text = try? await wv.getText(selector: selector), !text.hasPrefix("error:") {
                return true
            }
            try? await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
        }
        return false
    }
}
