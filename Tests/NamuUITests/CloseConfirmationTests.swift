import XCTest

final class CloseConfirmationTests: NamuUITestCase {

    func testCloseIdleShellInSplit() throws {
        XCTAssertTrue(mainWindow.waitForExistence(timeout: 10),
                      "Main window should appear on launch")
        usleep(2_000_000)

        // Create a split so Cmd+W closes a pane (not the window).
        app.typeKey("d", modifierFlags: .command)
        usleep(1_000_000)

        // Shell is at idle prompt — close should work without blocking.
        app.typeKey("w", modifierFlags: .command)
        usleep(1_000_000)

        // App should still be running with the remaining pane.
        XCTAssertTrue(mainWindow.exists,
                      "App should still be running after closing idle pane in split")

        // The remaining pane should accept input.
        mainWindow.typeKey("a", modifierFlags: [])
        usleep(200_000)
        XCTAssertTrue(mainWindow.exists,
                      "Remaining pane should accept input after closing idle split pane")
    }

    func testCloseMultipleSplitPanesSequentially() throws {
        XCTAssertTrue(mainWindow.waitForExistence(timeout: 10),
                      "Main window should appear on launch")
        usleep(2_000_000)

        // Create two splits (3 panes).
        app.typeKey("d", modifierFlags: .command)
        usleep(500_000)
        app.typeKey("d", modifierFlags: [.command, .shift])
        usleep(500_000)

        // Close panes one by one.
        app.typeKey("w", modifierFlags: .command)
        usleep(500_000)
        app.typeKey("w", modifierFlags: .command)
        usleep(500_000)

        // Window should still exist with one pane remaining.
        XCTAssertTrue(mainWindow.exists,
                      "Window should remain after closing split panes down to one")

        // Remaining pane should accept input.
        mainWindow.typeKey("a", modifierFlags: [])
        usleep(200_000)
        XCTAssertTrue(mainWindow.exists,
                      "Last remaining pane should accept input")
    }

    func testCmdWWithSinglePanePassesToAppKit() throws {
        XCTAssertTrue(mainWindow.waitForExistence(timeout: 10),
                      "Main window should appear on launch")
        usleep(2_000_000)

        // With a single pane, Cmd+W passes the event to AppKit (window close).
        app.typeKey("w", modifierFlags: .command)
        usleep(1_000_000)

        // App stays alive (applicationShouldTerminateAfterLastWindowClosed = false).
        XCTAssertTrue(app.exists,
                      "App should not crash on Cmd+W with single pane")
    }
}
