import SwiftUI

// MARK: - WorkspaceView

/// Renders the full pane tree for a single workspace.
/// Takes the live workspace value and the PanelManager that owns focus/resize mutations.
struct WorkspaceView: View {
    let workspace: Workspace
    let panelManager: PanelManager
    var isActive: Bool = true

    var body: some View {
        GeometryReader { geo in
            PaneTreeView(
                tree: workspace.paneTree,
                focusedPaneID: workspace.focusedPanelID,
                panelManager: panelManager,
                availableSize: geo.size,
                isActive: isActive
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color.black)
    }
}
