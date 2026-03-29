import SwiftUI
import Bonsplit

/// Renders a workspace using BonsplitView — the single source of truth for
/// split layout, tabs, focus, and zoom. Replaces the old PaneTreeView approach.
struct WorkspaceView: View {
    let workspaceID: UUID
    let panelManager: PanelManager
    var isActive: Bool = true

    var body: some View {
        let controller = panelManager.controller(for: workspaceID)
        let engine = panelManager.engine(for: workspaceID)

        BonsplitView(controller: controller) { tab, paneId in
            // Content for each tab
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
                    Color.black
                }
            } else {
                Color.black
            }
        } emptyPane: { paneId in
            // Auto-create a terminal in empty panes instead of showing a welcome page
            Color.black
                .onAppear {
                    let eng = panelManager.engine(for: workspaceID)
                    let panel = panelManager.createTerminalPanel(workspaceID: workspaceID)
                    if let tabID = eng.createTab(title: "Terminal", kind: "terminal", inPane: paneId) {
                        eng.registerMapping(tabID: tabID, panelID: panel.id)
                    }

                }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("namu-workspace-view")
    }
}