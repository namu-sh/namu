import Foundation
import Bonsplit

// MARK: - Namu Layout Snapshot

/// Codable snapshot of a layout tree for persistence and restore.
/// Distinct from Bonsplit.LayoutSnapshot which represents pixel geometry.
/// This captures the tree structure for session save/restore.
/// Uses a class (reference type) because the tree is recursive.
final class NamuLayoutSnapshot: Codable, @unchecked Sendable {
    enum NodeType: String, Codable, Sendable {
        case pane
        case split
    }

    let type: NodeType
    let id: UUID

    // Pane properties (present when type == .pane)
    let panelType: String?

    // Split properties (present when type == .split)
    let orientation: Bonsplit.SplitOrientation?
    let ratio: Double?
    let first: NamuLayoutSnapshot?
    let second: NamuLayoutSnapshot?

    private init(
        type: NodeType, id: UUID,
        panelType: String?,
        orientation: Bonsplit.SplitOrientation?, ratio: Double?,
        first: NamuLayoutSnapshot?, second: NamuLayoutSnapshot?
    ) {
        self.type = type
        self.id = id
        self.panelType = panelType
        self.orientation = orientation
        self.ratio = ratio
        self.first = first
        self.second = second
    }

    /// Create a pane node.
    static func pane(id: UUID, panelType: String = "terminal") -> NamuLayoutSnapshot {
        NamuLayoutSnapshot(
            type: .pane, id: id,
            panelType: panelType,
            orientation: nil, ratio: nil, first: nil, second: nil
        )
    }

    /// Create a split node.
    static func split(
        id: UUID,
        orientation: Bonsplit.SplitOrientation,
        ratio: Double,
        first: NamuLayoutSnapshot,
        second: NamuLayoutSnapshot
    ) -> NamuLayoutSnapshot {
        NamuLayoutSnapshot(
            type: .split, id: id,
            panelType: nil,
            orientation: orientation, ratio: ratio,
            first: first, second: second
        )
    }
}

// MARK: - LayoutEngine Protocol

/// Abstraction over split-pane layout management.
/// Production: BonsplitLayoutEngine (Phase 0). Test: MockLayoutEngine.
@MainActor
protocol LayoutEngine: AnyObject {
    /// The underlying BonsplitController (for view rendering).
    var controller: BonsplitController { get }

    /// The currently focused pane, if any.
    var focusedPaneID: Bonsplit.PaneID? { get }

    /// All pane IDs in the layout, in document order.
    var allPaneIDs: [Bonsplit.PaneID] { get }

    /// Create a new tab in a pane. Returns the TabID of the created tab.
    @discardableResult
    func createTab(title: String, kind: String?, inPane: Bonsplit.PaneID?) -> Bonsplit.TabID?

    /// Split an existing pane, returning the new pane's ID.
    @discardableResult
    func splitPane(_ paneID: Bonsplit.PaneID?, orientation: Bonsplit.SplitOrientation) -> Bonsplit.PaneID?

    /// Close a pane, collapsing the tree if needed.
    @discardableResult
    func closePane(_ paneID: Bonsplit.PaneID) -> Bool

    /// Close a tab by ID.
    @discardableResult
    func closeTab(_ tabID: Bonsplit.TabID) -> Bool

    /// Set focus to a specific pane.
    func focusPane(_ paneID: Bonsplit.PaneID)

    /// Navigate focus in the given direction.
    func navigateFocus(_ direction: Bonsplit.NavigationDirection)

    /// Toggle zoom on a pane.
    @discardableResult
    func toggleZoom(_ paneID: Bonsplit.PaneID?) -> Bool

    /// Set the divider position for a split.
    @discardableResult
    func setDividerPosition(_ ratio: CGFloat, forSplit splitID: UUID) -> Bool

    /// Take a snapshot of the current layout for persistence.
    func treeSnapshot() -> ExternalTreeNode

    /// Get the pixel-geometry layout snapshot.
    func layoutSnapshot() -> Bonsplit.LayoutSnapshot
}
