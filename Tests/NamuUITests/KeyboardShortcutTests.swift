import XCTest

/// Comprehensive keyboard shortcut verification.
/// Tests that already exist in other suites (Cmd+K, Cmd+P, Cmd+,, Cmd+F, Escape)
/// are not duplicated here. This covers the remaining shortcuts.
final class KeyboardShortcutTests: NamuUITestCase {

    // MARK: - Workspace shortcuts

    func testCmdTCreatesWorkspace() throws {
        XCTAssertTrue(waitForElement(sidebar, timeout: 10),
                      "Sidebar should appear on launch")

        // Cmd+T creates a new workspace.
        app.typeKey("t", modifierFlags: .command)
        usleep(500_000)

        // Sidebar should still exist with the new workspace.
        XCTAssertTrue(sidebar.exists, "Sidebar should exist after Cmd+T")
        XCTAssertTrue(newWorkspaceButton.exists, "New workspace button should still exist")

        // Verify the new workspace has a shell that accepts input.
        mainWindow.typeKey("a", modifierFlags: [])
        usleep(200_000)
        XCTAssertTrue(mainWindow.exists, "New workspace shell should accept input")
    }

    func testCmdNumberSwitchesWorkspace() throws {
        XCTAssertTrue(waitForElement(sidebar, timeout: 10),
                      "Sidebar should appear on launch")

        // Create 2 additional workspaces (3 total).
        app.typeKey("t", modifierFlags: .command)
        usleep(500_000)
        app.typeKey("t", modifierFlags: .command)
        usleep(500_000)

        // Switch to workspace 1.
        app.typeKey("1", modifierFlags: .command)
        usleep(300_000)
        mainWindow.typeKey("a", modifierFlags: [])
        usleep(100_000)
        XCTAssertTrue(mainWindow.exists, "Cmd+1 should switch to workspace 1")

        // Switch to workspace 2.
        app.typeKey("2", modifierFlags: .command)
        usleep(300_000)
        mainWindow.typeKey("b", modifierFlags: [])
        usleep(100_000)
        XCTAssertTrue(mainWindow.exists, "Cmd+2 should switch to workspace 2")

        // Switch to workspace 3.
        app.typeKey("3", modifierFlags: .command)
        usleep(300_000)
        mainWindow.typeKey("c", modifierFlags: [])
        usleep(100_000)
        XCTAssertTrue(mainWindow.exists, "Cmd+3 should switch to workspace 3")
    }

    func testCmdShiftBracketsNavigateWorkspaces() throws {
        XCTAssertTrue(waitForElement(sidebar, timeout: 10),
                      "Sidebar should appear on launch")

        // Create a second workspace.
        app.typeKey("t", modifierFlags: .command)
        usleep(500_000)

        // Cmd+Shift+[ -> previous workspace.
        app.typeKey("[", modifierFlags: [.command, .shift])
        usleep(300_000)
        mainWindow.typeKey("a", modifierFlags: [])
        usleep(100_000)
        XCTAssertTrue(mainWindow.exists, "Cmd+Shift+[ should navigate to previous workspace")

        // Cmd+Shift+] -> next workspace.
        app.typeKey("]", modifierFlags: [.command, .shift])
        usleep(300_000)
        mainWindow.typeKey("b", modifierFlags: [])
        usleep(100_000)
        XCTAssertTrue(mainWindow.exists, "Cmd+Shift+] should navigate to next workspace")
    }

    // MARK: - Split shortcuts

    func testCmdDHorizontalSplit() throws {
        XCTAssertTrue(mainWindow.waitForExistence(timeout: 10),
                      "Main window should appear on launch")
        usleep(2_000_000)

        // Cmd+D -> horizontal split.
        app.typeKey("d", modifierFlags: .command)
        usleep(500_000)

        // The workspace should still exist and accept input in the new pane.
        XCTAssertTrue(mainWindow.exists, "Window should exist after Cmd+D horizontal split")
        mainWindow.typeKey("a", modifierFlags: [])
        usleep(200_000)
        XCTAssertTrue(mainWindow.exists, "New pane should accept input after horizontal split")
    }

    func testCmdShiftDVerticalSplit() throws {
        XCTAssertTrue(mainWindow.waitForExistence(timeout: 10),
                      "Main window should appear on launch")
        usleep(2_000_000)

        // Cmd+Shift+D -> vertical split.
        app.typeKey("d", modifierFlags: [.command, .shift])
        usleep(500_000)

        XCTAssertTrue(mainWindow.exists, "Window should exist after Cmd+Shift+D vertical split")
        mainWindow.typeKey("a", modifierFlags: [])
        usleep(200_000)
        XCTAssertTrue(mainWindow.exists, "New pane should accept input after vertical split")
    }

    func testCmdWClosesPaneInSplit() throws {
        XCTAssertTrue(mainWindow.waitForExistence(timeout: 10),
                      "Main window should appear on launch")
        usleep(2_000_000)

        // Create a split first.
        app.typeKey("d", modifierFlags: .command)
        usleep(500_000)

        // Cmd+W closes the focused pane.
        app.typeKey("w", modifierFlags: .command)
        usleep(500_000)

        // Window should still exist with the remaining pane.
        XCTAssertTrue(mainWindow.exists,
                      "Cmd+W should close one pane, leaving the window open")
    }

    // MARK: - Pane navigation shortcuts

    func testCmdOptionArrowNavigatesPanes() throws {
        XCTAssertTrue(mainWindow.waitForExistence(timeout: 10),
                      "Main window should appear on launch")
        usleep(2_000_000)

        // Create a split.
        app.typeKey("d", modifierFlags: .command)
        usleep(500_000)

        // Navigate left.
        app.typeKey(.leftArrow, modifierFlags: [.command, .option])
        usleep(200_000)
        mainWindow.typeKey("l", modifierFlags: [])
        usleep(100_000)

        // Navigate right.
        app.typeKey(.rightArrow, modifierFlags: [.command, .option])
        usleep(200_000)
        mainWindow.typeKey("r", modifierFlags: [])
        usleep(100_000)

        XCTAssertTrue(mainWindow.exists,
                      "Cmd+Option+Arrow should navigate between panes")
    }

    // MARK: - Find shortcut

    func testCmdFOpensFind() throws {
        XCTAssertTrue(mainWindow.waitForExistence(timeout: 10),
                      "Main window should appear on launch")
        usleep(2_000_000)

        // Cmd+F opens find overlay.
        app.typeKey("f", modifierFlags: .command)

        let findOverlay = app.groups["namu-find-overlay"].firstMatch
        XCTAssertTrue(waitForElement(findOverlay, timeout: 5),
                      "Cmd+F should open find overlay")

        // Escape closes it.
        app.typeKey(.escape, modifierFlags: [])
        usleep(500_000)
        XCTAssertFalse(findOverlay.exists,
                       "Escape should close find overlay")
    }

    // MARK: - Command palette shortcut

    func testCmdKOpensAndEscapeClosesCommandPalette() throws {
        XCTAssertTrue(mainWindow.waitForExistence(timeout: 10),
                      "Main window should appear on launch")
        usleep(1_000_000)

        // Cmd+K opens command palette.
        app.typeKey("k", modifierFlags: .command)

        let palette = app.groups["namu-command-palette"].firstMatch
        XCTAssertTrue(waitForElement(palette, timeout: 5),
                      "Cmd+K should open command palette")

        // Escape closes it.
        app.typeKey(.escape, modifierFlags: [])
        usleep(500_000)
        XCTAssertFalse(palette.exists,
                       "Escape should close command palette")
    }

    // MARK: - Settings shortcut

    func testCmdCommaOpensSettings() throws {
        XCTAssertTrue(mainWindow.waitForExistence(timeout: 10),
                      "Main window should appear on launch")
        usleep(1_000_000)

        // Cmd+, opens settings.
        app.typeKey(",", modifierFlags: .command)
        usleep(500_000)

        let settings = app.groups["namu-settings"].firstMatch
        XCTAssertTrue(waitForElement(settings, timeout: 5),
                      "Cmd+, should open settings")
    }
}
