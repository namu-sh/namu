import AppKit
import Foundation
import Combine

/// Focus intent for panels — describes what kind of focus transition is happening.
enum FocusIntent {
    case capture    // Panel is gaining focus
    case restore    // Panel is regaining focus after temporary loss
    case resign     // Panel is losing focus
}

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

    /// Path to a scrollback replay file set during session restore.
    /// Shell integration reads MOSAIC_RESTORE_SCROLLBACK_FILE on startup to replay it.
    var scrollbackRestoreFile: String?

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
        session: TerminalSession? = nil
    ) {
        self.id = id
        self.workingDirectory = workingDirectory

        let sess = session ?? TerminalSession(id: id, workingDirectory: workingDirectory)
        self.session = sess
        self.title = sess.title.isEmpty ? "Terminal" : sess.title

        // Keep title in sync with the session.
        sess.$title
            .map { $0.isEmpty ? "Terminal" : $0 }
            .receive(on: DispatchQueue.main)
            .assign(to: &$title)
    }

    // MARK: - Focus

    func captureFocus() {
        session.setFocus(true)
    }

    func restoreFocus() {
        session.setFocus(true)
    }

    func resignFocus() {
        session.setFocus(false)
    }

    func handleFocus(_ intent: FocusIntent) {
        switch intent {
        case .capture: captureFocus()
        case .restore: restoreFocus()
        case .resign:  resignFocus()
        }
    }

    // MARK: - Lifecycle

    func close() {
        surfaceView.removeFromSuperview()
        session.destroy()
    }
}
