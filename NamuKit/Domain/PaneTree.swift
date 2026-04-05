import Foundation

/// Direction of a split in the pane tree.
public enum SplitDirection: String, Codable {
    case horizontal
    case vertical
}

/// Cardinal navigation direction for spatial focus movement.
enum NavigationDirection: Sendable {
    case left, right, up, down
}

/// A binary tree of splits where each leaf is a panel.
/// Uses indirect enum for recursive structure with copy-on-write semantics.
indirect enum PaneTree: Identifiable, Equatable, Codable {
    case pane(PaneLeaf)
    case split(PaneSplit)

    var id: UUID {
        switch self {
        case .pane(let leaf): leaf.id
        case .split(let split): split.id
        }
    }

    // MARK: - Queries

    /// Find a pane by ID in the tree.
    func findPane(id: UUID) -> PaneLeaf? {
        switch self {
        case .pane(let leaf):
            return leaf.id == id ? leaf : nil
        case .split(let split):
            return split.first.findPane(id: id) ?? split.second.findPane(id: id)
        }
    }

    /// Count total panes in the tree.
    var paneCount: Int {
        switch self {
        case .pane: 1
        case .split(let split): split.first.paneCount + split.second.paneCount
        }
    }

    /// Flat list of all leaf panels in document order (depth-first, left-to-right).
    var allPanels: [PaneLeaf] {
        switch self {
        case .pane(let leaf):
            return [leaf]
        case .split(let split):
            return split.first.allPanels + split.second.allPanels
        }
    }

    // MARK: - Mutations (immutable — return new tree)

    /// Insert a split at the pane identified by `panelID`.
    /// The existing pane becomes the `first` child; `newPanel` becomes the `second`.
    /// Returns the modified tree, or the unmodified tree if `panelID` is not found.
    func insertSplit(
        at panelID: UUID,
        direction: SplitDirection,
        newPanel: PaneLeaf,
        ratio: Double = 0.5
    ) -> PaneTree {
        switch self {
        case .pane(let leaf):
            guard leaf.id == panelID else { return self }
            let split = PaneSplit(
                direction: direction,
                ratio: ratio,
                first: .pane(leaf),
                second: .pane(newPanel)
            )
            return .split(split)

        case .split(var split):
            split.first = split.first.insertSplit(at: panelID, direction: direction, newPanel: newPanel, ratio: ratio)
            split.second = split.second.insertSplit(at: panelID, direction: direction, newPanel: newPanel, ratio: ratio)
            return .split(split)
        }
    }

    /// Return a new tree with all split ratios set to 0.5 (equalized).
    func equalized() -> PaneTree {
        switch self {
        case .pane: return self
        case .split(var split):
            split.ratio = 0.5
            split.first = split.first.equalized()
            split.second = split.second.equalized()
            return .split(split)
        }
    }

    /// Find the nearest ancestor split that divides along `direction`'s axis and
    /// contains `paneID`. Adjusts its ratio by `delta` (positive = grow first child).
    /// Returns (splitID, newRatio) or nil if not found.
    func adjustSplitRatio(
        containing paneID: UUID,
        direction: ghostty_action_resize_split_direction_e,
        delta: Double
    ) -> (UUID, Double)? {
        adjustSplitRatioHelper(paneID: paneID, direction: direction, delta: delta, path: [])
    }

    private func adjustSplitRatioHelper(
        paneID: UUID,
        direction: ghostty_action_resize_split_direction_e,
        delta: Double,
        path: [(PaneSplit, inFirst: Bool)]
    ) -> (UUID, Double)? {
        switch self {
        case .pane(let leaf):
            guard leaf.id == paneID else { return nil }
            let targetAxis: SplitDirection = (direction == GHOSTTY_RESIZE_SPLIT_LEFT || direction == GHOSTTY_RESIZE_SPLIT_RIGHT)
                ? .horizontal : .vertical
            let grow = (direction == GHOSTTY_RESIZE_SPLIT_RIGHT || direction == GHOSTTY_RESIZE_SPLIT_DOWN)
            for (split, inFirst) in path.reversed() {
                guard split.direction == targetAxis else { continue }
                let currentRatio = split.ratio
                // If in first child: right/down grows our share (ratio increases).
                // If in second child: right/down shrinks first share (ratio decreases for us).
                let adjustment = inFirst ? (grow ? delta : -delta) : (grow ? -delta : delta)
                let newRatio = (currentRatio + adjustment).clamped(to: 0.05...0.95)
                return (split.id, newRatio)
            }
            return nil
        case .split(let split):
            if let result = split.first.adjustSplitRatioHelper(
                paneID: paneID, direction: direction, delta: delta,
                path: path + [(split, true)]
            ) { return result }
            return split.second.adjustSplitRatioHelper(
                paneID: paneID, direction: direction, delta: delta,
                path: path + [(split, false)]
            )
        }
    }

}

// MARK: - PaneLeaf

/// A leaf node in the pane tree — represents a single panel.
struct PaneLeaf: Identifiable, Equatable, Codable {
    let id: UUID
    var panelType: PanelType

    init(id: UUID = UUID(), panelType: PanelType = .terminal) {
        self.id = id
        self.panelType = panelType
    }
}

// MARK: - PaneSplit

/// A split node in the pane tree — divides space between two children.
struct PaneSplit: Identifiable, Equatable, Codable {
    let id: UUID
    var direction: SplitDirection
    var ratio: Double  // 0.0-1.0, proportion of first child
    var first: PaneTree
    var second: PaneTree

    init(
        id: UUID = UUID(),
        direction: SplitDirection,
        ratio: Double = 0.5,
        first: PaneTree,
        second: PaneTree
    ) {
        self.id = id
        self.direction = direction
        self.ratio = ratio
        self.first = first
        self.second = second
    }
}

// MARK: - PanelType

/// Types of panels that can occupy a pane leaf.
enum PanelType: String, Codable {
    case terminal
    case browser
    case markdown
}
