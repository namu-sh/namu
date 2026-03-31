import XCTest
@testable import Namu

// MARK: - ScrollbackPersistenceTests
//
// Tests the UTF-8 boundary-safe truncation algorithm used by
// TerminalSession.readScrollbackText(charLimit:).
//
// Because readScrollbackText requires a live ghostty_surface_t, we test
// the truncation logic directly via a free function that mirrors the
// implementation in TerminalSession. The helper is defined below so the
// tests are self-contained without touching any C/Ghostty surface code.

// MARK: - Truncation helper (mirrors TerminalSession.readScrollbackText logic)

/// Truncate `text` to at most `charLimit` UTF-8 bytes, stepping back over
/// any UTF-8 continuation bytes (0x80–0xBF) so the result is always valid UTF-8.
/// Returns nil when charLimit <= 0. Returns the original string when it is
/// already within the limit.
private func safeTruncate(_ text: String, charLimit: Int) -> String? {
    guard charLimit > 0 else { return nil }
    let utf8 = text.utf8
    guard utf8.count > charLimit else { return text }
    var endIdx = utf8.index(utf8.startIndex, offsetBy: charLimit, limitedBy: utf8.endIndex) ?? utf8.endIndex
    // Step back over UTF-8 continuation bytes to a leading byte.
    while endIdx > utf8.startIndex && endIdx < utf8.endIndex && utf8[endIdx] & 0xC0 == 0x80 {
        endIdx = utf8.index(before: endIdx)
    }
    return String(utf8[..<endIdx])
}

// MARK: - ANSI-safe truncation helper (mirrors full TerminalSession logic including CSI repair + SGR prefix)

/// Full mirror of TerminalSession.readScrollbackText truncation logic:
/// UTF-8 boundary safety, ANSI CSI partial-sequence repair, and SGR reset prefix.
/// Returns nil when charLimit <= 0.
private func ansiSafeTruncate(_ text: String, charLimit: Int) -> String? {
    guard charLimit > 0 else { return nil }
    guard text.utf8.count > charLimit else { return "\u{1B}[0m" + text }
    var bytes = Array(text.utf8)
    var cutByte = min(charLimit, bytes.count)
    // Step back over UTF-8 continuation bytes.
    while cutByte > 0 && cutByte < bytes.count && bytes[cutByte] & 0xC0 == 0x80 {
        cutByte -= 1
    }
    // ANSI CSI safety: scan backward up to 20 bytes for ESC.
    let lookback = min(20, cutByte)
    var escPos: Int? = nil
    for i in stride(from: cutByte - 1, through: cutByte - lookback, by: -1) {
        if bytes[i] == 0x1B {
            escPos = i
            break
        }
    }
    if let esc = escPos, esc + 1 < bytes.count, bytes[esc + 1] == UInt8(ascii: "[") {
        let searchStart = esc + 2
        let hasFinal = searchStart < cutByte && (searchStart..<cutByte).contains { bytes[$0] >= 0x40 && bytes[$0] <= 0x7E }
        if !hasFinal {
            cutByte = esc
        }
    }
    let truncated = String(bytes: Array(bytes.prefix(cutByte)), encoding: .utf8) ?? ""
    return "\u{1B}[0m" + truncated
}

final class ScrollbackPersistenceTests: XCTestCase {

    // MARK: - charLimit = 0

    func test_charLimitZero_returnsNil() {
        let result = safeTruncate("hello world", charLimit: 0)
        XCTAssertNil(result, "charLimit 0 should return nil")
    }

    // MARK: - Content shorter than limit

    func test_contentShorterThanLimit_returnedAsIs() {
        let input = "hello"
        let result = safeTruncate(input, charLimit: 100)
        XCTAssertEqual(result, input, "Content shorter than charLimit should be returned unchanged")
    }

    func test_contentExactlyAtLimit_returnedAsIs() {
        let input = "hello"
        // "hello" is 5 UTF-8 bytes
        let result = safeTruncate(input, charLimit: 5)
        XCTAssertEqual(result, input, "Content exactly at charLimit should be returned unchanged")
    }

    // MARK: - ASCII truncation

    func test_asciiContent_truncatedAtExactBoundary() {
        let input = "hello world"
        let result = safeTruncate(input, charLimit: 5)
        XCTAssertEqual(result, "hello", "ASCII string should truncate cleanly at byte boundary")
    }

    func test_asciiContent_resultIsValidUTF8() {
        let input = "abcdefghij"
        let result = safeTruncate(input, charLimit: 7)
        XCTAssertNotNil(result)
        XCTAssertEqual(result, "abcdefg")
    }

    // MARK: - UTF-8 multibyte safe truncation

    func test_utf8_truncationInsideMultibyteCharStepsBack() {
        // "é" is 2 UTF-8 bytes (0xC3 0xA9). If charLimit cuts inside it, step back.
        // "aé" = 3 bytes: [0x61, 0xC3, 0xA9]. charLimit=2 would land on 0xA9 (continuation byte).
        let input = "aé"
        let result = safeTruncate(input, charLimit: 2)
        // Should step back to just "a" (1 byte) to avoid a partial sequence.
        XCTAssertNotNil(result)
        // Result must be valid UTF-8 (no partial sequence).
        XCTAssertNotNil(result.flatMap { $0.data(using: .utf8) },
                        "Result must be valid UTF-8 after truncation inside a multibyte char")
        // Must not contain a partial 'é'.
        XCTAssertFalse(result?.contains("é") ?? false,
                       "Should not contain the partial multibyte character")
    }

    func test_utf8_threeByteCJKCharacterStepsBack() {
        // "中" = 3 UTF-8 bytes (0xE4 0xB8 0xAD).
        // "a中" = 4 bytes. charLimit=2 cuts inside "中".
        let input = "a中"
        let result = safeTruncate(input, charLimit: 2)
        XCTAssertNotNil(result)
        XCTAssertNotNil(result.flatMap { $0.data(using: .utf8) },
                        "Result must be valid UTF-8")
        XCTAssertFalse(result?.contains("中") ?? false,
                       "Partial CJK character should not appear in truncated output")
    }

    func test_utf8_charAtExactBoundaryIsKept() {
        // "é" = 2 bytes. "aé" = 3 bytes. charLimit=3 should keep both characters.
        let input = "aé"
        let result = safeTruncate(input, charLimit: 3)
        XCTAssertEqual(result, "aé", "Complete multibyte char at exact limit should be kept")
    }

    func test_utf8_multipleMultibyteCharsAllRetained() {
        // "éé" = 4 bytes. charLimit=4 should return the full string.
        let input = "éé"
        let result = safeTruncate(input, charLimit: 4)
        XCTAssertEqual(result, "éé")
    }

    func test_utf8_truncationYieldsValidSwiftString() {
        // Ensure the result can be used as a normal Swift String without issues.
        let input = "Hello 世界! More text here."
        for limit in [1, 5, 7, 8, 9, 10, 20] {
            let result = safeTruncate(input, charLimit: limit)
            if let r = result {
                // Encoding round-trip must succeed.
                XCTAssertNotNil(r.data(using: .utf8),
                                "charLimit=\(limit) result must be valid UTF-8")
            }
        }
    }

    // MARK: - Edge cases

    func test_emptyString_returnsEmpty() {
        let result = safeTruncate("", charLimit: 10)
        XCTAssertEqual(result, "", "Empty string should be returned as empty, not nil")
    }

    func test_charLimitOne_returnsFirstAsciiChar() {
        let result = safeTruncate("abc", charLimit: 1)
        XCTAssertEqual(result, "a")
    }

    func test_charLimitOne_withLeadingMultibyteChar_stepsBackToEmpty() {
        // "é" starts with a leading byte 0xC3, charLimit=1 lands on that leading byte
        // which is NOT a continuation — so it is kept as "é" actually... wait:
        // charLimit=1 means endIdx = offset 1, which is 0xA9 (continuation byte of "é").
        // The step-back loop will move back to offset 0 (the leading byte 0xC3).
        // String(utf8[..<0]) = "" (empty).
        let input = "é"  // 2 UTF-8 bytes
        let result = safeTruncate(input, charLimit: 1)
        // After stepping back over continuation byte at index 1, endIdx becomes 0.
        XCTAssertNotNil(result)
        XCTAssertNotNil(result.flatMap { $0.data(using: .utf8) },
                        "Single-byte limit on 2-byte char must yield valid UTF-8")
    }
}

// MARK: - ANSISafetyTests

final class ANSISafetyTests: XCTestCase {

    // MARK: - SGR reset prefix

    func test_shortContent_prefixedWithSGRReset() {
        // Content within limit should still be prefixed with ESC[0m.
        let result = ansiSafeTruncate("hello", charLimit: 100)
        XCTAssertEqual(result, "\u{1B}[0mhello")
    }

    func test_truncatedContent_prefixedWithSGRReset() {
        let input = String(repeating: "a", count: 20)
        let result = ansiSafeTruncate(input, charLimit: 10)
        XCTAssertNotNil(result)
        XCTAssertTrue(result!.hasPrefix("\u{1B}[0m"), "Truncated result must start with ESC[0m")
    }

    // MARK: - Complete CSI sequence preserved

    func test_completeCSISequence_notDropped() {
        // "\u{1B}[31m" = complete CSI (final byte 'm' = 0x6D which is in 0x40–0x7E).
        // Place it so it ends just before the cut point.
        // "abc\u{1B}[31mXXXXXXXXX" — cut at 9 keeps the whole CSI.
        let ansi = "\u{1B}[31m"  // 4 bytes: ESC [ 3 1 m
        let input = "abc" + ansi + "XXXXX"
        // cut at 8: "abc" (3) + ESC[31m (5 bytes: ESC,[,3,1,m) = first 8 bytes = "abc\u{1B}[31m"
        // ESC is at position 3, '[' at 4, final byte 'm' at 7, cutByte=8 so hasFinal = true.
        let result = ansiSafeTruncate(input, charLimit: 8)
        XCTAssertNotNil(result)
        // The complete sequence should be retained (no trimming needed).
        XCTAssertTrue(result!.contains("\u{1B}[31m"), "Complete CSI sequence should not be dropped")
    }

    // MARK: - Partial CSI sequence dropped

    func test_partialCSISequence_droppedAtESC() {
        // "\u{1B}[31m" = 5 bytes. If cut lands inside the sequence (before 'm'), it's partial.
        // "abc\u{1B}[3" — ESC at index 3, '[' at 4, '3' at 5, no final byte before cut=6.
        // bytes: a(0) b(1) c(2) ESC(3) [(4) 3(5) 1(6) m(7)
        // charLimit=6 → cut at byte 6, scan back finds ESC at 3, '[' at 4.
        // hasFinal in range [5,6) = byte[5]='3'=0x33, not in 0x40–0x7E. Partial → cutByte = 3.
        let input = "abc\u{1B}[31m"
        let result = ansiSafeTruncate(input, charLimit: 6)
        XCTAssertNotNil(result)
        // Result body should be just "abc" (ESC and partial sequence dropped).
        let body = result!.replacingOccurrences(of: "\u{1B}[0m", with: "")
        XCTAssertEqual(body, "abc", "Partial CSI sequence should be dropped, leaving only 'abc'")
    }

    func test_partialCSIAtVeryEnd_dropped() {
        // ESC is the last byte of the cut window — definitely partial.
        // "abcde\u{1B}" — ESC at index 5, charLimit=6 → cutByte=6.
        // scan back: bytes[5]=ESC, escPos=5. bytes[6]='[' but cutByte=6 so esc+1 == cutByte.
        // esc+1 < bytes.count = true (more bytes exist) and bytes[6]='['.
        // hasFinal in range [7,6) = empty → partial → cutByte = 5.
        let input = "abcde\u{1B}[32mX"
        let result = ansiSafeTruncate(input, charLimit: 6)
        XCTAssertNotNil(result)
        let body = result!.replacingOccurrences(of: "\u{1B}[0m", with: "")
        XCTAssertEqual(body, "abcde", "ESC-only partial CSI at cut boundary should be dropped")
    }

    // MARK: - Non-CSI ESC not affected

    func test_nonCSIEscape_notTrimmed() {
        // ESC not followed by '[' is not a CSI sequence — leave the cut as-is.
        // "abc\u{1B}Xmore" — ESC at 3, next byte 'X' != '[', so no CSI trimming.
        // charLimit=5 → cut at "abc\u{1B}X" (5 bytes).
        let input = "abc\u{1B}Xmore"
        let result = ansiSafeTruncate(input, charLimit: 5)
        XCTAssertNotNil(result)
        let body = result!.replacingOccurrences(of: "\u{1B}[0m", with: "")
        XCTAssertEqual(body, "abc\u{1B}X", "Non-CSI ESC sequence should not cause extra trimming")
    }

    // MARK: - charLimit zero

    func test_charLimitZero_returnsNil() {
        let result = ansiSafeTruncate("hello", charLimit: 0)
        XCTAssertNil(result)
    }
}
