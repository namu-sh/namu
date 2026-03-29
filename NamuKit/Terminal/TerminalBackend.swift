import Foundation
import AppKit

/// Abstraction over a terminal session. Production: TerminalSession (Ghostty).
/// Test: MockTerminalBackend. Future iOS: RelayBackend.
protocol TerminalBackend: AnyObject {
    var id: UUID { get }
    var title: String { get }
    var workingDirectory: String? { get }
    var isAlive: Bool { get }

    /// Create the terminal surface and start the shell.
    @MainActor
    func start(hostView: NSView, displayID: UInt32, app: GhosttyApp, config: GhosttyConfig)

    /// Send raw text to the terminal.
    func sendText(_ text: String)

    /// Send a named key (e.g. "ctrl-c", "enter") to the terminal.
    /// Returns true if the key name was recognised and dispatched.
    @discardableResult
    func sendNamedKey(_ name: String) -> Bool

    /// Read the visible (viewport) text from the terminal.
    func readVisibleText() -> String?

    /// Resize the terminal grid.
    func resize(width: UInt32, height: UInt32)

    /// Destroy the surface and mark the session dead.
    func destroy()
}
