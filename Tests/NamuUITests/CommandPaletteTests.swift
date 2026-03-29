import XCTest

final class CommandPaletteTests: NamuUITestCase {

    func testOpenCommandPalette() throws {
        XCTAssertTrue(mainWindow.waitForExistence(timeout: 10))
        usleep(1_000_000)

        // Cmd+K opens the command palette.
        app.typeKey("k", modifierFlags: .command)

        let palette = app.groups["namu-command-palette"].firstMatch
        XCTAssertTrue(waitForElement(palette, timeout: 5),
                      "Command palette should appear after Cmd+K")
    }

    func testCommandPaletteSearch() throws {
        XCTAssertTrue(mainWindow.waitForExistence(timeout: 10))
        usleep(1_000_000)

        // Open palette.
        app.typeKey("k", modifierFlags: .command)

        let palette = app.groups["namu-command-palette"].firstMatch
        XCTAssertTrue(waitForElement(palette, timeout: 5),
                      "Command palette should appear")

        // The search field gets focus automatically. Type using app-level key events
        // which go to the focused element (the search field) without requiring
        // XCUITest keyboard focus on the element.
        usleep(500_000)
        app.typeKey("s", modifierFlags: [])
        app.typeKey("p", modifierFlags: [])
        app.typeKey("l", modifierFlags: [])
        app.typeKey("i", modifierFlags: [])
        app.typeKey("t", modifierFlags: [])
        usleep(300_000)

        // The palette should still be visible with filtered results.
        XCTAssertTrue(palette.exists, "Command palette should remain visible while searching")
    }

    func testCloseCommandPalette() throws {
        XCTAssertTrue(mainWindow.waitForExistence(timeout: 10))
        usleep(1_000_000)

        // Open palette.
        app.typeKey("k", modifierFlags: .command)

        let palette = app.groups["namu-command-palette"].firstMatch
        XCTAssertTrue(waitForElement(palette, timeout: 5),
                      "Command palette should appear")

        // Press Escape to close.
        app.typeKey(.escape, modifierFlags: [])
        usleep(500_000)

        // Palette should be dismissed.
        XCTAssertFalse(palette.exists,
                       "Command palette should be dismissed after Escape")
    }

    func testCommandPaletteViaP() throws {
        XCTAssertTrue(mainWindow.waitForExistence(timeout: 10))
        usleep(1_000_000)

        // Cmd+P also opens the command palette.
        app.typeKey("p", modifierFlags: .command)

        let palette = app.groups["namu-command-palette"].firstMatch
        XCTAssertTrue(waitForElement(palette, timeout: 5),
                      "Command palette should appear after Cmd+P")
    }
}
