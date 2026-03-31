import AppKit
import Foundation
import Combine

/// Focus intent for panels — describes what kind of focus transition is happening.
enum FocusIntent {
    case capture    // Panel is gaining focus
    case resign     // Panel is losing focus
}

// MARK: - SearchState

/// Active find/search state for a terminal panel.
struct SearchState {
    var needle: String
    var total: UInt?
    var selected: UInt?
}

// MARK: - ScrollbarState

/// Scrollbar position reported by Ghostty for a terminal surface.
struct ScrollbarState {
    var total: UInt64 = 0
    var offset: UInt64 = 0
    var length: UInt64 = 0

    var isVisible: Bool { total > 0 && length < total }
    var position: Double {
        guard total > 0 else { return 0 }
        return Double(offset) / Double(total)
    }
}

// MARK: - Panel protocol

/// Protocol for all panel types in the pane tree.
protocol Panel: AnyObject, Identifiable where ID == UUID {
    var id: UUID { get }
    var panelType: PanelType { get }
    var title: String { get }

    /// Handle focus transitions.
    func handleFocus(_ intent: FocusIntent)

    /// Clean up resources when the panel is closed.
    func close()
}

// MARK: - TerminalPanel

/// Concrete panel that wraps a TerminalSession.
/// ObservableObject so views can react to title/focus changes.
final class TerminalPanel: Panel, ObservableObject {

    // MARK: - Identity

    let id: UUID
    let panelType: PanelType = .terminal

    // MARK: - Published state

    /// Display title — mirrors the session's process title when available.
    @Published private(set) var title: String

    /// Working directory path reported by shell integration.
    @Published private(set) var workingDirectory: String?

    /// Current git branch reported by shell integration.
    @Published private(set) var gitBranch: String?

    /// User-supplied custom title for this pane (overrides process title in sidebar).
    @Published var customTitle: String?

    /// Path to a scrollback replay file set during session restore.
    /// Shell integration reads NAMU_RESTORE_SCROLLBACK_FILE on startup to replay it.
    var scrollbackRestoreFile: String?

    /// Active find/search state. Non-nil when a search is in progress.
    @Published var searchState: SearchState?

    /// Most recent cell size (character cell width/height in points) reported by Ghostty.
    /// Used by Phase 3 geometry variables for tmux compat.
    @Published var cellSize: CGSize = .zero

    /// Most recent scrollbar state reported by Ghostty.
    @Published var scrollbarState: ScrollbarState = .init()

    // MARK: - Shell integration state

    /// Most recent shell state reported by OSC 133 shell integration.
    /// Updated via `report_shell_state` IPC command from namu.zsh.
    /// Starts as `.unknown` — transitions to `.running` / `.prompt` / `.idle` as integration fires.
    @Published private(set) var shellState: ShellState = .unknown

    /// Update the shell state from IPC (called by SurfaceCommands.reportShellState).
    func updateShellState(_ state: ShellState) {
        shellState = state
    }

    // MARK: - Session

    let session: TerminalSession

    // MARK: - Persistent surface view

    /// The persistent AppKit surface view for this panel.
    /// Created lazily on first access and kept alive for the panel's entire lifetime.
    /// SwiftUI may destroy/recreate its container NSView on tab switch, but this
    /// view is merely reparented (removed/added as subview), not deallocated.
    private(set) lazy var surfaceView: GhosttySurfaceView = {
        let view = GhosttySurfaceView(frame: .zero)
        view.session = session
        return view
    }()

    // MARK: - Init

    init(
        id: UUID = UUID(),
        workingDirectory: String? = nil,
        environmentVariables: [String: String] = [:],
        waitAfterCommand: Bool = false,
        initialInput: String? = nil,
        fontSizeOverride: Float? = nil,
        session: TerminalSession? = nil
    ) {
        self.id = id
        self.workingDirectory = workingDirectory

        let sess = session ?? TerminalSession(
            id: id,
            workingDirectory: workingDirectory,
            environmentVariables: environmentVariables,
            waitAfterCommand: waitAfterCommand,
            initialInput: initialInput,
            fontSizeOverride: fontSizeOverride
        )
        self.session = sess
        self.title = sess.title.isEmpty ? "Terminal" : sess.title

        // Keep title in sync with the session.
        sess.$title
            .map { $0.isEmpty ? "Terminal" : $0 }
            .receive(on: DispatchQueue.main)
            .assign(to: &$title)
    }

    // MARK: - Restore helpers

    /// Seed the git branch from a persisted snapshot (avoids waiting for shell integration to report).
    func restoreGitBranch(_ branch: String) {
        gitBranch = branch
    }

    // MARK: - Focus

    func handleFocus(_ intent: FocusIntent) {
        switch intent {
        case .capture: session.setFocus(true)
        case .resign:  session.setFocus(false)
        }
    }

    // MARK: - Lifecycle

    func close() {
        surfaceView.removeFromSuperview()
        session.destroy()
    }
}

// MARK: - DetachedSurfaceTransfer

/// Encapsulates all data needed to move a panel between panes or workspaces.
/// Created by `PanelManager.detachPanel`, consumed by `PanelManager.attachPanel`.
struct DetachedSurfaceTransfer {
    let panelID: UUID
    let panelType: PanelType
    let title: String
    let isPinned: Bool
    let customTitle: String?
    let workingDirectory: String?

    /// The tab kind string used when re-creating the tab in Bonsplit (e.g. "terminal", "browser", "markdown").
    let tabKind: String

    /// The actual panel object. Stored as `AnyObject` because it can be
    /// `TerminalPanel`, `BrowserPanel`, or `MarkdownPanel`.
    let panel: AnyObject
}
