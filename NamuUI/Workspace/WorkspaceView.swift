import SwiftUI

// MARK: - WorkspaceView

/// Renders the full pane tree for a single workspace using PaneTreeView.
///
/// NOTE: BonsplitView integration requires removing PaneTree entirely and making
/// BonsplitController the sole source of truth (like Namu does). The current
/// dual-model approach (PaneTree for data + BonsplitController for rendering)
/// has fundamental sync issues. The LayoutEngine protocol and BonsplitLayoutEngine
/// are in place for when this migration is done properly.
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
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("namu-workspace-view")
    }
}
