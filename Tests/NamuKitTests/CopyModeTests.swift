import XCTest
@testable import Namu

final class CopyModeTests: XCTestCase {

    // MARK: - Escape always exits

    func testEscapeExits() {
        var state = CopyModeInputState()
        let result = copyModeResolve(keyCode: 53, chars: nil, modifiers: [], hasSelection: false, state: &state)
        if case .perform(let action, let count) = result {
            XCTAssertEqual(action, .exit)
            XCTAssertEqual(count, 1)
        } else {
            XCTFail("Expected .perform(.exit, count: 1), got \(result)")
        }
    }

    func testQuitExits() {
        var state = CopyModeInputState()
        let result = copyModeResolve(keyCode: 12, chars: "q", modifiers: [], hasSelection: false, state: &state)
        if case .perform(let action, _) = result {
            XCTAssertEqual(action, .exit)
        } else {
            XCTFail("Expected exit action")
        }
    }

    // MARK: - Navigation without selection

    func testJScrollsDown() {
        var state = CopyModeInputState()
        let result = copyModeResolve(keyCode: 38, chars: "j", modifiers: [], hasSelection: false, state: &state)
        if case .perform(let action, let count) = result {
            XCTAssertEqual(action, .scrollLines(1))
            XCTAssertEqual(count, 1)
        } else {
            XCTFail("Expected scrollLines(1)")
        }
    }

    func testKScrollsUp() {
        var state = CopyModeInputState()
        let result = copyModeResolve(keyCode: 40, chars: "k", modifiers: [], hasSelection: false, state: &state)
        if case .perform(let action, _) = result {
            XCTAssertEqual(action, .scrollLines(-1))
        } else {
            XCTFail("Expected scrollLines(-1)")
        }
    }

    func testGGScrollsToTop() {
        var state = CopyModeInputState()
        // First `g` sets pendingG
        let first = copyModeResolve(keyCode: 5, chars: "g", modifiers: [], hasSelection: false, state: &state)
        XCTAssertEqual(first, .consume)
        XCTAssertTrue(state.pendingG)

        // Second `g` performs scrollToTop
        let second = copyModeResolve(keyCode: 5, chars: "g", modifiers: [], hasSelection: false, state: &state)
        if case .perform(let action, _) = second {
            XCTAssertEqual(action, .scrollToTop)
        } else {
            XCTFail("Expected scrollToTop after gg")
        }
        XCTAssertFalse(state.pendingG)
    }

    func testShiftGScrollsToBottom() {
        var state = CopyModeInputState()
        let result = copyModeResolve(keyCode: 5, chars: "g", modifiers: .shift, hasSelection: false, state: &state)
        if case .perform(let action, _) = result {
            XCTAssertEqual(action, .scrollToBottom)
        } else {
            XCTFail("Expected scrollToBottom for G")
        }
    }

    // MARK: - Selection mode

    func testVStartsSelection() {
        var state = CopyModeInputState()
        let result = copyModeResolve(keyCode: 9, chars: "v", modifiers: [], hasSelection: false, state: &state)
        if case .perform(let action, _) = result {
            XCTAssertEqual(action, .startSelection)
        } else {
            XCTFail("Expected startSelection")
        }
    }

    func testVWithSelectionClearsSelection() {
        var state = CopyModeInputState()
        let result = copyModeResolve(keyCode: 9, chars: "v", modifiers: [], hasSelection: true, state: &state)
        if case .perform(let action, _) = result {
            XCTAssertEqual(action, .clearSelection)
        } else {
            XCTFail("Expected clearSelection")
        }
    }

    func testHJKLAdjustSelectionWhenActive() {
        var state = CopyModeInputState()
        let cases: [(String, CopyModeSelectionMove)] = [
            ("h", .left), ("l", .right), ("j", .down), ("k", .up)
        ]
        for (ch, move) in cases {
            let result = copyModeResolve(keyCode: 0, chars: ch, modifiers: [], hasSelection: true, state: &state)
            if case .perform(let action, _) = result {
                XCTAssertEqual(action, .adjustSelection(move), "Expected adjustSelection(\(move)) for '\(ch)'")
            } else {
                XCTFail("Expected adjustSelection for '\(ch)'")
            }
        }
    }

    func testYCopiesWithSelection() {
        var state = CopyModeInputState()
        let result = copyModeResolve(keyCode: 16, chars: "y", modifiers: [], hasSelection: true, state: &state)
        if case .perform(let action, _) = result {
            XCTAssertEqual(action, .copyAndExit)
        } else {
            XCTFail("Expected copyAndExit")
        }
    }

    // MARK: - Double-y (yy) detection

    func testDoubleYCopiesLine() {
        var state = CopyModeInputState()
        // First y — no selection, sets pendingYankLine
        let first = copyModeResolve(keyCode: 16, chars: "y", modifiers: [], hasSelection: false, state: &state)
        XCTAssertEqual(first, .consume)
        XCTAssertTrue(state.pendingYankLine)

        // Second y — commits yy
        let second = copyModeResolve(keyCode: 16, chars: "y", modifiers: [], hasSelection: false, state: &state)
        if case .perform(let action, _) = second {
            XCTAssertEqual(action, .copyLineAndExit)
        } else {
            XCTFail("Expected copyLineAndExit after yy")
        }
        XCTAssertFalse(state.pendingYankLine)
    }

    func testYFollowedByOtherCancelsYank() {
        var state = CopyModeInputState()
        _ = copyModeResolve(keyCode: 16, chars: "y", modifiers: [], hasSelection: false, state: &state)
        XCTAssertTrue(state.pendingYankLine)
        // Follow with 'k' — should cancel yank and treat as fresh command
        _ = copyModeResolve(keyCode: 40, chars: "k", modifiers: [], hasSelection: false, state: &state)
        XCTAssertFalse(state.pendingYankLine)
    }

    // MARK: - Count prefix (e.g., 5j = scroll 5 lines)

    func testCountPrefix() {
        var state = CopyModeInputState()
        // Press '5'
        let r1 = copyModeResolve(keyCode: 23, chars: "5", modifiers: [], hasSelection: false, state: &state)
        XCTAssertEqual(r1, .consume)
        XCTAssertEqual(state.countPrefix, 5)

        // Press 'j' — should perform with count 5
        let r2 = copyModeResolve(keyCode: 38, chars: "j", modifiers: [], hasSelection: false, state: &state)
        if case .perform(_, let count) = r2 {
            XCTAssertEqual(count, 5)
        } else {
            XCTFail("Expected perform with count 5")
        }
        XCTAssertNil(state.countPrefix)
    }

    func testMultiDigitCountPrefix() {
        var state = CopyModeInputState()
        _ = copyModeResolve(keyCode: 0, chars: "1", modifiers: [], hasSelection: false, state: &state)
        _ = copyModeResolve(keyCode: 0, chars: "0", modifiers: [], hasSelection: false, state: &state)
        XCTAssertEqual(state.countPrefix, 10)
    }

    func testCountPrefixClampedToMax() {
        var state = CopyModeInputState()
        // Enter a very large number
        for ch in "99999".map(String.init) {
            _ = copyModeResolve(keyCode: 0, chars: ch, modifiers: [], hasSelection: false, state: &state)
        }
        XCTAssertLessThanOrEqual(state.countPrefix ?? 0, 9999)
    }

    func testCountResetsAfterAction() {
        var state = CopyModeInputState()
        _ = copyModeResolve(keyCode: 0, chars: "3", modifiers: [], hasSelection: false, state: &state)
        _ = copyModeResolve(keyCode: 53, chars: nil, modifiers: [], hasSelection: false, state: &state) // Escape
        XCTAssertNil(state.countPrefix)
    }

    // MARK: - Search keys

    func testSlashStartsSearch() {
        var state = CopyModeInputState()
        let result = copyModeResolve(keyCode: 44, chars: "/", modifiers: [], hasSelection: false, state: &state)
        if case .perform(let action, _) = result {
            XCTAssertEqual(action, .startSearch)
        } else {
            XCTFail("Expected startSearch")
        }
    }

    func testNSearchesNext() {
        var state = CopyModeInputState()
        let result = copyModeResolve(keyCode: 45, chars: "n", modifiers: [], hasSelection: false, state: &state)
        if case .perform(let action, _) = result {
            XCTAssertEqual(action, .searchNext)
        } else {
            XCTFail("Expected searchNext")
        }
    }

    func testShiftNSearchesPrevious() {
        var state = CopyModeInputState()
        let result = copyModeResolve(keyCode: 45, chars: "n", modifiers: .shift, hasSelection: false, state: &state)
        if case .perform(let action, _) = result {
            XCTAssertEqual(action, .searchPrevious)
        } else {
            XCTFail("Expected searchPrevious")
        }
    }

    // MARK: - bindingAction mapping

    func testBindingActionScrollToTop() {
        let action = copyModeBindingAction(for: .scrollToTop, count: 1)
        XCTAssertEqual(action, "scroll_to_top")
    }

    func testBindingActionScrollLines() {
        let action = copyModeBindingAction(for: .scrollLines(1), count: 3)
        XCTAssertEqual(action, "scroll_page_lines:3")
    }

    func testBindingActionScrollLinesUp() {
        let action = copyModeBindingAction(for: .scrollLines(-1), count: 2)
        XCTAssertEqual(action, "scroll_page_lines:-2")
    }

    func testBindingActionScrollPageUp() {
        let action = copyModeBindingAction(for: .scrollPage(-1), count: 1)
        XCTAssertEqual(action, "scroll_page_up")
    }

    func testBindingActionAdjustSelectionUp() {
        let action = copyModeBindingAction(for: .adjustSelection(.up), count: 1)
        XCTAssertEqual(action, "adjust_selection:up")
    }

    func testBindingActionCopyToClipboard() {
        let action = copyModeBindingAction(for: .copyAndExit, count: 1)
        XCTAssertEqual(action, "copy_to_clipboard")
    }

    func testBypassForCommandKey() {
        XCTAssertTrue(copyModeShouldBypassForShortcut(modifierFlags: .command))
        XCTAssertFalse(copyModeShouldBypassForShortcut(modifierFlags: []))
        XCTAssertFalse(copyModeShouldBypassForShortcut(modifierFlags: .control))
    }
}
