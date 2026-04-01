import SwiftUI
import Bonsplit

/// Renders a workspace using BonsplitView — the single source of truth for
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
        // Without this, BonsplitView's GeometryReader receives a frame
        // offset by ~28pt from the top (the hidden titlebar height).
        SafeAreaFreeView {
            BonsplitView(controller: controller) { tab, paneId in
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
                                panelManager.activatePanel(id: panelID)
                            },
                            isActive: isActive,
                            isKeyPane: isFocused
                        )
                        .onTapGesture {
                            controller.focusPane(paneId)
                        }
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
                        let panel = panelManager.createTerminalPanel(workspaceID: workspaceID)
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
