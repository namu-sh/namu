import AppKit

// MARK: - CopyModeSelectionMove

enum CopyModeSelectionMove: String, Equatable {
    case left
    case right
    case up
    case down
    case pageUp = "page_up"
    case pageDown = "page_down"
    case home
    case end
    case beginningOfLine = "beginning_of_line"
    case endOfLine = "end_of_line"
    case wordForward = "word_forward"
    case wordBackward = "word_backward"
}

// MARK: - CopyModeAction

enum CopyModeAction: Equatable {
    case exit
    case startSelection
    case clearSelection
    case copyAndExit
    case copyLineAndExit
    case scrollLines(Int)
    case scrollPage(Int)
    case scrollHalfPage(Int)
    case scrollToTop
    case scrollToBottom
    case jumpToPrompt(Int)
    case startSearch
    case searchNext
    case searchPrevious
    case adjustSelection(CopyModeSelectionMove)
}

// MARK: - CopyModeInputState

struct CopyModeInputState: Equatable {
    var countPrefix: Int?
    var pendingYankLine = false
    var pendingG = false

    mutating func reset() {
        countPrefix = nil
        pendingYankLine = false
        pendingG = false
    }
}

// MARK: - CopyModeResolution

enum CopyModeResolution: Equatable {
    case perform(CopyModeAction, count: Int)
    case consume
}

// MARK: - Constants

private let copyModeMaxCount = 9_999

// MARK: - Helpers

private func copyModeClampCount(_ value: Int) -> Int {
    min(max(value, 1), copyModeMaxCount)
}

private func copyModeNormalizedModifiers(
    _ modifierFlags: NSEvent.ModifierFlags
) -> NSEvent.ModifierFlags {
    modifierFlags
        .intersection(.deviceIndependentFlagsMask)
        .subtracting([.numericPad, .function, .capsLock])
}

private func copyModeChars(_ charactersIgnoringModifiers: String?) -> String {
    guard let scalar = charactersIgnoringModifiers?.unicodeScalars.first else {
        return ""
    }
    return String(scalar).lowercased()
}

/// Returns true if the event should bypass copy mode and go to AppKit/system
/// (e.g. Cmd+W to close window should still work in copy mode).
func copyModeShouldBypassForShortcut(modifierFlags: NSEvent.ModifierFlags) -> Bool {
    let normalized = copyModeNormalizedModifiers(modifierFlags)
    return normalized.contains(.command)
}

// MARK: - Single-key action lookup (no state)

private func copyModeActionForKey(
    keyCode: UInt16,
    charactersIgnoringModifiers: String?,
    modifierFlags: NSEvent.ModifierFlags,
    hasSelection: Bool
) -> CopyModeAction? {
    let normalized = copyModeNormalizedModifiers(modifierFlags)
    let chars = copyModeChars(charactersIgnoringModifiers)

    if keyCode == 53 { // Escape
        return .exit
    }

    switch keyCode {
    case 126: // Up arrow
        return hasSelection ? .adjustSelection(.up) : .scrollLines(-1)
    case 125: // Down arrow
        return hasSelection ? .adjustSelection(.down) : .scrollLines(1)
    case 123: // Left arrow
        return hasSelection ? .adjustSelection(.left) : nil
    case 124: // Right arrow
        return hasSelection ? .adjustSelection(.right) : nil
    case 116: // Page Up
        return hasSelection ? .adjustSelection(.pageUp) : .scrollPage(-1)
    case 121: // Page Down
        return hasSelection ? .adjustSelection(.pageDown) : .scrollPage(1)
    case 115: // Home
        return hasSelection ? .adjustSelection(.home) : .scrollToTop
    case 119: // End
        return hasSelection ? .adjustSelection(.end) : .scrollToBottom
    default:
        break
    }

    if normalized == [.control] {
        if chars == "u" || chars == "\u{15}" {
            return hasSelection ? .adjustSelection(.pageUp) : .scrollHalfPage(-1)
        }
        if chars == "d" || chars == "\u{04}" {
            return hasSelection ? .adjustSelection(.pageDown) : .scrollHalfPage(1)
        }
        if chars == "b" || chars == "\u{02}" {
            return hasSelection ? .adjustSelection(.pageUp) : .scrollPage(-1)
        }
        if chars == "f" || chars == "\u{06}" {
            return hasSelection ? .adjustSelection(.pageDown) : .scrollPage(1)
        }
        if chars == "y" || chars == "\u{19}" {
            return hasSelection ? .adjustSelection(.up) : .scrollLines(-1)
        }
        if chars == "e" || chars == "\u{05}" {
            return hasSelection ? .adjustSelection(.down) : .scrollLines(1)
        }
        return nil
    }

    guard normalized.isEmpty || normalized == [.shift] else { return nil }

    switch chars {
    case "q":
        return .exit
    case "v":
        return hasSelection ? .clearSelection : .startSelection
    case "y":
        if normalized == [.shift], !hasSelection {
            return .copyLineAndExit
        }
        return hasSelection ? .copyAndExit : nil
    case "j":
        return hasSelection ? .adjustSelection(.down) : .scrollLines(1)
    case "k":
        return hasSelection ? .adjustSelection(.up) : .scrollLines(-1)
    case "h":
        return hasSelection ? .adjustSelection(.left) : nil
    case "l":
        return hasSelection ? .adjustSelection(.right) : nil
    case "w":
        return hasSelection ? .adjustSelection(.wordForward) : nil
    case "b":
        return hasSelection ? .adjustSelection(.wordBackward) : nil
    case "g":
        if normalized == [.shift] {
            return hasSelection ? .adjustSelection(.end) : .scrollToBottom
        }
        // Bare "g" is a prefix key handled in copyModeResolve.
        return nil
    case "0", "^":
        return hasSelection ? .adjustSelection(.beginningOfLine) : nil
    case "$", "4":
        guard chars == "$" || normalized == [.shift] else { return nil }
        return hasSelection ? .adjustSelection(.endOfLine) : nil
    case "{", "[":
        guard chars == "{" || normalized == [.shift] else { return nil }
        return .jumpToPrompt(-1)
    case "}", "]":
        guard chars == "}" || normalized == [.shift] else { return nil }
        return .jumpToPrompt(1)
    case "/":
        return .startSearch
    case "n":
        return normalized == [.shift] ? .searchPrevious : .searchNext
    default:
        return nil
    }
}

// MARK: - Main resolve function (with state)

/// Resolve a key event in copy mode, updating `state` and returning the resolution.
///
/// - Parameters:
///   - keyCode: NSEvent.keyCode
///   - chars: NSEvent.charactersIgnoringModifiers
///   - modifiers: NSEvent.modifierFlags
///   - hasSelection: whether the terminal currently has an active selection
///   - state: mutable copy-mode input state (handles count prefix, `yy`, `gg`)
/// - Returns: A `CopyModeResolution` — either `.perform(action, count:)` or `.consume`.
func copyModeResolve(
    keyCode: UInt16,
    chars: String?,
    modifiers: NSEvent.ModifierFlags,
    hasSelection: Bool,
    state: inout CopyModeInputState
) -> CopyModeResolution {
    let normalized = copyModeNormalizedModifiers(modifiers)
    let ch = copyModeChars(chars)

    if keyCode == 53 { // Escape always exits
        state.reset()
        return .perform(.exit, count: 1)
    }

    // Handle pending `yy` (line-yank): second `y` commits, anything else cancels.
    if state.pendingYankLine {
        if ch == "y", normalized.isEmpty || normalized == [.shift] {
            let count = copyModeClampCount(state.countPrefix ?? 1)
            state.reset()
            return .perform(.copyLineAndExit, count: count)
        }
        state.pendingYankLine = false
        // Fall through and treat this key as a fresh command.
    }

    // Handle pending `gg`: second `g` scrolls to top, anything else cancels.
    if state.pendingG {
        if ch == "g", normalized.isEmpty {
            let count = copyModeClampCount(state.countPrefix ?? 1)
            let action: CopyModeAction = hasSelection ? .adjustSelection(.home) : .scrollToTop
            state.reset()
            return .perform(action, count: count)
        }
        state.pendingG = false
        // Fall through.
    }

    // Digit prefix accumulation (1-9 start; 0 only extends an existing prefix).
    if normalized.isEmpty,
       let scalar = ch.unicodeScalars.first,
       scalar.isASCII,
       scalar.value >= 48,
       scalar.value <= 57 {
        let digit = Int(scalar.value - 48)
        if digit == 0 {
            if let current = state.countPrefix {
                state.countPrefix = copyModeClampCount(current * 10)
                return .consume
            }
            // Leading zero falls through to `0` → beginningOfLine.
        } else {
            let current = state.countPrefix ?? 0
            state.countPrefix = copyModeClampCount((current * 10) + digit)
            return .consume
        }
    }

    // `y` without selection begins a yank-line sequence.
    if !hasSelection, ch == "y", normalized.isEmpty {
        state.pendingYankLine = true
        return .consume
    }

    // Bare `g` begins a `gg` sequence.
    if ch == "g", normalized.isEmpty {
        state.pendingG = true
        return .consume
    }

    guard let action = copyModeActionForKey(
        keyCode: keyCode,
        charactersIgnoringModifiers: chars,
        modifierFlags: modifiers,
        hasSelection: hasSelection
    ) else {
        state.reset()
        return .consume
    }

    let count = copyModeClampCount(state.countPrefix ?? 1)
    state.reset()
    return .perform(action, count: count)
}

// MARK: - Action → binding-action string

/// Map a `CopyModeAction` to the Ghostty binding-action string used with
/// `ghostty_surface_binding_action`.  Returns nil for actions that are handled
/// natively in Swift (e.g. `.exit`).
func copyModeBindingAction(for action: CopyModeAction, count: Int) -> String? {
    switch action {
    case .exit:
        return "copy_mode:exit"
    case .startSelection:
        return "copy_mode:start_selection"
    case .clearSelection:
        return "copy_mode:clear_selection"
    case .copyAndExit:
        return "copy_to_clipboard"
    case .copyLineAndExit:
        return "copy_to_clipboard"
    case .scrollToTop:
        return "scroll_to_top"
    case .scrollToBottom:
        return "scroll_to_bottom"
    case .scrollLines(let n):
        let lines = n * count
        return "scroll_page_lines:\(lines)"
    case .scrollPage(let n):
        return n < 0 ? "scroll_page_up" : "scroll_page_down"
    case .scrollHalfPage(let n):
        let fraction: Float = n < 0 ? -0.5 : 0.5
        return "scroll_page_fractional:\(fraction)"
    case .jumpToPrompt(let dir):
        return "jump_to_prompt:\(dir * count)"
    case .startSearch:
        return "copy_mode:start_search"
    case .searchNext:
        return "copy_mode:search_next"
    case .searchPrevious:
        return "copy_mode:search_previous"
    case .adjustSelection(let move):
        switch move {
        case .up:           return "adjust_selection:up"
        case .down:         return "adjust_selection:down"
        case .left:         return "adjust_selection:left"
        case .right:        return "adjust_selection:right"
        case .pageUp:       return "adjust_selection:page_up"
        case .pageDown:     return "adjust_selection:page_down"
        case .home:         return "adjust_selection:home"
        case .end:          return "adjust_selection:end"
        case .beginningOfLine: return "adjust_selection:beginning_of_line"
        case .endOfLine:    return "adjust_selection:end_of_line"
        case .wordForward:  return "adjust_selection:word_right"
        case .wordBackward: return "adjust_selection:word_left"
        }
    }
}
