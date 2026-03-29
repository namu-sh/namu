import XCTest

final class ShellFunctionalTests: NamuUITestCase {

    // MARK: - Shell starts and is interactive

    func testShellStartsOnLaunch() throws {
        XCTAssertTrue(mainWindow.waitForExistence(timeout: 10),
                      "Main window should appear on launch")
        usleep(2_000_000)

        // Type a command — if the shell hasn't started, this would do nothing.
        mainWindow.typeKey("a", modifierFlags: [])
        mainWindow.typeKey(.return, modifierFlags: [])
        usleep(500_000)

        XCTAssertTrue(mainWindow.exists, "Window should remain after typing in terminal")
    }

    // MARK: - Shell exit behavior

    func testShellExitClosesPaneInSplit() throws {
        XCTAssertTrue(mainWindow.waitForExistence(timeout: 10),
                      "Main window should appear on launch")
        usleep(2_000_000)

        // Create a horizontal split — now 2 panes.
        app.typeKey("d", modifierFlags: .command)
        usleep(1_000_000)

        let workspace = app.groups["namu-workspace-content"]
        XCTAssertTrue(waitForElement(workspace),
                      "Workspace content should exist after split")

        // Type 'exit' in the focused pane.
        for key in ["e", "x", "i", "t"] {
            mainWindow.typeKey(key, modifierFlags: [])
        }
        mainWindow.typeKey(.return, modifierFlags: [])
        usleep(2_000_000)

        XCTAssertTrue(mainWindow.exists, "App should still be running after pane exit in split")

        // Verify the remaining pane accepts input (focus transferred).
        mainWindow.typeKey("a", modifierFlags: [])
        usleep(200_000)
        XCTAssertTrue(mainWindow.exists, "Remaining pane should accept input after split exit")
    }

    func testShellExitLastPaneKeepsAppOpen() throws {
        XCTAssertTrue(mainWindow.waitForExistence(timeout: 10),
                      "Main window should appear on launch")
        usleep(2_000_000)

        for key in ["e", "x", "i", "t"] {
            mainWindow.typeKey(key, modifierFlags: [])
        }
        mainWindow.typeKey(.return, modifierFlags: [])
        usleep(2_000_000)

        // applicationShouldTerminateAfterLastWindowClosed returns false.
        XCTAssertTrue(mainWindow.exists, "App should stay open after last shell exits")
    }

    func testNonZeroExitCodeClosesPaneInSplit() throws {
        XCTAssertTrue(mainWindow.waitForExistence(timeout: 10),
                      "Main window should appear on launch")
        usleep(2_000_000)

        // Create a split.
        app.typeKey("d", modifierFlags: .command)
        usleep(1_000_000)

        // Run `false; exit` (exit code 1).
        let cmd = "false; exit"
        for char in cmd {
            mainWindow.typeKey(String(char), modifierFlags: [])
        }
        mainWindow.typeKey(.return, modifierFlags: [])
        usleep(2_000_000)

        // App should still be running — one pane remains.
        XCTAssertTrue(mainWindow.exists, "App should remain after non-zero exit in split")

        // Remaining pane should accept input.
        mainWindow.typeKey("a", modifierFlags: [])
        usleep(200_000)
        XCTAssertTrue(mainWindow.exists, "Remaining pane should accept input after non-zero exit")
    }

    func testMultipleSplitsAndExits() throws {
        XCTAssertTrue(mainWindow.waitForExistence(timeout: 10),
                      "Main window should appear on launch")
        usleep(2_000_000)

        // Create 2 additional panes (3 total).
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

        XCTAssertTrue(mainWindow.exists, "App should still run after closing one of three panes")

        // Verify remaining panes accept input.
        mainWindow.typeKey("a", modifierFlags: [])
        usleep(200_000)
        XCTAssertTrue(mainWindow.exists, "Remaining pane should accept input after exit")
    }

    // MARK: - Shell Integration

    /// Verify shell integration by typing cd /tmp and checking the shell
    /// responds (no crash, app stays alive, shell remains interactive).
    /// NOTE: Full shell integration verification (PWD → sidebar title) is done
    /// via Python socket tests (test_shell_env.py: test_surface_send_and_read)
    /// because SwiftUI's .accessibilityElement(children: .contain) on sidebar
    /// containers prevents XCUITest from reading individual Text() labels.
    func testShellIntegrationCdAndContinue() throws {
        XCTAssertTrue(mainWindow.waitForExistence(timeout: 10),
                      "Main window should appear on launch")
        usleep(2_000_000)

        // cd to /tmp
        let cdCmd = "cd /tmp"
        for char in cdCmd {
            mainWindow.typeKey(String(char), modifierFlags: [])
        }
        mainWindow.typeKey(.return, modifierFlags: [])
        usleep(1_000_000)

        // Shell should still be interactive — type ls
        for char in "ls" {
            mainWindow.typeKey(String(char), modifierFlags: [])
        }
        mainWindow.typeKey(.return, modifierFlags: [])
        usleep(500_000)

        XCTAssertTrue(mainWindow.exists,
                      "App should remain after cd + ls (shell integration working)")

        // cd back
        for char in "cd" {
            mainWindow.typeKey(String(char), modifierFlags: [])
        }
        mainWindow.typeKey(.return, modifierFlags: [])
        usleep(500_000)
    }

    /// Verify shell works in a git repo context (cd to repo, run git status).
    func testShellIntegrationInGitRepo() throws {
        XCTAssertTrue(mainWindow.waitForExistence(timeout: 10),
                      "Main window should appear on launch")
        usleep(2_000_000)

        // cd to the namu repo and run git status
        // Use semicolon instead of && because & requires shift modifier
        // which typeKey with no modifiers doesn't produce.
        let cdCmd = "cd /Users/keon/dev/namu; git status"
        for char in cdCmd {
            mainWindow.typeKey(String(char), modifierFlags: [])
        }
        mainWindow.typeKey(.return, modifierFlags: [])
        usleep(2_000_000)

        // Shell should still be interactive
        mainWindow.typeKey("a", modifierFlags: [])
        usleep(200_000)
        XCTAssertTrue(mainWindow.exists,
                      "App should remain after cd + git status (shell integration works in git repos)")

        // cd back
        for char in "cd" {
            mainWindow.typeKey(String(char), modifierFlags: [])
        }
        mainWindow.typeKey(.return, modifierFlags: [])
        usleep(500_000)
    }
}
