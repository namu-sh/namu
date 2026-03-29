import Foundation
import Bonsplit

/// Concrete LayoutEngine implementation backed by BonsplitController.
/// Owns one BonsplitController per workspace and conforms to BonsplitDelegate
/// for receiving callbacks about tab/pane lifecycle events.
@MainActor
final class BonsplitLayoutEngine: LayoutEngine, BonsplitDelegate {

    // MARK: - Properties

    let controller: BonsplitController
    private weak var eventBus: TypedEventBus?
    let workspaceID: UUID

    /// Maps Bonsplit TabID -> Namu panel UUID for terminal/browser content lookup.
    private(set) var tabToPanelID: [Bonsplit.TabID: UUID] = [:]

    /// Reverse map: Namu panel UUID -> Bonsplit TabID.
    private(set) var panelIDToTab: [UUID: Bonsplit.TabID] = [:]

    // MARK: - Init

    init(
        workspaceID: UUID,
        configuration: BonsplitConfiguration = BonsplitConfiguration(
            allowCloseLastPane: false,
            contentViewLifecycle: .keepAllAlive
        ),
        eventBus: TypedEventBus? = nil
    ) {
        self.workspaceID = workspaceID
        self.eventBus = eventBus
        self.controller = BonsplitController(configuration: configuration)
        self.controller.delegate = self

        // Handle tab close requests from the tab strip UI
        controller.onTabCloseRequest = { [weak self] tabId, paneId in
            guard let self else { return }
            self.handleTabCloseRequest(tabId: tabId, paneId: paneId)
        }
    }

    // MARK: - LayoutEngine Protocol

    var focusedPaneID: Bonsplit.PaneID? {
        controller.focusedPaneId
    }

    var allPaneIDs: [Bonsplit.PaneID] {
        controller.allPaneIds
    }

    @discardableResult
    func createTab(title: String, kind: String?, inPane pane: Bonsplit.PaneID?) -> Bonsplit.TabID? {
        controller.createTab(title: title, kind: kind, inPane: pane)
    }

    @discardableResult
    func splitPane(_ paneID: Bonsplit.PaneID?, orientation: Bonsplit.SplitOrientation) -> Bonsplit.PaneID? {
        controller.splitPane(paneID, orientation: orientation)
    }

    @discardableResult
    func closePane(_ paneID: Bonsplit.PaneID) -> Bool {
        controller.closePane(paneID)
    }

    @discardableResult
    func closeTab(_ tabID: Bonsplit.TabID) -> Bool {
        controller.closeTab(tabID)
    }

    func focusPane(_ paneID: Bonsplit.PaneID) {
        controller.focusPane(paneID)
    }

    func navigateFocus(_ direction: Bonsplit.NavigationDirection) {
        controller.navigateFocus(direction: direction)
    }

    @discardableResult
    func toggleZoom(_ paneID: Bonsplit.PaneID?) -> Bool {
        controller.togglePaneZoom(inPane: paneID)
    }

    @discardableResult
    func setDividerPosition(_ ratio: CGFloat, forSplit splitID: UUID) -> Bool {
        controller.setDividerPosition(ratio, forSplit: splitID)
    }

    func treeSnapshot() -> ExternalTreeNode {
        controller.treeSnapshot()
    }

    func layoutSnapshot() -> Bonsplit.LayoutSnapshot {
        controller.layoutSnapshot()
    }

    // MARK: - Tab ↔ Panel Mapping

    /// Register a mapping between a Bonsplit tab and a Namu panel UUID.
    func registerMapping(tabID: Bonsplit.TabID, panelID: UUID) {
        tabToPanelID[tabID] = panelID
        panelIDToTab[panelID] = tabID
    }

    /// Remove mapping for a tab.
    func removeMapping(tabID: Bonsplit.TabID) {
        if let panelID = tabToPanelID.removeValue(forKey: tabID) {
            panelIDToTab.removeValue(forKey: panelID)
        }
    }

    /// Remove mapping for a panel.
    func removeMapping(panelID: UUID) {
        if let tabID = panelIDToTab.removeValue(forKey: panelID) {
            tabToPanelID.removeValue(forKey: tabID)
        }
    }

    /// Look up the panel UUID for a Bonsplit tab.
    func panelID(for tabID: Bonsplit.TabID) -> UUID? {
        tabToPanelID[tabID]
    }

    /// Look up the Bonsplit tab for a panel UUID.
    func tabID(for panelID: UUID) -> Bonsplit.TabID? {
        panelIDToTab[panelID]
    }

    // MARK: - Tab Close Request

    private func handleTabCloseRequest(tabId: Bonsplit.TabID, paneId: Bonsplit.PaneID) {
        // This will be wired to PanelManager.closePanel() which handles cleanup
        guard let panelID = tabToPanelID[tabId] else { return }
        Task { @MainActor in
            if let eventBus = self.eventBus {
                await eventBus.publish(.paneClosed(panelID: panelID, workspaceID: self.workspaceID))
            }
        }
    }

    // MARK: - BonsplitDelegate

    func splitTabBar(_ controller: BonsplitController, shouldCreateTab tab: Bonsplit.Tab, inPane pane: Bonsplit.PaneID) -> Bool {
        true
    }

    func splitTabBar(_ controller: BonsplitController, shouldCloseTab tab: Bonsplit.Tab, inPane pane: Bonsplit.PaneID) -> Bool {
        true
    }

    func splitTabBar(_ controller: BonsplitController, didCreateTab tab: Bonsplit.Tab, inPane pane: Bonsplit.PaneID) {
        // Panel creation is handled by PanelManager when it calls createTab
    }

    func splitTabBar(_ controller: BonsplitController, didCloseTab tabId: Bonsplit.TabID, fromPane pane: Bonsplit.PaneID) {
        if let panelID = tabToPanelID[tabId] {
            removeMapping(tabID: tabId)
            Task {
                await eventBus?.publish(.paneClosed(panelID: panelID, workspaceID: workspaceID))
            }
        }
    }

    func splitTabBar(_ controller: BonsplitController, didSelectTab tab: Bonsplit.Tab, inPane pane: Bonsplit.PaneID) {
        // Tab selection within a pane — could update focus tracking
    }

    func splitTabBar(_ controller: BonsplitController, shouldSplitPane pane: Bonsplit.PaneID, orientation: Bonsplit.SplitOrientation) -> Bool {
        true
    }

    func splitTabBar(_ controller: BonsplitController, shouldClosePane pane: Bonsplit.PaneID) -> Bool {
        true
    }

    func splitTabBar(_ controller: BonsplitController, didSplitPane originalPane: Bonsplit.PaneID, newPane: Bonsplit.PaneID, orientation: Bonsplit.SplitOrientation) {
        // PanelManager creates the panel for the new pane
    }

    func splitTabBar(_ controller: BonsplitController, didClosePane paneId: Bonsplit.PaneID) {
        // Pane closed — PanelManager handles cleanup via the tab close callback
    }

    func splitTabBar(_ controller: BonsplitController, didFocusPane pane: Bonsplit.PaneID) {
        // Find the selected tab's panel ID for focus tracking
        if let selectedTab = controller.selectedTab(inPane: pane),
           let panelID = tabToPanelID[selectedTab.id] {
            Task {
                await eventBus?.publish(.focusChanged(workspaceID: workspaceID, from: nil, to: panelID))
            }
        }
    }

    /// Callback for new tab requests from the tab bar's + button.
    /// Set by PanelManager to create a terminal panel in the requesting pane.
    var onNewTabRequested: ((_ kind: String, _ pane: Bonsplit.PaneID) -> Void)?

    func splitTabBar(_ controller: BonsplitController, didRequestNewTab kind: String, inPane pane: Bonsplit.PaneID) {
        onNewTabRequested?(kind, pane)
    }

    func splitTabBar(_ controller: BonsplitController, didChangeGeometry snapshot: Bonsplit.LayoutSnapshot) {
        // Could forward to event bus for tmux compat / IPC geometry reporting
    }
}
