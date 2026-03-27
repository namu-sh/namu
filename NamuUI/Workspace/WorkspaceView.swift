import SwiftUI

// MARK: - WorkspaceView

/// Renders the full pane tree for a single workspace.
/// Takes the live workspace value and the PanelManager that owns focus/resize mutations.
struct WorkspaceView: View {
    let workspace: Workspace
    let panelManager: PanelManager
    var isActive: Bool = true

    var body: some View {
        let zoomState = panelManager.zoomState(for: workspace.id)
        GeometryReader { geo in
            PaneTreeView(
                tree: workspace.paneTree,
                activePaneID: workspace.activePanelID,
                panelManager: panelManager,
                availableSize: geo.size,
                isActive: isActive,
                zoomedPaneID: zoomState.isZoomed ? zoomState.zoomedPanelID : nil
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color.black)
    }
}
