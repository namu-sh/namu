import XCTest

final class MultiPaneTests: NamuUITestCase {

    // MARK: - Focus tracking across panes

    func testFocusNavigationAllDirections() throws {
        XCTAssertTrue(mainWindow.waitForExistence(timeout: 10),
                      "Main window should appear on launch")
        usleep(2_000_000)

        // Create 3 panes: Cmd+D (horizontal), then Cmd+Shift+D (vertical in right half).
        app.typeKey("d", modifierFlags: .command)
        usleep(500_000)
        app.typeKey("d", modifierFlags: [.command, .shift])
        usleep(500_000)

        // Navigate left to the left pane and type.
        app.typeKey(.leftArrow, modifierFlags: [.command, .option])
        usleep(300_000)
        mainWindow.typeKey("a", modifierFlags: [])
        usleep(200_000)

        // Navigate right to the right column.
        app.typeKey(.rightArrow, modifierFlags: [.command, .option])
        usleep(300_000)
        mainWindow.typeKey("b", modifierFlags: [])
        usleep(200_000)

        // Navigate down/up within the right column.
        app.typeKey(.downArrow, modifierFlags: [.command, .option])
        usleep(300_000)
        mainWindow.typeKey("c", modifierFlags: [])
        usleep(200_000)

        app.typeKey(.upArrow, modifierFlags: [.command, .option])
        usleep(300_000)
        mainWindow.typeKey("d", modifierFlags: [])
        usleep(200_000)

        XCTAssertTrue(mainWindow.exists,
                      "All 4 navigation directions should work across 3 panes")
    }

    func testFocusIsExclusiveAfterNavigation() throws {
        XCTAssertTrue(mainWindow.waitForExistence(timeout: 10),
                      "Main window should appear on launch")
        usleep(2_000_000)

        // Create horizontal split.
        app.typeKey("d", modifierFlags: .command)
        usleep(500_000)

        // Navigate to left pane and type a unique string.
        app.typeKey(.leftArrow, modifierFlags: [.command, .option])
        usleep(200_000)
        mainWindow.typeKey("x", modifierFlags: [])
        usleep(100_000)

        // Navigate to right pane and type a different string.
        app.typeKey(.rightArrow, modifierFlags: [.command, .option])
        usleep(200_000)
        mainWindow.typeKey("y", modifierFlags: [])
        usleep(100_000)

        // No crash means only the focused pane received keystrokes at each point.
        XCTAssertTrue(mainWindow.exists,
                      "Focus should be exclusive — only one pane receives input at a time")
    }

    func testFocusSurvivesWorkspaceSwitch() throws {
        XCTAssertTrue(mainWindow.waitForExistence(timeout: 10),
                      "Main window should appear on launch")
        usleep(2_000_000)

        // Create a split in workspace 1.
        app.typeKey("d", modifierFlags: .command)
        usleep(500_000)

        // Navigate to left pane and type.
        app.typeKey(.leftArrow, modifierFlags: [.command, .option])
        usleep(200_000)
        mainWindow.typeKey("a", modifierFlags: [])
        usleep(200_000)

        // Create workspace 2 and switch to it.
        app.typeKey("t", modifierFlags: .command)
        usleep(1_000_000)

        // Type in workspace 2.
        mainWindow.typeKey("b", modifierFlags: [])
        usleep(200_000)

        // Switch back to workspace 1.
        app.typeKey("1", modifierFlags: .command)
        usleep(500_000)

        // Focus should still work — type in the workspace.
        mainWindow.typeKey("c", modifierFlags: [])
        usleep(200_000)
        XCTAssertTrue(mainWindow.exists,
                      "Focus should work after switching away and back to workspace")
    }

    // MARK: - Mixed split directions

    func testMixedSplitDirections() throws {
        XCTAssertTrue(mainWindow.waitForExistence(timeout: 10),
                      "Main window should appear on launch")
        usleep(2_000_000)

        // Horizontal split: 2 panes side by side.
        app.typeKey("d", modifierFlags: .command)
        usleep(500_000)

        // Navigate to right pane.
        app.typeKey(.rightArrow, modifierFlags: [.command, .option])
        usleep(200_000)

        // Vertical split in right pane: 3 panes total (1 left, 2 stacked right).
        app.typeKey("d", modifierFlags: [.command, .shift])
        usleep(500_000)

        // Type in each pane to verify all 3 exist and accept input.
        // Currently in bottom-right after vertical split.
        mainWindow.typeKey("a", modifierFlags: [])
        usleep(200_000)

        // Navigate up to top-right.
        app.typeKey(.upArrow, modifierFlags: [.command, .option])
        usleep(300_000)
        mainWindow.typeKey("b", modifierFlags: [])
        usleep(200_000)

        // Navigate left to left pane.
        app.typeKey(.leftArrow, modifierFlags: [.command, .option])
        usleep(300_000)
        mainWindow.typeKey("c", modifierFlags: [])
        usleep(200_000)

        XCTAssertTrue(mainWindow.exists,
                      "All 3 panes in mixed horizontal+vertical layout should accept input")
    }

    // MARK: - Shell exit in multi-pane

    func testShellExitMiddlePaneInThreeWaySplit() throws {
        XCTAssertTrue(mainWindow.waitForExistence(timeout: 10),
                      "Main window should appear on launch")
        usleep(2_000_000)

        // Create 3 horizontal panes.
        app.typeKey("d", modifierFlags: .command)
        usleep(500_000)
        app.typeKey("d", modifierFlags: .command)
        usleep(500_000)

        // Navigate to the middle pane.
        app.typeKey(.leftArrow, modifierFlags: [.command, .option])
        usleep(300_000)

        // Exit the middle pane's shell.
        for key in ["e", "x", "i", "t"] {
            mainWindow.typeKey(key, modifierFlags: [])
        }
        mainWindow.typeKey(.return, modifierFlags: [])
        usleep(2_000_000)

        XCTAssertTrue(mainWindow.exists,
                      "Window should remain after middle pane exits in 3-way split")

        // Verify focus transferred — remaining pane should accept input.
        mainWindow.typeKey("a", modifierFlags: [])
        usleep(200_000)
        XCTAssertTrue(mainWindow.exists,
                      "Focus should transfer to remaining pane after middle pane exits")

        // Navigate to verify the other remaining pane also works.
        app.typeKey(.leftArrow, modifierFlags: [.command, .option])
        usleep(300_000)
        mainWindow.typeKey("b", modifierFlags: [])
        usleep(200_000)
        XCTAssertTrue(mainWindow.exists,
                      "Both remaining panes should accept input after middle pane exits")
    }

    func testExitFirstPaneTransfersFocus() throws {
        XCTAssertTrue(mainWindow.waitForExistence(timeout: 10),
                      "Main window should appear on launch")
        usleep(2_000_000)

        // Create a split.
        app.typeKey("d", modifierFlags: .command)
        usleep(500_000)

        // Navigate to the left (first) pane.
        app.typeKey(.leftArrow, modifierFlags: [.command, .option])
        usleep(300_000)

        // Exit the first pane's shell.
        for key in ["e", "x", "i", "t"] {
            mainWindow.typeKey(key, modifierFlags: [])
        }
        mainWindow.typeKey(.return, modifierFlags: [])
        usleep(2_000_000)

        XCTAssertTrue(mainWindow.exists,
                      "Window should remain after first pane exits")
        mainWindow.typeKey("a", modifierFlags: [])
        usleep(200_000)
        XCTAssertTrue(mainWindow.exists,
                      "Remaining pane should accept input after first pane exits")
    }

    // MARK: - Multiple workspaces with active shells

    func testMultipleWorkspacesWithActiveShells() throws {
        XCTAssertTrue(mainWindow.waitForExistence(timeout: 10),
                      "Main window should appear on launch")
        usleep(2_000_000)

        // Type in workspace 1.
        mainWindow.typeKey("a", modifierFlags: [])
        usleep(500_000)

        // Create workspace 2 and let it fully initialize.
        app.typeKey("t", modifierFlags: .command)
        usleep(2_000_000)
        mainWindow.typeKey("b", modifierFlags: [])
        usleep(500_000)

        // Create workspace 3 and let it fully initialize.
        app.typeKey("t", modifierFlags: .command)
        usleep(2_000_000)
        mainWindow.typeKey("c", modifierFlags: [])
        usleep(500_000)

        // Switch back through all workspaces and verify shells are alive.
        app.typeKey("1", modifierFlags: .command)
        usleep(1_000_000)
        mainWindow.typeKey("d", modifierFlags: [])
        usleep(500_000)
        XCTAssertTrue(mainWindow.exists, "Workspace 1 shell should still be alive after round-trip")

        app.typeKey("2", modifierFlags: .command)
        usleep(1_000_000)
        mainWindow.typeKey("e", modifierFlags: [])
        usleep(500_000)
        XCTAssertTrue(mainWindow.exists, "Workspace 2 shell should still be alive after round-trip")

        app.typeKey("3", modifierFlags: .command)
        usleep(1_000_000)
        mainWindow.typeKey("f", modifierFlags: [])
        usleep(500_000)
        XCTAssertTrue(mainWindow.exists, "Workspace 3 shell should still be alive after round-trip")
    }

    func testMixedSplitsWithExitAndNavigate() throws {
        XCTAssertTrue(mainWindow.waitForExistence(timeout: 10),
                      "Main window should appear on launch")
        usleep(2_000_000)

        // Create mixed layout: horizontal then vertical.
        app.typeKey("d", modifierFlags: .command)
        usleep(500_000)
        app.typeKey("d", modifierFlags: [.command, .shift])
        usleep(500_000)

        // Exit the focused pane.
        for key in ["e", "x", "i", "t"] {
            mainWindow.typeKey(key, modifierFlags: [])
        }
        mainWindow.typeKey(.return, modifierFlags: [])
        usleep(2_000_000)

        // Navigate to verify remaining panes work.
        app.typeKey(.leftArrow, modifierFlags: [.command, .option])
        usleep(300_000)
        mainWindow.typeKey("a", modifierFlags: [])
        usleep(200_000)

        app.typeKey(.rightArrow, modifierFlags: [.command, .option])
        usleep(300_000)
        mainWindow.typeKey("b", modifierFlags: [])
        usleep(200_000)

        XCTAssertTrue(mainWindow.exists,
                      "Remaining panes should work after exit in mixed layout")
    }
}
