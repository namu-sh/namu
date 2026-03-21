import Foundation

/// A named unit of work shown as a tab in the sidebar.
/// Pure value type — no UI dependencies.
struct Workspace: Identifiable, Codable, Equatable {
    let id: UUID
    var title: String
    var order: Int
    var isPinned: Bool
    var createdAt: Date

    /// The layout tree for this workspace's panes.
    var paneTree: PaneTree

    /// The panel currently receiving keyboard input.
    var focusedPanelID: UUID?

    // MARK: - Computed properties

    /// Total number of panels in the workspace.
    var panelCount: Int {
        paneTree.paneCount
    }

    /// Flat list of all panel leaves in the workspace.
    var allPanels: [PaneLeaf] {
        paneTree.allPanels
    }

    // MARK: - Init

    init(
        id: UUID = UUID(),
        title: String = String(localized: "workspace.default.title", defaultValue: "New Workspace"),
        order: Int = 0,
        isPinned: Bool = false,
        createdAt: Date = Date(),
        paneTree: PaneTree? = nil,
        focusedPanelID: UUID? = nil
    ) {
        self.id = id
        self.title = title
        self.order = order
        self.isPinned = isPinned
        self.createdAt = createdAt
        let initialLeaf = PaneLeaf()
        let tree = paneTree ?? .pane(initialLeaf)
        self.paneTree = tree
        self.focusedPanelID = focusedPanelID ?? {
            // Default focus to the first panel in the provided (or new) tree
            if case .pane(let leaf) = tree { return leaf.id }
            return tree.allPanels.first?.id
        }()
    }
}
