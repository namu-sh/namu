import Foundation
import WebKit

// MARK: - BrowserControlling

/// Protocol that a browser panel view-model must conform to so the IPC layer
/// (BrowserCommands, in NamuKit) can drive the browser without importing NamuUI.
@MainActor
protocol BrowserControlling: AnyObject {
    /// The pane ID this browser panel occupies.
    var paneID: UUID { get }
    /// Current URL string shown in the address bar.
    var currentURL: String { get }
    /// Current page title.
    var currentTitle: String { get }

    func navigate(to urlString: String)
    func goBack()
    func goForward()
    func reload()
    /// Evaluate arbitrary JavaScript and return the result as a String.
    func evaluateJS(_ script: String) async throws -> String
    /// Click the element matching `selector`.
    func click(selector: String) async throws -> String
    /// Type text into the element matching `selector`.
    func type(selector: String, text: String) async throws -> String
    /// Hover over the element matching `selector`.
    func hover(selector: String) async throws -> String
    /// Get the text content of the element matching `selector`.
    func getText(selector: String) async throws -> String
    /// Get an attribute value from the element matching `selector`.
    func getAttribute(selector: String, attribute: String) async throws -> String
    /// Take a screenshot and return PNG data.
    func takeScreenshot() async throws -> Data
    /// Find text on the page; returns match count or highlight info.
    func findText(_ text: String) async throws -> String

    // MARK: Advanced automation
    /// Wait for a CSS selector to appear in the DOM.
    func waitForSelector(_ selector: String, timeout: TimeInterval) async throws -> String
    /// Wait for the next navigation to complete.
    func waitForNavigation(timeout: TimeInterval) async throws
    /// Dismiss the front-most pending JS dialog.
    func dismissDialog(accept: Bool, text: String?) async throws
    /// Retrieve captured console messages.
    func consoleLogs() async throws -> [ConsoleMessage]
    /// Get cookies, optionally filtered by URL.
    func getCookies(url: URL?) async throws -> [[String: String]]
    /// Set a cookie from a properties dictionary.
    func setCookieProperties(_ props: [String: String]) async throws
    /// Delete a cookie by name and domain.
    func deleteCookie(name: String, domain: String) async throws
    /// Delete all cookies.
    func deleteAllCookies() async throws
    /// Get a localStorage item.
    func getStorageItem(key: String) async throws -> String
    /// Set a localStorage item.
    func setStorageItem(key: String, value: String) async throws
    /// Clear localStorage.
    func clearStorage() async throws
    /// Resize the browser viewport.
    func setViewportSize(width: Int, height: Int) async throws

    // MARK: Browser V2 automation
    /// Scroll the page by (x, y) pixels.
    func scroll(x: Double, y: Double) async throws -> String
    /// Scroll the element matching `selector` into view.
    func scrollIntoView(selector: String) async throws -> String
    /// Dispatch a keyboard event on the element matching `selector`.
    func press(selector: String, key: String) async throws -> String
    /// Check a checkbox element.
    func check(selector: String) async throws -> String
    /// Uncheck a checkbox element.
    func uncheck(selector: String) async throws -> String
    /// Set a <select> element value and dispatch change.
    func selectOption(selector: String, value: String) async throws -> String
    /// Switch JS evaluation context to an iframe (nil = main frame).
    func selectFrame(_ selector: String?)
    /// Focus the element matching `selector`.
    func focusElement(selector: String) async throws -> String
    /// Clear the captured console log buffer.
    func clearConsoleLogs()
    /// Inject a JavaScript snippet at document start.
    func addInitScript(_ script: String)
    /// Inject a CSS stylesheet at document start.
    func addInitStyle(_ css: String)

    // MARK: Developer Tools
    /// Toggle the Web Inspector panel.
    func toggleDeveloperTools()
    /// Show the Web Inspector console tab.
    func showDeveloperToolsConsole()

    // MARK: Browser V3 automation (US-017)

    /// Double-click the element matching `selector`.
    func dblclick(selector: String) async throws -> String
    /// Clear + type into the element matching `selector` (Playwright fill).
    func fill(selector: String, text: String) async throws -> String
    /// Dispatch a keydown event on the element matching `selector`.
    func keydown(selector: String, key: String) async throws -> String
    /// Dispatch a keyup event on the element matching `selector`.
    func keyup(selector: String, key: String) async throws -> String
    /// Get the innerHTML of the element matching `selector`.
    func getInnerHTML(selector: String) async throws -> String
    /// Get the value property of the input matching `selector`.
    func getInputValue(selector: String) async throws -> String
    /// Count elements matching `selector`.
    func countElements(selector: String) async throws -> Int
    /// Get the bounding box of the element matching `selector` as JSON.
    func getBoundingBox(selector: String) async throws -> String
    /// Get the computed styles of the element matching `selector` as JSON.
    func getComputedStyles(selector: String) async throws -> String
    /// Check if the element matching `selector` is visible.
    func isVisible(selector: String) async throws -> Bool
    /// Check if the element matching `selector` is enabled.
    func isEnabled(selector: String) async throws -> Bool
    /// Check if the checkbox matching `selector` is checked.
    func isChecked(selector: String) async throws -> Bool
    /// Find elements by ARIA role.
    func findByRole(_ role: String) async throws -> String
    /// Find elements by text content.
    func findByText(_ text: String) async throws -> String
    /// Find elements by label text.
    func findByLabel(_ text: String) async throws -> String
    /// Find elements by placeholder attribute.
    func findByPlaceholder(_ text: String) async throws -> String
    /// Find elements by alt attribute.
    func findByAlt(_ text: String) async throws -> String
    /// Find elements by title attribute.
    func findByTitle(_ text: String) async throws -> String
    /// Find elements by data-testid attribute.
    func findByTestId(_ testId: String) async throws -> String
    /// Return the first element matching `selector`.
    func findFirst(selector: String) async throws -> String
    /// Return the last element matching `selector`.
    func findLast(selector: String) async throws -> String
    /// Return the nth element matching `selector`.
    func findNth(selector: String, index: Int) async throws -> String
    /// Accept the front-most pending dialog.
    func acceptDialog(text: String?) async throws
    /// Clear all cookies.
    func clearAllCookies() async throws
    /// Highlight the element matching `selector` visually.
    func highlight(selector: String) async throws -> String
    /// Save the current page scroll/form state as JSON.
    func savePageState() async throws -> String
    /// Restore page state from previously saved JSON.
    func loadPageState(_ state: String) async throws -> String
    /// Return recently intercepted network requests as JSON.
    func networkRequests() async throws -> String
    /// Inject fetch/XHR interceptors and reset the trace buffer.
    func startNetworkTrace() async throws
    /// Read the trace buffer, restore original fetch/XHR, and return entries as JSON.
    func stopNetworkTrace() async throws -> String
}

// MARK: - BrowserRegistry

/// Registry that maps pane IDs to live BrowserControlling instances.
/// Owned by ServiceContainer and populated by BrowserPanelView on appear/disappear.
@MainActor
final class BrowserRegistry {
    static let shared = BrowserRegistry()
    private var controllers: [UUID: any BrowserControlling] = [:]

    func register(_ controller: any BrowserControlling) {
        controllers[controller.paneID] = controller
    }

    func unregister(paneID: UUID) {
        controllers.removeValue(forKey: paneID)
    }

    func controller(for paneID: UUID) -> (any BrowserControlling)? {
        controllers[paneID]
    }

    /// Returns the controller for the given pane ID, or any registered controller
    /// if `paneID` is nil (useful for single-browser scenarios).
    func resolve(paneID: UUID?) -> (any BrowserControlling)? {
        if let id = paneID { return controllers[id] }
        return controllers.values.first
    }

    /// Return all registered controllers.
    func allControllers() -> [any BrowserControlling] {
        Array(controllers.values)
    }
}

// MARK: - Notification names for tab management

extension Notification.Name {
    /// Posted when the IPC layer requests a new browser tab.
    static let browserTabNew    = Notification.Name("namu.browser.tab.new")
    /// Posted when the IPC layer requests switching to a tab by surface_id.
    static let browserTabSwitch = Notification.Name("namu.browser.tab.switch")
    /// Posted when the IPC layer requests closing a tab by surface_id.
    static let browserTabClose  = Notification.Name("namu.browser.tab.close")
}
