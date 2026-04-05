import Foundation
import UniformTypeIdentifiers

/// Concrete LayoutEngine implementation backed by LayoutTreeController.
/// Owns one LayoutTreeController per workspace and conforms to NamuSplitDelegate
/// for receiving callbacks about tab/pane lifecycle events.
@MainActor
final class NamuSplitLayoutEngine: LayoutEngine, NamuSplitDelegate {

    // MARK: - Properties

    let splitController: LayoutTreeController
    private weak var eventBus: TypedEventBus?
    let workspaceID: UUID

    /// Maps NamuSplit TabID -> Namu panel UUID for terminal/browser content lookup.
    private(set) var tabToPanelID: [TabID: UUID] = [:]

    /// Reverse map: Namu panel UUID -> NamuSplit TabID.
    private(set) var panelIDToTab: [UUID: TabID] = [:]

    // MARK: - Init

    init(
        workspaceID: UUID,
        configuration: NamuSplitConfiguration = NamuSplitConfiguration(
            allowCloseLastPane: false,
            contentViewLifecycle: .keepAllAlive
        ),
        eventBus: TypedEventBus? = nil
    ) {
        self.workspaceID = workspaceID
        self.eventBus = eventBus
        self.splitController = LayoutTreeController(configuration: configuration)
        self.splitController.delegate = self

        // Handle tab close requests from the tab strip UI
        splitController.onTabCloseRequest = { [weak self] tabId, paneId in
            guard let self else { return }
            self.handleTabCloseRequest(tabId: tabId, paneId: paneId)
        }

        // Attach namuPaneTab payload to tab drags so the sidebar WorkspaceDropDelegate
        // can receive them as cross-workspace drops.
        splitController.onCreateAdditionalDragPayload = { [weak self] tabId in
            guard let self,
                  let panelID = self.tabToPanelID[tabId] else { return [] }
            let payload = PaneTabDragPayload(
                panelID: panelID,
                sourceWorkspaceID: self.workspaceID
            )
            guard let data = try? JSONEncoder().encode(payload) else { return [] }
            return [(typeIdentifier: UTType.namuPaneTab.identifier, data: data)]
        }
    }

    // MARK: - LayoutEngine Protocol

    var focusedPaneID: PaneID? {
        splitController.focusedPaneId
    }

    var allPaneIDs: [PaneID] {
        splitController.allPaneIds
    }

    @discardableResult
    func createTab(title: String, kind: String?, inPane pane: PaneID?) -> TabID? {
        splitController.createTab(title: title, kind: kind, inPane: pane)
    }

    @discardableResult
    func splitPane(_ paneID: PaneID?, orientation: SplitOrientation) -> PaneID? {
        splitController.splitPane(paneID, orientation: orientation)
    }

    @discardableResult
    func closePane(_ paneID: PaneID) -> Bool {
        splitController.closePane(paneID)
    }

    @discardableResult
    func closeTab(_ tabID: TabID) -> Bool {
        splitController.closeTab(tabID)
    }

    /// Move a tab to a different pane (or reorder within the same pane).
    @discardableResult
    func moveTab(_ tabID: TabID, toPane paneID: PaneID, atIndex index: Int? = nil) -> Bool {
        splitController.moveTab(tabID, toPane: paneID, atIndex: index)
    }

    /// Reorder a tab within its current pane.
    @discardableResult
    func reorderTab(_ tabID: TabID, toIndex: Int) -> Bool {
        splitController.reorderTab(tabID, toIndex: toIndex)
    }

    /// Split a pane by moving an existing tab into the new pane.
    @discardableResult
    func splitPaneWithMovingTab(
        id panelID: UUID,
        direction: SplitDirection,
        insertFirst: Bool
    ) -> PaneID? {
        guard let tabID = panelIDToTab[panelID] else { return nil }
        let orientation: SplitOrientation = direction == .horizontal ? .horizontal : .vertical
        return splitController.splitPane(nil, orientation: orientation, movingTab: tabID, insertFirst: insertFirst)
    }

    func focusPane(_ paneID: PaneID) {
        splitController.focusPane(paneID)
    }

    func navigateFocus(_ direction: NavigationDirection) {
        splitController.navigateFocus(direction: direction)
    }

    @discardableResult
    func toggleZoom(_ paneID: PaneID?) -> Bool {
        splitController.togglePaneZoom(inPane: paneID)
    }

    @discardableResult
    func setDividerPosition(_ ratio: CGFloat, forSplit splitID: UUID) -> Bool {
        splitController.setDividerPosition(ratio, forSplit: splitID)
    }

    func treeSnapshot() -> ExternalTreeNode {
        splitController.treeSnapshot()
    }

    func layoutSnapshot() -> LayoutSnapshot {
        splitController.layoutSnapshot()
    }

    // MARK: - Tab ↔ Panel Mapping

    func registerMapping(tabID: TabID, panelID: UUID) {
        tabToPanelID[tabID] = panelID
        panelIDToTab[panelID] = tabID
    }

    func removeMapping(tabID: TabID) {
        if let panelID = tabToPanelID.removeValue(forKey: tabID) {
            panelIDToTab.removeValue(forKey: panelID)
        }
    }

    func removeMapping(panelID: UUID) {
        if let tabID = panelIDToTab.removeValue(forKey: panelID) {
            tabToPanelID.removeValue(forKey: tabID)
        }
    }

    func panelID(for tabID: TabID) -> UUID? {
        tabToPanelID[tabID]
    }

    func tabID(for panelID: UUID) -> TabID? {
        panelIDToTab[panelID]
    }

    // MARK: - Tab Close Request

    private func handleTabCloseRequest(tabId: TabID, paneId: PaneID) {
        guard let panelID = tabToPanelID[tabId] else { return }
        Task { @MainActor in
            if let eventBus = self.eventBus {
                await eventBus.publish(.paneClosed(panelID: panelID, workspaceID: self.workspaceID))
            }
        }
    }

    // MARK: - NamuSplitDelegate

    func splitController(_ controller: LayoutTreeController, shouldCreateTab tab: Tab, inPane pane: PaneID) -> Bool {
        true
    }

    func splitController(_ controller: LayoutTreeController, shouldCloseTab tab: Tab, inPane pane: PaneID) -> Bool {
        true
    }

    func splitController(_ controller: LayoutTreeController, didCreateTab tab: Tab, inPane pane: PaneID) {
    }

    func splitController(_ controller: LayoutTreeController, didCloseTab tabId: TabID, fromPane pane: PaneID) {
        if let panelID = tabToPanelID[tabId] {
            removeMapping(tabID: tabId)
            Task {
                await eventBus?.publish(.paneClosed(panelID: panelID, workspaceID: workspaceID))
            }
        }
    }

    func splitController(_ controller: LayoutTreeController, didSelectTab tab: Tab, inPane pane: PaneID) {
    }

    func splitController(_ controller: LayoutTreeController, shouldSplitPane pane: PaneID, orientation: SplitOrientation) -> Bool {
        true
    }

    func splitController(_ controller: LayoutTreeController, shouldClosePane pane: PaneID) -> Bool {
        true
    }

    func splitController(_ controller: LayoutTreeController, didSplitPane originalPane: PaneID, newPane: PaneID, orientation: SplitOrientation) {
    }

    func splitController(_ controller: LayoutTreeController, didClosePane paneId: PaneID) {
    }

    func splitController(_ controller: LayoutTreeController, didFocusPane pane: PaneID) {
        if let selectedTab = controller.selectedTab(inPane: pane),
           let panelID = tabToPanelID[selectedTab.id] {
            Task {
                await eventBus?.publish(.focusChanged(workspaceID: workspaceID, from: nil, to: panelID))
            }
        }
    }

    /// Callback for new tab requests from the tab bar's + button.
    var onNewTabRequested: ((_ kind: String, _ pane: PaneID) -> Void)?

    func splitController(_ controller: LayoutTreeController, didRequestNewTab kind: String, inPane pane: PaneID) {
        onNewTabRequested?(kind, pane)
    }

    func splitController(_ controller: LayoutTreeController, didChangeGeometry snapshot: LayoutSnapshot) {
    }
}
