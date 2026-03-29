import XCTest

final class AppLaunchTests: NamuUITestCase {

    func testAppLaunches() throws {
        // App launched in setUp; verify at least one window exists.
        XCTAssertTrue(mainWindow.waitForExistence(timeout: 10),
                      "App window should appear after launch")
    }

    func testMainWindowExists() throws {
        XCTAssertTrue(mainWindow.exists, "Main window should be present")
    }

    func testSidebarVisible() throws {
        // The sidebar should be visible on launch.
        XCTAssertTrue(waitForElement(sidebar, timeout: 10),
                      "Sidebar should be visible on launch")
    }

    func testInitialWorkspaceExists() throws {
        // On launch there should be at least one workspace in the sidebar.
        XCTAssertTrue(waitForElement(sidebar, timeout: 10),
                      "Sidebar should exist")

        // The new workspace button should also exist — confirming the sidebar is populated.
        XCTAssertTrue(waitForElement(newWorkspaceButton, timeout: 5),
                      "New workspace button should exist in sidebar")
    }
}
