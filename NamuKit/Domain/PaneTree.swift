import Foundation

/// Direction of a split in the pane tree.
enum SplitDirection: String, Codable {
    case horizontal
    case vertical
}

/// Cardinal navigation direction for spatial focus movement.
enum NavigationDirection {
    case left, right, up, down

    var axis: SplitDirection {
        switch self {
        case .left, .right: return .horizontal
        case .up, .down: return .vertical
        }
    }

    var isForward: Bool {
        switch self {
        case .right, .down: return true
        case .left, .up: return false
        }
    }
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

    /// Find the split node whose `first` or `second` child contains `panelID` directly.
    func findParentSplit(of panelID: UUID) -> PaneSplit? {
        guard case .split(let split) = self else { return nil }

        // Check if either direct child is the target leaf.
        if case .pane(let leaf) = split.first, leaf.id == panelID { return split }
        if case .pane(let leaf) = split.second, leaf.id == panelID { return split }

        // Recurse.
        return split.first.findParentSplit(of: panelID)
            ?? split.second.findParentSplit(of: panelID)
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

    /// Remove the pane with `id` from the tree.
    /// When a split loses one child the remaining child replaces the whole split node.
    /// Returns `nil` if the tree becomes empty (i.e., the root pane was removed).
    func removePane(id: UUID) -> PaneTree? {
        switch self {
        case .pane(let leaf):
            return leaf.id == id ? nil : self

        case .split(var split):
            let newFirst = split.first.removePane(id: id)
            let newSecond = split.second.removePane(id: id)

            switch (newFirst, newSecond) {
            case (nil, nil):
                return nil
            case (let tree?, nil):
                return tree
            case (nil, let tree?):
                return tree
            case (let first?, let second?):
                split.first = first
                split.second = second
                return .split(split)
            }
        }
    }

    /// Swap the positions of two panes identified by `idA` and `idB`.
    /// Returns the modified tree. No-ops if either ID is not found or they are the same.
    func swapPanes(id idA: UUID, with idB: UUID) -> PaneTree {
        guard idA != idB else { return self }
        guard let leafA = findPane(id: idA), let leafB = findPane(id: idB) else { return self }
        return replacingLeaf(id: idA, with: leafB).replacingLeaf(id: idB, with: leafA)
    }

    /// Remove the pane with `id` from the tree, returning both the extracted leaf
    /// and the remaining tree (nil if the tree becomes empty).
    /// Used by pane break-out: the extracted leaf is placed in a new workspace.
    func breakPane(id: UUID) -> (leaf: PaneLeaf, remaining: PaneTree?)? {
        guard let leaf = findPane(id: id) else { return nil }
        let remaining = removePane(id: id)
        return (leaf, remaining)
    }

    /// Return a new tree with the leaf matching `id` replaced by `replacement`.
    private func replacingLeaf(id: UUID, with replacement: PaneLeaf) -> PaneTree {
        switch self {
        case .pane(let leaf):
            return leaf.id == id ? .pane(replacement) : self
        case .split(var split):
            split.first = split.first.replacingLeaf(id: id, with: replacement)
            split.second = split.second.replacingLeaf(id: id, with: replacement)
            return .split(split)
        }
    }

    /// Adjust the split ratio for the split node identified by `splitID`.
    /// `ratio` is the proportion allocated to the first child (0.0–1.0).
    /// Returns a new tree; no-ops if `splitID` is not found.
    func resizeSplit(splitID: UUID, ratio: Double) -> PaneTree {
        guard case .split(var split) = self else { return self }

        if split.id == splitID {
            split.ratio = ratio.clamped(to: 0.05...0.95)
            return .split(split)
        }

        split.first = split.first.resizeSplit(splitID: splitID, ratio: ratio)
        split.second = split.second.resizeSplit(splitID: splitID, ratio: ratio)
        return .split(split)
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

    // MARK: - Focus navigation

    /// Return the panel ID after `currentID` in document order, wrapping around.
    func focusNext(after currentID: UUID) -> UUID? {
        let panels = allPanels
        guard !panels.isEmpty else { return nil }
        if let idx = panels.firstIndex(where: { $0.id == currentID }) {
            return panels[(idx + 1) % panels.count].id
        }
        return panels.first?.id
    }

    /// Return the panel ID before `currentID` in document order, wrapping around.
    func focusPrevious(before currentID: UUID) -> UUID? {
        let panels = allPanels
        guard !panels.isEmpty else { return nil }
        if let idx = panels.firstIndex(where: { $0.id == currentID }) {
            return panels[(idx + panels.count - 1) % panels.count].id
        }
        return panels.last?.id
    }

    /// Return the ID of the nearest panel in `direction` relative to `currentID`.
    /// Walks up the tree to find the nearest ancestor split matching the navigation
    /// axis, then moves to the sibling subtree's nearest leaf.
    func focusInDirection(_ direction: NavigationDirection, from currentID: UUID) -> UUID? {
        focusInDirectionHelper(direction: direction, targetID: currentID, path: [])
    }

    /// Recursive helper that builds the ancestor path and performs the navigation.
    private func focusInDirectionHelper(direction: NavigationDirection, targetID: UUID, path: [(split: PaneSplit, inFirst: Bool)]) -> UUID? {
        switch self {
        case .pane(let leaf):
            guard leaf.id == targetID else { return nil }
            // Found the target leaf. Walk up the path looking for a matching split.
            for (split, inFirst) in path.reversed() {
                guard split.direction == direction.axis else { continue }
                // Can navigate: forward from first child, or backward from second child.
                if direction.isForward && inFirst {
                    return split.second.firstLeaf?.id
                } else if !direction.isForward && !inFirst {
                    return split.first.lastLeaf?.id
                }
            }
            return nil

        case .split(let split):
            // Try first subtree.
            if let result = split.first.focusInDirectionHelper(
                direction: direction, targetID: targetID,
                path: path + [(split, true)]
            ) { return result }
            // Try second subtree.
            return split.second.focusInDirectionHelper(
                direction: direction, targetID: targetID,
                path: path + [(split, false)]
            )
        }
    }

    /// Returns the first (leftmost/topmost) leaf in this subtree.
    private var firstLeaf: PaneLeaf? {
        switch self {
        case .pane(let leaf): return leaf
        case .split(let split): return split.first.firstLeaf
        }
    }

    /// Returns the last (rightmost/bottommost) leaf in this subtree.
    private var lastLeaf: PaneLeaf? {
        switch self {
        case .pane(let leaf): return leaf
        case .split(let split): return split.second.lastLeaf
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
}
