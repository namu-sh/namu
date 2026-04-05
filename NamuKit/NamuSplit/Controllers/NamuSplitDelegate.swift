import Foundation

/// Protocol for receiving callbacks about split/tab lifecycle events
@MainActor
protocol NamuSplitDelegate: AnyObject {
    // MARK: - Tab Lifecycle (Veto Operations)

    func splitController(_ controller: LayoutTreeController, shouldCreateTab tab: Tab, inPane pane: PaneID) -> Bool
    func splitController(_ controller: LayoutTreeController, shouldCloseTab tab: Tab, inPane pane: PaneID) -> Bool

    // MARK: - Tab Lifecycle (Notifications)

    func splitController(_ controller: LayoutTreeController, didCreateTab tab: Tab, inPane pane: PaneID)
    func splitController(_ controller: LayoutTreeController, didCloseTab tabId: TabID, fromPane pane: PaneID)
    func splitController(_ controller: LayoutTreeController, didSelectTab tab: Tab, inPane pane: PaneID)
    func splitController(_ controller: LayoutTreeController, didMoveTab tab: Tab, fromPane source: PaneID, toPane destination: PaneID)

    // MARK: - Split Lifecycle (Veto Operations)

    func splitController(_ controller: LayoutTreeController, shouldSplitPane pane: PaneID, orientation: SplitOrientation) -> Bool
    func splitController(_ controller: LayoutTreeController, shouldClosePane pane: PaneID) -> Bool

    // MARK: - Split Lifecycle (Notifications)

    func splitController(_ controller: LayoutTreeController, didSplitPane originalPane: PaneID, newPane: PaneID, orientation: SplitOrientation)
    func splitController(_ controller: LayoutTreeController, didClosePane paneId: PaneID)

    // MARK: - Focus

    func splitController(_ controller: LayoutTreeController, didFocusPane pane: PaneID)

    // MARK: - New Tab Request

    func splitController(_ controller: LayoutTreeController, didRequestNewTab kind: String, inPane pane: PaneID)
    func splitController(_ controller: LayoutTreeController, didRequestTabContextAction action: TabContextAction, for tab: Tab, inPane pane: PaneID)

    // MARK: - Geometry

    func splitController(_ controller: LayoutTreeController, didChangeGeometry snapshot: LayoutSnapshot)
    func splitController(_ controller: LayoutTreeController, shouldNotifyDuringDrag: Bool) -> Bool
}

// MARK: - Default Implementations (all methods optional)

extension NamuSplitDelegate {
    func splitController(_ controller: LayoutTreeController, shouldCreateTab tab: Tab, inPane pane: PaneID) -> Bool { true }
    func splitController(_ controller: LayoutTreeController, shouldCloseTab tab: Tab, inPane pane: PaneID) -> Bool { true }
    func splitController(_ controller: LayoutTreeController, didCreateTab tab: Tab, inPane pane: PaneID) {}
    func splitController(_ controller: LayoutTreeController, didCloseTab tabId: TabID, fromPane pane: PaneID) {}
    func splitController(_ controller: LayoutTreeController, didSelectTab tab: Tab, inPane pane: PaneID) {}
    func splitController(_ controller: LayoutTreeController, didMoveTab tab: Tab, fromPane source: PaneID, toPane destination: PaneID) {}
    func splitController(_ controller: LayoutTreeController, shouldSplitPane pane: PaneID, orientation: SplitOrientation) -> Bool { true }
    func splitController(_ controller: LayoutTreeController, shouldClosePane pane: PaneID) -> Bool { true }
    func splitController(_ controller: LayoutTreeController, didSplitPane originalPane: PaneID, newPane: PaneID, orientation: SplitOrientation) {}
    func splitController(_ controller: LayoutTreeController, didClosePane paneId: PaneID) {}
    func splitController(_ controller: LayoutTreeController, didFocusPane pane: PaneID) {}
    func splitController(_ controller: LayoutTreeController, didRequestNewTab kind: String, inPane pane: PaneID) {}
    func splitController(_ controller: LayoutTreeController, didRequestTabContextAction action: TabContextAction, for tab: Tab, inPane pane: PaneID) {}
    func splitController(_ controller: LayoutTreeController, didChangeGeometry snapshot: LayoutSnapshot) {}
    func splitController(_ controller: LayoutTreeController, shouldNotifyDuringDrag: Bool) -> Bool { false }
}
