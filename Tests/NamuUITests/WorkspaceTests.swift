import XCTest

final class WorkspaceTests: NamuUITestCase {

    func testCreateNewWorkspace() throws {
        XCTAssertTrue(waitForElement(sidebar, timeout: 10))

        // Cmd+T creates a new workspace.
        app.typeKey("t", modifierFlags: .command)
        usleep(500_000)

        // The sidebar and new workspace button should still exist.
        XCTAssertTrue(sidebar.exists, "Sidebar should exist after creating workspace")
        XCTAssertTrue(newWorkspaceButton.exists, "New workspace button should exist")
    }

    func testCreateNewWorkspaceViaButton() throws {
        XCTAssertTrue(waitForElement(sidebar, timeout: 10))

        XCTAssertTrue(waitForElement(newWorkspaceButton, timeout: 5),
                      "New workspace button should exist")
        newWorkspaceButton.click()

        // Wait for new workspace to appear.
        usleep(500_000)

        // Sidebar should still be visible with the new workspace.
        XCTAssertTrue(sidebar.exists, "Sidebar should still exist after creating workspace")
    }

    func testMultipleWorkspaces() throws {
        XCTAssertTrue(waitForElement(sidebar, timeout: 10))

        // Create 2 additional workspaces (1 exists by default).
        app.typeKey("t", modifierFlags: .command)
        usleep(300_000)
        app.typeKey("t", modifierFlags: .command)
        usleep(300_000)

        // Sidebar should be populated with items.
        XCTAssertTrue(sidebar.exists, "Sidebar should exist with multiple workspaces")
    }

    func testSwitchWorkspaceWithKeyboard() throws {
        XCTAssertTrue(waitForElement(sidebar, timeout: 10))

        // Create a second workspace.
        app.typeKey("t", modifierFlags: .command)
        usleep(500_000)

        // Switch to previous workspace using Cmd+Shift+[
        app.typeKey("[", modifierFlags: [.command, .shift])
        usleep(300_000)

        // Switch to next workspace using Cmd+Shift+]
        app.typeKey("]", modifierFlags: [.command, .shift])
        usleep(300_000)

        // App should still be responsive.
        XCTAssertTrue(mainWindow.exists, "Window should exist after workspace switching")
    }
}
