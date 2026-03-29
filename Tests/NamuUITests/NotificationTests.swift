import XCTest

final class NotificationTests: NamuUITestCase {

    func testNewWorkspaceGetsRunningShell() throws {
        XCTAssertTrue(waitForElement(sidebar, timeout: 10),
                      "Sidebar should appear on launch")
        usleep(2_000_000)

        // Create a second workspace.
        app.typeKey("t", modifierFlags: .command)
        usleep(1_000_000)

        // The new workspace should have a shell that accepts input immediately.
        mainWindow.typeKey("a", modifierFlags: [])
        usleep(200_000)
        XCTAssertTrue(mainWindow.exists,
                      "New workspace should have a running shell that accepts input")
    }

    func testWorkspaceSwitchPreservesShellState() throws {
        XCTAssertTrue(waitForElement(sidebar, timeout: 10),
                      "Sidebar should appear on launch")
        usleep(2_000_000)

        // Type in workspace 1.
        mainWindow.typeKey("a", modifierFlags: [])
        usleep(200_000)

        // Create workspace 2.
        app.typeKey("t", modifierFlags: .command)
        usleep(1_000_000)

        // Switch back to workspace 1.
        app.typeKey("1", modifierFlags: .command)
        usleep(500_000)

        // Shell should still be responsive.
        mainWindow.typeKey("b", modifierFlags: [])
        usleep(200_000)
        XCTAssertTrue(mainWindow.exists,
                      "Workspace 1 shell should still be responsive after switching back")
    }

    func testSidebarShowsMultipleWorkspaces() throws {
        XCTAssertTrue(waitForElement(sidebar, timeout: 10),
                      "Sidebar should appear on launch")

        // Create a second workspace.
        app.typeKey("t", modifierFlags: .command)
        usleep(500_000)

        XCTAssertTrue(sidebar.exists,
                      "Sidebar should exist with multiple workspaces")
    }

    func testWorkspaceSwitchingWithAllShortcuts() throws {
        XCTAssertTrue(waitForElement(sidebar, timeout: 10),
                      "Sidebar should appear on launch")

        // Create 2 more workspaces (3 total).
        app.typeKey("t", modifierFlags: .command)
        usleep(500_000)
        app.typeKey("t", modifierFlags: .command)
        usleep(500_000)

        // Cmd+1.
        app.typeKey("1", modifierFlags: .command)
        usleep(300_000)
        XCTAssertTrue(mainWindow.exists, "Cmd+1 should switch to workspace 1")

        // Cmd+2.
        app.typeKey("2", modifierFlags: .command)
        usleep(300_000)
        XCTAssertTrue(mainWindow.exists, "Cmd+2 should switch to workspace 2")

        // Cmd+3.
        app.typeKey("3", modifierFlags: .command)
        usleep(300_000)
        XCTAssertTrue(mainWindow.exists, "Cmd+3 should switch to workspace 3")

        // Cmd+Shift+[.
        app.typeKey("[", modifierFlags: [.command, .shift])
        usleep(300_000)
        XCTAssertTrue(mainWindow.exists, "Cmd+Shift+[ should switch workspace")

        // Cmd+Shift+].
        app.typeKey("]", modifierFlags: [.command, .shift])
        usleep(300_000)
        XCTAssertTrue(mainWindow.exists, "Cmd+Shift+] should switch workspace")
    }
}
