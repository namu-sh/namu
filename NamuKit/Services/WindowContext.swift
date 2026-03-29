import Foundation
import CoreGraphics

// MARK: - WindowContext

/// Per-window state container. Each NSWindow gets its own WorkspaceManager and PanelManager
/// so workspaces and panels are fully isolated between windows.
struct WindowContext {
    let windowID: UUID
    let workspaceManager: WorkspaceManager
    let panelManager: PanelManager

    /// Window frame in screen coordinates. Populated just before session save so
    /// SessionPersistence can serialize it without needing an AppKit import.
    var windowFrame: CGRect?

    /// Whether the sidebar is currently collapsed.
    var sidebarCollapsed: Bool = false

    /// Current sidebar width in points.
    var sidebarWidth: Double = 220
}
