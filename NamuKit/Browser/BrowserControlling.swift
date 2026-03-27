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
}
