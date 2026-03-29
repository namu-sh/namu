import XCTest

class NamuUITestCase: XCTestCase {
    var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments.append("--ui-testing")
        app.launch()
    }

    override func tearDownWithError() throws {
        app.terminate()
        app = nil
        try super.tearDownWithError()
    }

    // MARK: - Helpers

    /// Wait for an element to exist with timeout.
    @discardableResult
    func waitForElement(_ element: XCUIElement, timeout: TimeInterval = 5) -> Bool {
        element.waitForExistence(timeout: timeout)
    }

    /// Type a string character by character into the focused element.
    func typeString(_ text: String, into element: XCUIElement? = nil) {
        let target = element ?? mainWindow
        for char in text {
            target.typeKey(String(char), modifierFlags: [])
        }
    }

    /// The main window.
    var mainWindow: XCUIElement {
        app.windows.firstMatch
    }

    /// The sidebar (group with namu-sidebar identifier).
    var sidebar: XCUIElement {
        app.groups["namu-sidebar"].firstMatch
    }

    /// The workspace content area.
    var workspaceContent: XCUIElement {
        app.groups["namu-workspace-content"].firstMatch
    }

    /// The new workspace button.
    var newWorkspaceButton: XCUIElement {
        app.groups["namu-new-workspace-button"].firstMatch
    }
}
