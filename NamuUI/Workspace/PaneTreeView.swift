import SwiftUI

// MARK: - PaneTreeView

/// Recursively renders a PaneTree as nested splits with draggable dividers.
/// Each leaf renders the appropriate panel view; each split renders two children
/// separated by a resizable DividerView.
struct PaneTreeView: View {
    let tree: PaneTree
    let activePaneID: UUID?
    let panelManager: PanelManager
    let availableSize: CGSize
    var isActive: Bool = true
    var zoomedPaneID: UUID? = nil

    var body: some View {
        // When zoomed, find and render only the zoomed leaf directly.
        if let zoomedID = zoomedPaneID,
           let zoomedLeaf = tree.findPane(id: zoomedID) {
            PaneLeafView(
                leaf: zoomedLeaf,
                isKeyPane: zoomedLeaf.id == activePaneID,
                panelManager: panelManager,
                isActive: isActive
            )
        } else {
            switch tree {
            case .pane(let leaf):
                PaneLeafView(
                    leaf: leaf,
                    isKeyPane: leaf.id == activePaneID,
                    panelManager: panelManager,
                    isActive: isActive
                )

            case .split(let split):
                PaneSplitView(
                    split: split,
                    activePaneID: activePaneID,
                    panelManager: panelManager,
                    availableSize: availableSize,
                    isActive: isActive
                )
            }
        }
    }
}

// MARK: - PaneLeafView

/// Renders a single pane leaf — terminal or browser — with an active highlight border.
private struct PaneLeafView: View {
    let leaf: PaneLeaf
    let isKeyPane: Bool
    let panelManager: PanelManager
    var isActive: Bool = true

    var body: some View {
        ZStack {
            panelContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            // Border on the active (key) pane
            if isKeyPane {
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .strokeBorder(Color.accentColor.opacity(0.6), lineWidth: 2)
                    .allowsHitTesting(false)
            }
        }
    }

    @ViewBuilder
    private var panelContent: some View {
        switch leaf.panelType {
        case .terminal:
            if let panel = panelManager.panel(for: leaf.id) {
                TerminalView(
                    panel: panel,
                    onActivate: { panelManager.activatePanel(id: leaf.id) },
                    isActive: isActive,
                    isKeyPane: isKeyPane
                )
            } else {
                Color.black
            }
        case .browser:
            BrowserPanelView(paneID: leaf.id)
        }
    }
}

// MARK: - PaneSplitView

/// Renders a split node: two PaneTreeView children separated by a draggable DividerView.
private struct PaneSplitView: View {
    let split: PaneSplit
    let activePaneID: UUID?
    let panelManager: PanelManager
    let availableSize: CGSize
    var isActive: Bool = true

    var body: some View {
        GeometryReader { geo in
            layout(in: geo.size)
        }
    }

    @ViewBuilder
    private func layout(in size: CGSize) -> some View {
        let isHorizontal = split.direction == .horizontal
        let dividerThickness: CGFloat = 1.0
        let minSize = PaneTreeConstants.minPaneSize

        if isHorizontal {
            let available = size.width - dividerThickness
            let firstWidth = (available * split.ratio)
                .clamped(to: minSize...(available - minSize))
            let secondWidth = available - firstWidth

            HStack(spacing: 0) {
                PaneTreeView(
                    tree: split.first,
                    activePaneID: activePaneID,
                    panelManager: panelManager,
                    availableSize: CGSize(width: firstWidth, height: size.height),
                    isActive: isActive
                )
                .frame(width: firstWidth)

                DividerView(
                    split: split,
                    panelManager: panelManager,
                    availableExtent: size.width
                )
                .frame(width: dividerThickness)
                .frame(maxHeight: .infinity)

                PaneTreeView(
                    tree: split.second,
                    activePaneID: activePaneID,
                    panelManager: panelManager,
                    availableSize: CGSize(width: secondWidth, height: size.height),
                    isActive: isActive
                )
                .frame(width: secondWidth)
            }
        } else {
            let available = size.height - dividerThickness
            let firstHeight = (available * split.ratio)
                .clamped(to: minSize...(available - minSize))
            let secondHeight = available - firstHeight

            VStack(spacing: 0) {
                PaneTreeView(
                    tree: split.first,
                    activePaneID: activePaneID,
                    panelManager: panelManager,
                    availableSize: CGSize(width: size.width, height: firstHeight),
                    isActive: isActive
                )
                .frame(height: firstHeight)

                DividerView(
                    split: split,
                    panelManager: panelManager,
                    availableExtent: size.height
                )
                .frame(height: dividerThickness)
                .frame(maxWidth: .infinity)

                PaneTreeView(
                    tree: split.second,
                    activePaneID: activePaneID,
                    panelManager: panelManager,
                    availableSize: CGSize(width: size.width, height: secondHeight),
                    isActive: isActive
                )
                .frame(height: secondHeight)
            }
        }
    }
}

// MARK: - DividerView

/// A thin draggable line between two panes.
/// Drag updates the split ratio via PanelManager.resizeSplit(splitID:ratio:) using
/// the split node's own ID as the anchor.
/// Double-click equalizes the split to 0.5.
private struct DividerView: View {
    let split: PaneSplit
    let panelManager: PanelManager
    let availableExtent: CGFloat

    @State private var isHovered = false
    /// Ratio captured at the start of each drag gesture.
    @State private var dragStartRatio: Double = 0.5
    /// Whether we've captured the start ratio for the current drag session.
    @State private var isDragging = false

    private var isHorizontal: Bool { split.direction == .horizontal }

    var body: some View {
        ZStack {
            // Wider invisible hit area for easier grabbing
            Color.clear
                .contentShape(Rectangle())
                .frame(
                    width: isHorizontal ? 8 : nil,
                    height: isHorizontal ? nil : 8
                )

            // Visible 1pt line
            Rectangle()
                .fill(isHovered ? Color.white.opacity(0.28) : Color.white.opacity(0.10))
                .animation(.easeInOut(duration: 0.12), value: isHovered)
        }
        .onHover { hovering in
            isHovered = hovering
            if hovering {
                (isHorizontal ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown).push()
            } else {
                NSCursor.pop()
            }
        }
        .highPriorityGesture(
            DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { value in
                    if !isDragging {
                        dragStartRatio = split.ratio
                        isDragging = true
                    }

                    let delta = isHorizontal ? value.translation.width : value.translation.height
                    let newRatio = dragStartRatio + Double(delta / max(availableExtent, 1))
                    let clamped = max(0.1, min(0.9, newRatio))
                    if abs(clamped - split.ratio) > 0.002 {
                        withTransaction(Transaction(animation: nil)) {
                            panelManager.resizeSplit(splitID: split.id, ratio: clamped)
                        }
                    }
                }
                .onEnded { _ in
                    isDragging = false
                }
        )
        .onTapGesture(count: 2) {
            panelManager.resizeSplit(splitID: split.id, ratio: 0.5)
        }
    }
}

// MARK: - Constants

private enum PaneTreeConstants {
    /// Minimum pane size in points along the split axis.
    static let minPaneSize: CGFloat = 100
}
