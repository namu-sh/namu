import XCTest

final class TerminalTests: NamuUITestCase {

    func testTerminalAcceptsInput() throws {
        XCTAssertTrue(mainWindow.waitForExistence(timeout: 10))

        // Wait for terminal session to start.
        usleep(2_000_000)

        // Type text into the terminal. The terminal is the first responder
        // after launch, so we can type directly.
        mainWindow.typeKey("e", modifierFlags: [])
        mainWindow.typeKey("c", modifierFlags: [])
        mainWindow.typeKey("h", modifierFlags: [])
        mainWindow.typeKey("o", modifierFlags: [])
        usleep(200_000)

        // No crash means the terminal accepted input.
        XCTAssertTrue(mainWindow.exists,
                      "Window should remain after typing in terminal")
    }

    func testTerminalFindOverlay() throws {
        XCTAssertTrue(mainWindow.waitForExistence(timeout: 10))
        usleep(2_000_000)

        // Cmd+F opens the find overlay.
        app.typeKey("f", modifierFlags: .command)

        let findOverlay = app.groups["namu-find-overlay"].firstMatch
        XCTAssertTrue(waitForElement(findOverlay, timeout: 5),
                      "Find overlay should appear after Cmd+F")
    }

    func testTerminalFindClose() throws {
        XCTAssertTrue(mainWindow.waitForExistence(timeout: 10))
        usleep(2_000_000)

        // Open find overlay.
        app.typeKey("f", modifierFlags: .command)

        let findOverlay = app.groups["namu-find-overlay"].firstMatch
        XCTAssertTrue(waitForElement(findOverlay, timeout: 5),
                      "Find overlay should appear")

        // Press Escape to close.
        app.typeKey(.escape, modifierFlags: [])
        usleep(500_000)

        XCTAssertFalse(findOverlay.exists,
                       "Find overlay should be dismissed after Escape")
    }
}
