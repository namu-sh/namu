import Foundation

// MARK: - Session State Machine

/// Explicit state machine for terminal session lifecycle.
/// Replaces scattered boolean tracking with validated transitions.
enum SessionState: Equatable, Sendable {
    /// Allocated but not yet started.
    case created
    /// Surface is being created.
    case starting
    /// Active terminal with a running process.
    case running
    /// Child process ended; surface may still be alive for display.
    case exited(code: Int32)
    /// All resources freed.
    case destroyed

    /// Whether the session can accept interactive input.
    var isInteractive: Bool {
        if case .running = self { return true }
        return false
    }

    /// Whether the session has been started and is still active.
    /// `.created` returns false (not yet started) to match the original
    /// `isAlive = false` default that TerminalView uses to trigger session.start().
    var isAlive: Bool {
        switch self {
        case .starting, .running: return true
        case .created, .exited, .destroyed: return false
        }
    }

    // MARK: - Transition Events

    enum Event: Sendable {
        case start
        case surfaceReady
        case childExited(Int32)
        case destroy
    }

    // MARK: - Transition

    /// Apply a state transition event. Throws on invalid transitions.
    mutating func handle(_ event: Event) throws {
        switch (self, event) {
        case (.created, .start):
            self = .starting
        case (.starting, .surfaceReady):
            self = .running
        case (.running, .childExited(let code)):
            self = .exited(code: code)
        case (.exited, .destroy), (.running, .destroy), (.starting, .destroy), (.created, .destroy):
            self = .destroyed
        default:
            throw SessionStateError.invalidTransition(from: self, event: event)
        }
    }
}

// MARK: - Error

enum SessionStateError: Error, CustomStringConvertible {
    case invalidTransition(from: SessionState, event: SessionState.Event)

    var description: String {
        switch self {
        case .invalidTransition(let from, let event):
            return "Invalid session state transition: \(from) + \(event)"
        }
    }
}
