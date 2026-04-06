import SwiftUI

/// Renders a workspace using NamuSplitView — the single source of truth for
/// split layout, tabs, focus, and zoom. Replaces the old PaneTreeView approach.
struct WorkspaceView: View {
    let workspaceID: UUID
    let panelManager: PanelManager
    var isActive: Bool = true

    @ObservedObject private var workspaceManager: WorkspaceManager

    init(workspaceID: UUID, panelManager: PanelManager, isActive: Bool = true) {
        self.workspaceID = workspaceID
        self.panelManager = panelManager
        self.isActive = isActive
        self.workspaceManager = panelManager.workspaceManager
    }

    var body: some View {
        let controller = panelManager.controller(for: workspaceID)
        let engine = panelManager.engine(for: workspaceID)

        // Wrap in SafeAreaFreeView to zero the titlebar safe area inset.
        // Without this, NamuSplitView's GeometryReader receives a frame
        // offset by ~28pt from the top (the hidden titlebar height).
        SafeAreaFreeView {
            NamuSplitView(controller: controller) { tab, paneId in
                if let panelID = engine.panelID(for: tab.id) {
                    if tab.kind == "browser" {
                        BrowserPanelView(paneID: panelID)
                            .onTapGesture {
                                controller.focusPane(paneId)
                            }
                    } else if let panel = panelManager.panel(for: panelID) {
                        let isFocused = isActive && panelManager.focusedPanelID(in: workspaceID) == panelID
                        TerminalView(
                            panel: panel,
                            onActivate: {
                                // Focus handled in GhosttySurfaceView.mouseDown via onActivate.
                                // No .onTapGesture — it intercepts mouse events and breaks
                                // click-and-drag text selection in the terminal.
                                panelManager.activatePanel(id: panelID)
                                controller.focusPane(paneId)
                            },
                            isActive: isActive,
                            isKeyPane: isFocused
                        )
                    } else {
                        Color.clear
                    }
                } else {
                    Color.clear
                }
            } emptyPane: { paneId in
                Color.clear
                    .onAppear {
                        let eng = panelManager.engine(for: workspaceID)
                        // Only create a panel if this pane doesn't already have one
                        // (splitPane in PanelManager creates its own panel+tab immediately after splitting)
                        let hasMappedPanel = eng.splitController.tabs(inPane: paneId).contains { tab in
                            eng.panelID(for: tab.id) != nil
                        }
                        guard !hasMappedPanel else { return }

                        // Inherit working directory from the focused terminal
                        let cwd = panelManager.focusedPanelID(in: workspaceID).flatMap { panelManager.panel(for: $0)?.workingDirectory }
                        let panel = panelManager.createTerminalPanel(workspaceID: workspaceID, workingDirectory: cwd)
                        if let tabID = eng.createTab(title: String(localized: "workspace.defaultTab.terminal", defaultValue: "Terminal"), kind: "terminal", inPane: paneId) {
                            eng.registerMapping(tabID: tabID, panelID: panel.id)
                        }
                    }
            }
        }
        .id(workspaceManager.splitZoomRenderIdentity)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("namu-workspace-view")
    }
}
