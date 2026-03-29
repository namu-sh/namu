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
            if let panelID = engine.panelID(for: tab.id),
               let panel = panelManager.panel(for: panelID) {
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
        } emptyPane: { paneId in
            // Auto-create a terminal in empty panes instead of showing a welcome page
            Color.black
                .onAppear {
                    let eng = panelManager.engine(for: workspaceID)
                    let panel = panelManager.createTerminalPanel(workspaceID: workspaceID)
                    if let tabID = eng.createTab(title: "Terminal", kind: "terminal", inPane: paneId) {
                        eng.registerMapping(tabID: tabID, panelID: panel.id)
                    }
                    panelManager.syncWorkspaceFromEngine(workspaceID)
                }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("namu-workspace-view")
    }
}

// MARK: - EmptyPanelView

/// Shown for panes with no tabs — offers buttons to create a terminal or browser.
struct EmptyPanelView: View {
    let panelManager: PanelManager
    let workspaceID: UUID
    let paneId: Bonsplit.PaneID

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "terminal.fill")
                .font(.system(size: 48))
                .foregroundStyle(.tertiary)

            Text("Empty Panel")
                .font(.headline)
                .foregroundStyle(.secondary)

            HStack(spacing: 12) {
                Button("Terminal") {
                    let eng = panelManager.engine(for: workspaceID)
                    eng.controller.focusPane(paneId)
                    let panel = panelManager.createTerminalPanel(workspaceID: workspaceID)
                    if let tabID = eng.createTab(title: "Terminal", kind: "terminal", inPane: paneId) {
                        eng.registerMapping(tabID: tabID, panelID: panel.id)
                    }
                }
                .buttonStyle(.borderedProminent)

                Button("Browser") {
                    // Browser panel creation — placeholder
                    let eng = panelManager.engine(for: workspaceID)
                    eng.controller.focusPane(paneId)
                    if let _ = eng.createTab(title: "Browser", kind: "browser", inPane: paneId) {
                        // Browser panels don't have a backing TerminalPanel
                    }
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
    }
}
