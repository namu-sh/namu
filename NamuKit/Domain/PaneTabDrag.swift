import Foundation
import UniformTypeIdentifiers

// MARK: - UTType extension

extension UTType {
    /// Custom type for dragging pane tabs across workspaces (sidebar drop target).
    public static let namuPaneTab = UTType(exportedAs: "xyz.omlabs.namu.panetab")
}

// MARK: - PaneTabDragPayload

/// Payload carried when a pane tab is dragged from one workspace to another.
public struct PaneTabDragPayload: Codable {
    public let panelID: UUID
    public let sourceWorkspaceID: UUID
    /// When non-nil, the drop should create a split pane instead of adding a tab.
    /// nil = add as tab, .horizontal/.vertical = split into new pane.
    public let splitTarget: SplitDirection?

    public init(panelID: UUID, sourceWorkspaceID: UUID, splitTarget: SplitDirection? = nil) {
        self.panelID = panelID
        self.sourceWorkspaceID = sourceWorkspaceID
        self.splitTarget = splitTarget
    }
}
