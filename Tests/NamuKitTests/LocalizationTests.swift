import XCTest
@testable import Namu

// MARK: - LocalizationTests
//
// Tests for the i18n layer used across NamuKit.
//
// Strategy:
//   1. Verify String(localized:defaultValue:) returns the defaultValue when no
//      translation bundle is present (test target has no .strings file).
//   2. Verify the naming convention: all localized keys in production code must
//      follow the "feature.context.element" dot-separated pattern.

final class LocalizationTests: XCTestCase {

    // MARK: - Default value fallback

    func test_stringLocalized_withUnknownKey_returnsDefaultValue() {
        // In the test bundle there are no .strings files, so every lookup
        // must fall back to the provided defaultValue.
        // String(localized:defaultValue:) requires a string literal for the key parameter
        // (String.LocalizationValue). We use literals here to satisfy the type system.
        let result = String(localized: "nonexistent.key.xyz", defaultValue: "Fallback Text")
        XCTAssertEqual(result, "Fallback Text",
                       "String(localized:defaultValue:) must return defaultValue when no translation exists")
    }

    func test_stringLocalized_withEmptyDefaultValue_returnsKeyAsString() {
        // Swift's String(localized:defaultValue:) treats an empty defaultValue as "no default"
        // and returns the key string itself when no translation exists.
        // This is documented Swift Foundation behavior: the key is used as the last-resort value.
        let result = String(localized: "nonexistent.key.abc", defaultValue: "")
        XCTAssertEqual(result, "nonexistent.key.abc",
                       "When defaultValue is empty and no translation exists, the key itself is returned")
    }

    func test_stringLocalized_defaultValueIsPreservedVerbatim() {
        // The production code uses this exact key + defaultValue pair.
        let result = String(localized: "workspace.default.title", defaultValue: "New Workspace")
        // In the test environment there is no .strings file, so the defaultValue is returned.
        XCTAssertEqual(result, "New Workspace",
                       "defaultValue must be returned verbatim when no translation table is loaded")
    }

    func test_stringLocalized_multiWordDefaultValue_isReturnedAsIs() {
        let result = String(localized: "notifications.empty.label", defaultValue: "No notifications")
        XCTAssertEqual(result, "No notifications")
    }

    func test_stringLocalized_defaultValueWithSpecialCharacters_isReturnedAsIs() {
        let result = String(localized: "alert.cpu.threshold", defaultValue: "CPU > 90%")
        XCTAssertEqual(result, "CPU > 90%",
                       "Special characters in defaultValue must be preserved")
    }

    // MARK: - Key naming convention

    // All keys in the codebase must follow "feature.context.element" (2+ dot-separated components).
    // We verify the known production keys found via grep.

    private let knownProductionKeys: [String] = [
        "workspace.default.title",
    ]

    func test_allProductionKeys_followDotSeparatedNamingConvention() {
        for key in knownProductionKeys {
            let components = key.split(separator: ".")
            XCTAssertGreaterThanOrEqual(
                components.count, 2,
                "Key '\(key)' must have at least 2 dot-separated components (feature.context[.element])"
            )
        }
    }

    func test_allProductionKeys_haveNoUppercaseLetters() {
        for key in knownProductionKeys {
            XCTAssertEqual(key, key.lowercased(),
                           "Key '\(key)' must use lowercase only")
        }
    }

    func test_allProductionKeys_haveNoWhitespace() {
        for key in knownProductionKeys {
            XCTAssertFalse(key.contains(" "),
                           "Key '\(key)' must not contain spaces")
        }
    }

    func test_allProductionKeys_doNotStartOrEndWithDot() {
        for key in knownProductionKeys {
            XCTAssertFalse(key.hasPrefix("."),
                           "Key '\(key)' must not start with a dot")
            XCTAssertFalse(key.hasSuffix("."),
                           "Key '\(key)' must not end with a dot")
        }
    }

    func test_allProductionKeys_haveNoConsecutiveDots() {
        for key in knownProductionKeys {
            XCTAssertFalse(key.contains(".."),
                           "Key '\(key)' must not contain consecutive dots")
        }
    }

    // MARK: - Key format validation helper (reusable logic)

    func test_keyFormat_validKey_passes() {
        XCTAssertTrue(isValidLocalizationKey("workspace.default.title"))
        XCTAssertTrue(isValidLocalizationKey("notification.panel.empty"))
        XCTAssertTrue(isValidLocalizationKey("alert.cpu.threshold"))
    }

    func test_keyFormat_singleComponentKey_fails() {
        XCTAssertFalse(isValidLocalizationKey("workspace"),
                       "Single-component key should fail naming convention check")
    }

    func test_keyFormat_keyWithUppercase_fails() {
        XCTAssertFalse(isValidLocalizationKey("Workspace.default.title"),
                       "Key with uppercase letters should fail")
    }

    func test_keyFormat_keyWithLeadingDot_fails() {
        XCTAssertFalse(isValidLocalizationKey(".workspace.title"),
                       "Key with leading dot should fail")
    }

    func test_keyFormat_keyWithTrailingDot_fails() {
        XCTAssertFalse(isValidLocalizationKey("workspace.title."),
                       "Key with trailing dot should fail")
    }

    func test_keyFormat_keyWithConsecutiveDots_fails() {
        XCTAssertFalse(isValidLocalizationKey("workspace..title"),
                       "Key with consecutive dots should fail")
    }

    func test_keyFormat_keyWithSpace_fails() {
        XCTAssertFalse(isValidLocalizationKey("workspace.default title"),
                       "Key with space should fail")
    }

    // MARK: - Private helper

    /// Returns true when `key` conforms to the "feature.context[.element]" convention:
    /// lowercase, dot-separated, at least 2 components, no leading/trailing/consecutive dots,
    /// no whitespace.
    private func isValidLocalizationKey(_ key: String) -> Bool {
        guard !key.isEmpty else { return false }
        guard key == key.lowercased() else { return false }
        guard !key.hasPrefix(".") && !key.hasSuffix(".") else { return false }
        guard !key.contains("..") else { return false }
        guard !key.contains(" ") else { return false }
        let components = key.split(separator: ".", omittingEmptySubsequences: false)
        return components.count >= 2 && components.allSatisfy { !$0.isEmpty }
    }
}
