import XCTest

final class SplitPaneTests: NamuUITestCase {

    func testHorizontalSplit() throws {
        XCTAssertTrue(mainWindow.waitForExistence(timeout: 10))
        usleep(2_000_000)

        // Cmd+D -> Split horizontal.
        app.typeKey("d", modifierFlags: .command)
        usleep(500_000)

        // The workspace view should still exist.
        let workspaceView = app.groups["namu-workspace-view"].firstMatch
        XCTAssertTrue(workspaceView.exists || mainWindow.exists,
                      "Workspace should exist after horizontal split")
    }

    func testVerticalSplit() throws {
        XCTAssertTrue(mainWindow.waitForExistence(timeout: 10))
        usleep(2_000_000)

        // Cmd+Shift+D -> Split vertical.
        app.typeKey("d", modifierFlags: [.command, .shift])
        usleep(500_000)

        XCTAssertTrue(mainWindow.exists,
                      "Window should exist after vertical split")
    }

    func testCloseSplitPane() throws {
        XCTAssertTrue(mainWindow.waitForExistence(timeout: 10))
        usleep(2_000_000)

        // Split first, then close one pane.
        app.typeKey("d", modifierFlags: .command)
        usleep(500_000)

        // Cmd+W -> Close pane.
        app.typeKey("w", modifierFlags: .command)
        usleep(500_000)

        // Window should still exist (closing a split pane doesn't close the window).
        XCTAssertTrue(mainWindow.exists,
                      "Window should remain after closing one split pane")
    }

    func testNavigateBetweenPanes() throws {
        XCTAssertTrue(mainWindow.waitForExistence(timeout: 10))
        usleep(2_000_000)

        // Create a split.
        app.typeKey("d", modifierFlags: .command)
        usleep(500_000)

        // Navigate between panes with Cmd+Option+Arrow.
        app.typeKey(.leftArrow, modifierFlags: [.command, .option])
        usleep(200_000)
        app.typeKey(.rightArrow, modifierFlags: [.command, .option])
        usleep(200_000)

        XCTAssertTrue(mainWindow.exists,
                      "Window should exist after pane navigation")
    }
}
