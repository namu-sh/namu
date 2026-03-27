import Foundation

// MARK: - WindowContext

/// Per-window state container. Each NSWindow gets its own WorkspaceManager and PanelManager
/// so workspaces and panels are fully isolated between windows.
struct WindowContext {
    let windowID: UUID
    let workspaceManager: WorkspaceManager
    let panelManager: PanelManager
}
