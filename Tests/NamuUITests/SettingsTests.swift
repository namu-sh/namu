import XCTest

final class SettingsTests: NamuUITestCase {

    func testOpenSettings() throws {
        XCTAssertTrue(mainWindow.waitForExistence(timeout: 10))
        usleep(1_000_000)

        // Cmd+, opens settings.
        app.typeKey(",", modifierFlags: .command)
        usleep(500_000)

        let settings = app.groups["namu-settings"].firstMatch
        XCTAssertTrue(waitForElement(settings, timeout: 5),
                      "Settings view should appear after Cmd+,")
    }

    func testCloseSettings() throws {
        XCTAssertTrue(mainWindow.waitForExistence(timeout: 10))
        usleep(1_000_000)

        // Open settings.
        app.typeKey(",", modifierFlags: .command)
        usleep(500_000)

        let settings = app.groups["namu-settings"].firstMatch
        XCTAssertTrue(waitForElement(settings, timeout: 5),
                      "Settings should appear")

        // Close settings by selecting first workspace with Cmd+1.
        app.typeKey("1", modifierFlags: .command)
        usleep(500_000)

        XCTAssertFalse(settings.exists,
                       "Settings should be dismissed after selecting workspace")
    }
}
