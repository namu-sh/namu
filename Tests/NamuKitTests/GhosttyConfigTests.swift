import XCTest
@testable import Namu

final class GhosttyConfigTests: XCTestCase {

    // MARK: - Lifecycle

    func testConfigCreatesSuccessfully() {
        let config = GhosttyConfig()
        XCTAssertNotNil(config.config)
    }

    func testConfigFreeDoesNotCrash() {
        let config = GhosttyConfig()
        config.free()
        XCTAssertNil(config.config)
    }

    func testLoadDefaultFilesDoesNotCrash() {
        let config = GhosttyConfig()
        config.loadDefaultFiles()
        config.finalize()
    }

    // MARK: - Default property values

    func testDefaultFontSizeIsPositive() {
        let config = GhosttyConfig()
        config.finalize()
        XCTAssertGreaterThan(config.fontSize, 0)
    }

    func testDefaultScrollbackLimitIsPositive() {
        let config = GhosttyConfig()
        config.finalize()
        XCTAssertGreaterThan(config.scrollbackLimit, 0)
    }

    func testDefaultBackgroundOpacityInRange() {
        let config = GhosttyConfig()
        config.finalize()
        XCTAssertGreaterThanOrEqual(config.backgroundOpacity, 0.0)
        XCTAssertLessThanOrEqual(config.backgroundOpacity, 1.0)
    }

    // MARK: - Bell feature properties

    func testBellAudioVolumeInRange() {
        let config = GhosttyConfig()
        config.finalize()
        let volume = config.bellAudioVolume
        XCTAssertGreaterThanOrEqual(volume, 0.0)
        XCTAssertLessThanOrEqual(volume, 1.0)
    }

    func testBellFeaturesIsUInt32() {
        let config = GhosttyConfig()
        config.finalize()
        // Just verify it doesn't crash and returns a value
        let features = config.bellFeatures
        XCTAssertTrue(features >= 0)
    }

    // MARK: - Diagnostics

    func testDiagnosticsCountIsNonNegative() {
        let config = GhosttyConfig()
        config.finalize()
        XCTAssertGreaterThanOrEqual(config.diagnosticsCount, 0)
    }

    func testHasErrorsReflectsDiagnosticsCount() {
        let config = GhosttyConfig()
        config.finalize()
        XCTAssertEqual(config.hasErrors, config.diagnosticsCount > 0)
    }

    func testLogDiagnosticsDoesNotCrash() {
        let config = GhosttyConfig()
        config.finalize()
        config.logDiagnostics(label: "Test")
    }

    // MARK: - Generic get

    func testGetUnknownKeyReturnsFalse() {
        let config = GhosttyConfig()
        config.finalize()
        var value: UInt32 = 0
        let result = config.get("nonexistent-key-xyz", into: &value)
        XCTAssertFalse(result)
    }

    // MARK: - withSurfaceConfig

    func testWithSurfaceConfigDoesNotCrash() {
        let config = GhosttyConfig()
        config.finalize()
        // We can't actually create a surface in tests (no NSView/display),
        // but we can verify the closure is called with a valid config struct.
        var wasCalled = false
        config.withSurfaceConfig(
            nsView: NSView(frame: .zero),
            userdata: nil,
            scaleFactor: 1.0
        ) { cfg in
            wasCalled = true
            XCTAssertEqual(cfg.platform_tag, GHOSTTY_PLATFORM_MACOS)
            return ()
        }
        XCTAssertTrue(wasCalled)
    }
}
