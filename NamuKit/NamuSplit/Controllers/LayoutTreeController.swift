import Foundation
import SwiftUI

/// Central controller managing the entire split view state.
/// Central controller managing split-pane layout, tabs, focus, and zoom.
@MainActor
@Observable
final class LayoutTreeController {

    // MARK: - State

    /// The root node of the split tree
    var rootNode: SplitNode

    /// Currently focused pane ID
    var focusedPaneId: PaneID?

    /// Currently zoomed pane. When set, rendering should only show this pane.
    var zoomedPaneId: PaneID?

    /// Configuration for behavior and appearance
    var configuration: NamuSplitConfiguration

    /// Delegate for receiving callbacks about tab/pane events
    weak var delegate: NamuSplitDelegate?

    /// When false, drop delegates reject all drags.
    @ObservationIgnored var isInteractive: Bool = true

    /// Current frame of the entire split view container
    var containerFrame: CGRect = .zero

    /// Flag to prevent notification loops during external updates
    var isExternalUpdateInProgress: Bool = false

    /// Timestamp of last geometry notification for debouncing
    var lastGeometryNotificationTime: TimeInterval = 0

    // MARK: - Drag State

    /// Tab currently being dragged (for visual feedback)
    var draggingTab: TabItem?
    var dragGeneration: Int = 0
    var dragSourcePaneId: PaneID?

    @ObservationIgnored var activeDragTab: TabItem?
    @ObservationIgnored var activeDragSourcePaneId: PaneID?

    var dragHiddenSourceTabId: UUID?
    var dragHiddenSourcePaneId: PaneID?

    // MARK: - Callbacks

    @ObservationIgnored var onFileDrop: ((_ urls: [URL], _ paneId: PaneID) -> Bool)?
    @ObservationIgnored var onExternalTabDrop: ((ExternalTabDropRequest) -> Bool)?
    @ObservationIgnored var onCreateAdditionalDragPayload: ((_ tabId: TabID) -> [(typeIdentifier: String, data: Data)])?
    @ObservationIgnored var onTabCloseRequest: ((_ tabId: TabID, _ paneId: PaneID) -> Void)?

    /// Keyboard shortcuts to display in tab context menus
    var contextMenuShortcuts: [TabContextAction: KeyboardShortcut] = [:]

    // MARK: - Initialization

    init(configuration: NamuSplitConfiguration = .default) {
        self.configuration = configuration
        let initialPane = PaneState(tabs: [])
        self.rootNode = .pane(initialPane)
        self.focusedPaneId = initialPane.id
    }

    init(configuration: NamuSplitConfiguration = .default, rootNode: SplitNode) {
        self.configuration = configuration
        self.rootNode = rootNode
        self.focusedPaneId = rootNode.allPaneIds.first
    }

    // MARK: - Tab Operations

    @discardableResult
    func createTab(
        title: String,
        hasCustomTitle: Bool = false,
        icon: String? = "doc.text",
        iconImageData: Data? = nil,
        kind: String? = nil,
        isDirty: Bool = false,
        showsNotificationBadge: Bool = false,
        isLoading: Bool = false,
        isPinned: Bool = false,
        inPane pane: PaneID? = nil
    ) -> TabID? {
        let tabId = TabID()
        let tab = Tab(
            id: tabId, title: title, hasCustomTitle: hasCustomTitle,
            icon: icon, iconImageData: iconImageData, kind: kind,
            isDirty: isDirty, showsNotificationBadge: showsNotificationBadge,
            isLoading: isLoading, isPinned: isPinned
        )
        let targetPane = pane ?? focusedPaneId ?? rootNode.allPaneIds.first!

        if delegate?.splitController(self, shouldCreateTab: tab, inPane: targetPane) == false {
            return nil
        }

        // Calculate insertion index
        let insertIndex: Int?
        switch configuration.newTabPosition {
        case .current:
            if let paneState = rootNode.findPane(targetPane),
               let selectedTabId = paneState.selectedTabId,
               let currentIndex = paneState.tabs.firstIndex(where: { $0.id == selectedTabId }) {
                insertIndex = currentIndex + 1
            } else {
                insertIndex = nil
            }
        case .end:
            insertIndex = nil
        }

        let tabItem = TabItem(
            id: tabId.id, title: title, hasCustomTitle: hasCustomTitle,
            icon: icon, iconImageData: iconImageData, kind: kind,
            isDirty: isDirty, showsNotificationBadge: showsNotificationBadge,
            isLoading: isLoading, isPinned: isPinned
        )

        if let paneState = rootNode.findPane(targetPane) {
            if let insertIndex {
                paneState.insertTab(tabItem, at: insertIndex)
            } else {
                paneState.addTab(tabItem)
            }
        }

        delegate?.splitController(self, didCreateTab: tab, inPane: targetPane)
        return tabId
    }

    /// Request the delegate to create a new tab of the given kind in a pane.
    func requestNewTab(kind: String, inPane pane: PaneID) {
        delegate?.splitController(self, didRequestNewTab: kind, inPane: pane)
    }

    /// Request the delegate to handle a tab context-menu action.
    func requestTabContextAction(_ action: TabContextAction, for tabId: TabID, inPane pane: PaneID) {
        guard let t = tab(tabId) else { return }
        delegate?.splitController(self, didRequestTabContextAction: action, for: t, inPane: pane)
    }

    /// Update an existing tab's metadata
    func updateTab(
        _ tabId: TabID,
        title: String? = nil,
        icon: String?? = nil,
        iconImageData: Data?? = nil,
        kind: String?? = nil,
        hasCustomTitle: Bool? = nil,
        isDirty: Bool? = nil,
        showsNotificationBadge: Bool? = nil,
        isLoading: Bool? = nil,
        isPinned: Bool? = nil
    ) {
        guard let (pane, tabIndex) = findTabInternal(tabId) else { return }

        if let title { pane.tabs[tabIndex].title = title }
        if let icon { pane.tabs[tabIndex].icon = icon }
        if let iconImageData { pane.tabs[tabIndex].iconImageData = iconImageData }
        if let kind { pane.tabs[tabIndex].kind = kind }
        if let hasCustomTitle { pane.tabs[tabIndex].hasCustomTitle = hasCustomTitle }
        if let isDirty { pane.tabs[tabIndex].isDirty = isDirty }
        if let showsNotificationBadge { pane.tabs[tabIndex].showsNotificationBadge = showsNotificationBadge }
        if let isLoading { pane.tabs[tabIndex].isLoading = isLoading }
        if let isPinned { pane.tabs[tabIndex].isPinned = isPinned }
    }

    /// Close a tab by ID
    @discardableResult
    func closeTab(_ tabId: TabID) -> Bool {
        guard let (pane, tabIndex) = findTabInternal(tabId) else { return false }
        return closeTab(tabId, with: tabIndex, in: pane)
    }

    /// Close a tab by ID in a specific pane.
    @discardableResult
    func closeTab(_ tabId: TabID, inPane paneId: PaneID) -> Bool {
        guard let pane = rootNode.findPane(paneId),
              let tabIndex = pane.tabs.firstIndex(where: { $0.id == tabId.id }) else {
            return false
        }
        return closeTab(tabId, with: tabIndex, in: pane)
    }

    private func closeTab(_ tabId: TabID, with tabIndex: Int, in pane: PaneState) -> Bool {
        let tabItem = pane.tabs[tabIndex]
        let tab = Tab(from: tabItem)
        let paneId = pane.id

        if delegate?.splitController(self, shouldCloseTab: tab, inPane: paneId) == false {
            return false
        }

        pane.removeTab(tabId.id)

        // If pane is now empty and not the only pane, close it
        if pane.tabs.isEmpty && rootNode.allPaneIds.count > 1 {
            closePaneInternal(paneId)
        }

        delegate?.splitController(self, didCloseTab: tabId, fromPane: paneId)
        notifyGeometryChange()
        return true
    }

    /// Select a tab by ID
    func selectTab(_ tabId: TabID) {
        guard let (pane, tabIndex) = findTabInternal(tabId) else { return }
        pane.selectTab(tabId.id)
        focusPane(pane.id)
        let tab = Tab(from: pane.tabs[tabIndex])
        delegate?.splitController(self, didSelectTab: tab, inPane: pane.id)
    }

    /// Move a tab to a specific pane
    @discardableResult
    func moveTab(_ tabId: TabID, toPane targetPaneId: PaneID, atIndex index: Int? = nil) -> Bool {
        guard let (sourcePane, sourceIndex) = findTabInternal(tabId) else { return false }
        guard let targetPane = rootNode.findPane(targetPaneId) else { return false }

        let tabItem = sourcePane.tabs[sourceIndex]
        let movedTab = Tab(from: tabItem)
        let sourcePaneId = sourcePane.id

        if sourcePaneId == targetPane.id {
            let destinationIndex: Int = {
                if let index { return max(0, min(index, sourcePane.tabs.count)) }
                return sourcePane.tabs.count
            }()
            sourcePane.moveTab(from: sourceIndex, to: destinationIndex)
            sourcePane.selectTab(tabItem.id)
            focusPaneInternal(sourcePane.id)
            delegate?.splitController(self, didSelectTab: movedTab, inPane: sourcePane.id)
            notifyGeometryChange()
            return true
        }

        // Remove from source
        sourcePane.removeTab(tabItem.id)

        // Add to target
        if let index {
            targetPane.insertTab(tabItem, at: index)
        } else {
            targetPane.addTab(tabItem)
        }

        focusPaneInternal(targetPane.id)

        // Close empty source pane
        if sourcePane.tabs.isEmpty && rootNode.allPaneIds.count > 1 {
            closePaneInternal(sourcePaneId)
        }

        delegate?.splitController(self, didMoveTab: movedTab, fromPane: sourcePaneId, toPane: targetPane.id)
        notifyGeometryChange()
        return true
    }

    /// Reorder a tab within its pane.
    @discardableResult
    func reorderTab(_ tabId: TabID, toIndex: Int) -> Bool {
        guard let (pane, sourceIndex) = findTabInternal(tabId) else { return false }
        let destinationIndex = max(0, min(toIndex, pane.tabs.count))
        pane.moveTab(from: sourceIndex, to: destinationIndex)
        pane.selectTab(tabId.id)
        focusPaneInternal(pane.id)
        if let tabIndex = pane.tabs.firstIndex(where: { $0.id == tabId.id }) {
            let tab = Tab(from: pane.tabs[tabIndex])
            delegate?.splitController(self, didSelectTab: tab, inPane: pane.id)
        }
        notifyGeometryChange()
        return true
    }

    /// Move to previous tab in focused pane
    func selectPreviousTab() {
        guard let pane = focusedPane,
              let selectedTabId = pane.selectedTabId,
              let currentIndex = pane.tabs.firstIndex(where: { $0.id == selectedTabId }),
              !pane.tabs.isEmpty else { return }
        let newIndex = currentIndex > 0 ? currentIndex - 1 : pane.tabs.count - 1
        pane.selectTab(pane.tabs[newIndex].id)
        notifyTabSelection()
    }

    /// Move to next tab in focused pane
    func selectNextTab() {
        guard let pane = focusedPane,
              let selectedTabId = pane.selectedTabId,
              let currentIndex = pane.tabs.firstIndex(where: { $0.id == selectedTabId }),
              !pane.tabs.isEmpty else { return }
        let newIndex = currentIndex < pane.tabs.count - 1 ? currentIndex + 1 : 0
        pane.selectTab(pane.tabs[newIndex].id)
        notifyTabSelection()
    }

    // MARK: - Split Operations

    /// Split the focused pane (or specified pane)
    @discardableResult
    func splitPane(
        _ paneId: PaneID? = nil,
        orientation: SplitOrientation,
        withTab tab: Tab? = nil
    ) -> PaneID? {
        guard configuration.allowSplits else { return nil }
        let targetPaneId = paneId ?? focusedPaneId
        guard let targetPaneId else { return nil }

        if delegate?.splitController(self, shouldSplitPane: targetPaneId, orientation: orientation) == false {
            return nil
        }

        let internalTab: TabItem?
        if let tab {
            internalTab = TabItem(
                id: tab.id.id, title: tab.title, hasCustomTitle: tab.hasCustomTitle,
                icon: tab.icon, iconImageData: tab.iconImageData, kind: tab.kind,
                isDirty: tab.isDirty, showsNotificationBadge: tab.showsNotificationBadge,
                isLoading: tab.isLoading, isPinned: tab.isPinned
            )
        } else {
            internalTab = nil
        }

        clearPaneZoom()
        rootNode = splitNodeRecursively(
            node: rootNode, targetPaneId: targetPaneId,
            orientation: orientation, newTab: internalTab
        )

        let newPaneId = focusedPaneId!
        delegate?.splitController(self, didSplitPane: targetPaneId, newPane: newPaneId, orientation: orientation)
        notifyGeometryChange()
        return newPaneId
    }

    /// Split a pane with a tab, choosing which side to insert on.
    @discardableResult
    func splitPane(
        _ paneId: PaneID? = nil,
        orientation: SplitOrientation,
        withTab tab: Tab,
        insertFirst: Bool
    ) -> PaneID? {
        guard configuration.allowSplits else { return nil }
        let targetPaneId = paneId ?? focusedPaneId
        guard let targetPaneId else { return nil }

        if delegate?.splitController(self, shouldSplitPane: targetPaneId, orientation: orientation) == false {
            return nil
        }

        let internalTab = TabItem(
            id: tab.id.id, title: tab.title, hasCustomTitle: tab.hasCustomTitle,
            icon: tab.icon, iconImageData: tab.iconImageData, kind: tab.kind,
            isDirty: tab.isDirty, showsNotificationBadge: tab.showsNotificationBadge,
            isLoading: tab.isLoading, isPinned: tab.isPinned
        )

        clearPaneZoom()
        rootNode = splitNodeWithTabRecursively(
            node: rootNode, targetPaneId: targetPaneId,
            orientation: orientation, tab: internalTab, insertFirst: insertFirst
        )

        let newPaneId = focusedPaneId!
        delegate?.splitController(self, didSplitPane: targetPaneId, newPane: newPaneId, orientation: orientation)
        notifyGeometryChange()
        return newPaneId
    }

    /// Split a pane by moving an existing tab into the new pane.
    @discardableResult
    func splitPane(
        _ paneId: PaneID? = nil,
        orientation: SplitOrientation,
        movingTab tabId: TabID,
        insertFirst: Bool
    ) -> PaneID? {
        guard configuration.allowSplits else { return nil }
        guard let (sourcePane, tabIndex) = findTabInternal(tabId) else { return nil }
        let tabItem = sourcePane.tabs[tabIndex]
        let targetPaneId = paneId ?? sourcePane.id

        if delegate?.splitController(self, shouldSplitPane: targetPaneId, orientation: orientation) == false {
            return nil
        }

        // Remove from source first
        sourcePane.removeTab(tabItem.id)

        if sourcePane.tabs.isEmpty {
            if sourcePane.id == targetPaneId {
                sourcePane.addTab(TabItem(title: "Empty", icon: nil), select: true)
            } else if rootNode.allPaneIds.count > 1 {
                closePaneInternal(sourcePane.id)
            }
        }

        clearPaneZoom()
        rootNode = splitNodeWithTabRecursively(
            node: rootNode, targetPaneId: targetPaneId,
            orientation: orientation, tab: tabItem, insertFirst: insertFirst
        )

        let newPaneId = focusedPaneId!
        delegate?.splitController(self, didSplitPane: targetPaneId, newPane: newPaneId, orientation: orientation)
        notifyGeometryChange()
        return newPaneId
    }

    /// Close a specific pane
    @discardableResult
    func closePane(_ paneId: PaneID) -> Bool {
        if !configuration.allowCloseLastPane && rootNode.allPaneIds.count <= 1 {
            return false
        }

        if delegate?.splitController(self, shouldClosePane: paneId) == false {
            return false
        }

        closePaneInternal(paneId)
        delegate?.splitController(self, didClosePane: paneId)
        notifyGeometryChange()
        return true
    }

    // MARK: - Focus Management

    func focusPane(_ paneId: PaneID) {
        focusPaneInternal(paneId)
        delegate?.splitController(self, didFocusPane: paneId)
    }

    func navigateFocus(direction: NavigationDirection) {
        guard let currentPaneId = focusedPaneId else { return }
        let allPaneBounds = rootNode.computePaneBounds()
        guard let currentBounds = allPaneBounds.first(where: { $0.paneId == currentPaneId })?.bounds else { return }

        if let targetPaneId = findBestNeighbor(from: currentBounds, currentPaneId: currentPaneId,
                                                direction: direction, allPaneBounds: allPaneBounds) {
            focusPane(targetPaneId)
        }
    }

    func adjacentPane(to paneId: PaneID, direction: NavigationDirection) -> PaneID? {
        let allPaneBounds = rootNode.computePaneBounds()
        guard let currentBounds = allPaneBounds.first(where: { $0.paneId == paneId })?.bounds else {
            return nil
        }
        return findBestNeighbor(from: currentBounds, currentPaneId: paneId,
                                direction: direction, allPaneBounds: allPaneBounds)
    }

    // MARK: - Split Zoom

    var isSplitZoomed: Bool {
        zoomedPaneId != nil
    }

    @discardableResult
    func clearPaneZoom() -> Bool {
        guard zoomedPaneId != nil else { return false }
        zoomedPaneId = nil
        return true
    }

    @discardableResult
    func togglePaneZoom(inPane paneId: PaneID? = nil) -> Bool {
        let targetPaneId = paneId ?? focusedPaneId
        guard let targetPaneId else { return false }
        guard rootNode.findPane(targetPaneId) != nil else { return false }

        if zoomedPaneId == targetPaneId {
            zoomedPaneId = nil
            return true
        }

        guard rootNode.allPaneIds.count > 1 else { return false }
        zoomedPaneId = targetPaneId
        focusedPaneId = targetPaneId
        return true
    }

    // MARK: - Query Methods

    var allTabIds: [TabID] {
        rootNode.allPanes.flatMap { pane in
            pane.tabs.map { TabID(id: $0.id) }
        }
    }

    var allPaneIds: [PaneID] {
        rootNode.allPaneIds
    }

    var focusedPane: PaneState? {
        guard let focusedPaneId else { return nil }
        return rootNode.findPane(focusedPaneId)
    }

    var zoomedNode: SplitNode? {
        guard let zoomedPaneId else { return nil }
        return rootNode.findNode(containing: zoomedPaneId)
    }

    func tab(_ tabId: TabID) -> Tab? {
        guard let (pane, tabIndex) = findTabInternal(tabId) else { return nil }
        return Tab(from: pane.tabs[tabIndex])
    }

    func tabs(inPane paneId: PaneID) -> [Tab] {
        guard let pane = rootNode.findPane(paneId) else { return [] }
        return pane.tabs.map { Tab(from: $0) }
    }

    func selectedTab(inPane paneId: PaneID) -> Tab? {
        guard let pane = rootNode.findPane(paneId),
              let selected = pane.selectedTab else { return nil }
        return Tab(from: selected)
    }

    // MARK: - Geometry

    func layoutSnapshot() -> LayoutSnapshot {
        let paneBounds = rootNode.computePaneBounds()

        let paneGeometries = paneBounds.map { bounds -> PaneGeometry in
            let pane = rootNode.findPane(bounds.paneId)
            let pixelFrame = PixelRect(
                x: Double(bounds.bounds.minX * containerFrame.width + containerFrame.origin.x),
                y: Double(bounds.bounds.minY * containerFrame.height + containerFrame.origin.y),
                width: Double(bounds.bounds.width * containerFrame.width),
                height: Double(bounds.bounds.height * containerFrame.height)
            )
            return PaneGeometry(
                paneId: bounds.paneId.id.uuidString,
                frame: pixelFrame,
                selectedTabId: pane?.selectedTabId?.uuidString,
                tabIds: pane?.tabs.map { $0.id.uuidString } ?? []
            )
        }

        return LayoutSnapshot(
            containerFrame: PixelRect(from: containerFrame),
            panes: paneGeometries,
            focusedPaneId: focusedPaneId?.id.uuidString,
            timestamp: Date().timeIntervalSince1970
        )
    }

    func treeSnapshot() -> ExternalTreeNode {
        buildExternalTree(from: rootNode, containerFrame: containerFrame)
    }

    func findSplit(_ splitId: UUID) -> Bool {
        findSplitState(splitId) != nil
    }

    @discardableResult
    func setDividerPosition(_ position: CGFloat, forSplit splitId: UUID, fromExternal: Bool = false) -> Bool {
        guard let split = findSplitState(splitId) else { return false }

        if fromExternal {
            isExternalUpdateInProgress = true
        }

        let clampedPosition = min(max(position, 0.1), 0.9)
        split.dividerPosition = clampedPosition

        if fromExternal {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                self?.isExternalUpdateInProgress = false
            }
        }

        return true
    }

    func setContainerFrame(_ frame: CGRect) {
        containerFrame = frame
    }

    // MARK: - Private Helpers

    private func findTabInternal(_ tabId: TabID) -> (PaneState, Int)? {
        for pane in rootNode.allPanes {
            if let index = pane.tabs.firstIndex(where: { $0.id == tabId.id }) {
                return (pane, index)
            }
        }
        return nil
    }

    private func focusPaneInternal(_ paneId: PaneID) {
        guard rootNode.findPane(paneId) != nil else { return }
        focusedPaneId = paneId
    }

    private func closePaneInternal(_ paneId: PaneID) {
        guard rootNode.allPaneIds.count > 1 else { return }

        let (newRoot, siblingPaneId) = closePaneRecursively(node: rootNode, targetPaneId: paneId)

        if let newRoot {
            rootNode = newRoot
        }

        if let siblingPaneId {
            focusedPaneId = siblingPaneId
        } else if let firstPane = rootNode.allPaneIds.first {
            focusedPaneId = firstPane
        }

        if let zoomedPaneId, rootNode.findPane(zoomedPaneId) == nil {
            self.zoomedPaneId = nil
        }
    }

    private func notifyTabSelection() {
        guard let pane = focusedPane,
              let tabItem = pane.selectedTab else { return }
        let tab = Tab(from: tabItem)
        delegate?.splitController(self, didSelectTab: tab, inPane: pane.id)
    }

    func notifyGeometryChange(isDragging: Bool = false) {
        guard !isExternalUpdateInProgress else { return }

        if isDragging {
            let shouldNotify = delegate?.splitController(self, shouldNotifyDuringDrag: true) ?? false
            guard shouldNotify else { return }
        }

        if isDragging {
            let now = Date().timeIntervalSince1970
            let debounceInterval: TimeInterval = 0.05
            guard now - lastGeometryNotificationTime >= debounceInterval else { return }
            lastGeometryNotificationTime = now
        }

        let snapshot = layoutSnapshot()
        delegate?.splitController(self, didChangeGeometry: snapshot)
    }

    // MARK: - Tree Manipulation (Private)

    private func splitNodeRecursively(
        node: SplitNode, targetPaneId: PaneID,
        orientation: SplitOrientation, newTab: TabItem?
    ) -> SplitNode {
        switch node {
        case .pane(let paneState):
            if paneState.id == targetPaneId {
                let newPane: PaneState
                if let tab = newTab {
                    newPane = PaneState(tabs: [tab])
                } else {
                    newPane = PaneState(tabs: [])
                }

                let splitState = SplitState(
                    orientation: orientation,
                    first: .pane(paneState),
                    second: .pane(newPane),
                    dividerPosition: 0.5,
                    animationOrigin: .fromSecond
                )

                focusedPaneId = newPane.id
                return .split(splitState)
            }
            return node

        case .split(let splitState):
            splitState.first = splitNodeRecursively(
                node: splitState.first, targetPaneId: targetPaneId,
                orientation: orientation, newTab: newTab
            )
            splitState.second = splitNodeRecursively(
                node: splitState.second, targetPaneId: targetPaneId,
                orientation: orientation, newTab: newTab
            )
            return .split(splitState)
        }
    }

    private func splitNodeWithTabRecursively(
        node: SplitNode, targetPaneId: PaneID,
        orientation: SplitOrientation, tab: TabItem, insertFirst: Bool
    ) -> SplitNode {
        switch node {
        case .pane(let paneState):
            if paneState.id == targetPaneId {
                let newPane = PaneState(tabs: [tab])

                let splitState: SplitState
                if insertFirst {
                    splitState = SplitState(
                        orientation: orientation,
                        first: .pane(newPane),
                        second: .pane(paneState),
                        dividerPosition: 0.5,
                        animationOrigin: .fromFirst
                    )
                } else {
                    splitState = SplitState(
                        orientation: orientation,
                        first: .pane(paneState),
                        second: .pane(newPane),
                        dividerPosition: 0.5,
                        animationOrigin: .fromSecond
                    )
                }

                focusedPaneId = newPane.id
                return .split(splitState)
            }
            return node

        case .split(let splitState):
            splitState.first = splitNodeWithTabRecursively(
                node: splitState.first, targetPaneId: targetPaneId,
                orientation: orientation, tab: tab, insertFirst: insertFirst
            )
            splitState.second = splitNodeWithTabRecursively(
                node: splitState.second, targetPaneId: targetPaneId,
                orientation: orientation, tab: tab, insertFirst: insertFirst
            )
            return .split(splitState)
        }
    }

    private func closePaneRecursively(
        node: SplitNode, targetPaneId: PaneID
    ) -> (SplitNode?, PaneID?) {
        switch node {
        case .pane(let paneState):
            if paneState.id == targetPaneId {
                return (nil, nil)
            }
            return (node, nil)

        case .split(let splitState):
            if case .pane(let firstPane) = splitState.first, firstPane.id == targetPaneId {
                let focusTarget = splitState.second.allPaneIds.first
                return (splitState.second, focusTarget)
            }

            if case .pane(let secondPane) = splitState.second, secondPane.id == targetPaneId {
                let focusTarget = splitState.first.allPaneIds.first
                return (splitState.first, focusTarget)
            }

            let (newFirst, focusFromFirst) = closePaneRecursively(node: splitState.first, targetPaneId: targetPaneId)
            if newFirst == nil {
                return (splitState.second, splitState.second.allPaneIds.first)
            }

            let (newSecond, focusFromSecond) = closePaneRecursively(node: splitState.second, targetPaneId: targetPaneId)
            if newSecond == nil {
                return (splitState.first, splitState.first.allPaneIds.first)
            }

            if let newFirst { splitState.first = newFirst }
            if let newSecond { splitState.second = newSecond }

            return (.split(splitState), focusFromFirst ?? focusFromSecond)
        }
    }

    // MARK: - Focus Navigation (Private)

    private func findBestNeighbor(from currentBounds: CGRect, currentPaneId: PaneID,
                                   direction: NavigationDirection, allPaneBounds: [PaneBounds]) -> PaneID? {
        let epsilon: CGFloat = 0.001

        let candidates = allPaneBounds.filter { paneBounds in
            guard paneBounds.paneId != currentPaneId else { return false }
            let b = paneBounds.bounds
            switch direction {
            case .left:  return b.maxX <= currentBounds.minX + epsilon
            case .right: return b.minX >= currentBounds.maxX - epsilon
            case .up:    return b.maxY <= currentBounds.minY + epsilon
            case .down:  return b.minY >= currentBounds.maxY - epsilon
            }
        }

        guard !candidates.isEmpty else { return nil }

        let scored: [(PaneID, CGFloat, CGFloat)] = candidates.map { c in
            let overlap: CGFloat
            let distance: CGFloat

            switch direction {
            case .left, .right:
                overlap = max(0, min(currentBounds.maxY, c.bounds.maxY) - max(currentBounds.minY, c.bounds.minY))
                distance = direction == .left ? (currentBounds.minX - c.bounds.maxX) : (c.bounds.minX - currentBounds.maxX)
            case .up, .down:
                overlap = max(0, min(currentBounds.maxX, c.bounds.maxX) - max(currentBounds.minX, c.bounds.minX))
                distance = direction == .up ? (currentBounds.minY - c.bounds.maxY) : (c.bounds.minY - currentBounds.maxY)
            }

            return (c.paneId, overlap, distance)
        }

        let sorted = scored.sorted { a, b in
            if abs(a.1 - b.1) > epsilon { return a.1 > b.1 }
            return a.2 < b.2
        }

        return sorted.first?.0
    }

    // MARK: - Tree Snapshot (Private)

    private func buildExternalTree(from node: SplitNode, containerFrame: CGRect,
                                    bounds: CGRect = CGRect(x: 0, y: 0, width: 1, height: 1)) -> ExternalTreeNode {
        switch node {
        case .pane(let paneState):
            let pixelFrame = PixelRect(
                x: Double(bounds.minX * containerFrame.width + containerFrame.origin.x),
                y: Double(bounds.minY * containerFrame.height + containerFrame.origin.y),
                width: Double(bounds.width * containerFrame.width),
                height: Double(bounds.height * containerFrame.height)
            )
            let tabs = paneState.tabs.map { ExternalTab(id: $0.id.uuidString, title: $0.title) }
            let paneNode = ExternalPaneNode(
                id: paneState.id.id.uuidString,
                frame: pixelFrame,
                tabs: tabs,
                selectedTabId: paneState.selectedTabId?.uuidString
            )
            return .pane(paneNode)

        case .split(let splitState):
            let dividerPos = splitState.dividerPosition
            let firstBounds: CGRect
            let secondBounds: CGRect

            switch splitState.orientation {
            case .horizontal:
                firstBounds = CGRect(x: bounds.minX, y: bounds.minY,
                                     width: bounds.width * dividerPos, height: bounds.height)
                secondBounds = CGRect(x: bounds.minX + bounds.width * dividerPos, y: bounds.minY,
                                      width: bounds.width * (1 - dividerPos), height: bounds.height)
            case .vertical:
                firstBounds = CGRect(x: bounds.minX, y: bounds.minY,
                                     width: bounds.width, height: bounds.height * dividerPos)
                secondBounds = CGRect(x: bounds.minX, y: bounds.minY + bounds.height * dividerPos,
                                      width: bounds.width, height: bounds.height * (1 - dividerPos))
            }

            let splitNode = ExternalSplitNode(
                id: splitState.id.uuidString,
                orientation: splitState.orientation == .horizontal ? "horizontal" : "vertical",
                dividerPosition: Double(splitState.dividerPosition),
                first: buildExternalTree(from: splitState.first, containerFrame: containerFrame, bounds: firstBounds),
                second: buildExternalTree(from: splitState.second, containerFrame: containerFrame, bounds: secondBounds)
            )
            return .split(splitNode)
        }
    }

    // MARK: - Split State Access

    func findSplitState(_ splitId: UUID) -> SplitState? {
        findSplitRecursively(in: rootNode, id: splitId)
    }

    private func findSplitRecursively(in node: SplitNode, id: UUID) -> SplitState? {
        switch node {
        case .pane:
            return nil
        case .split(let splitState):
            if splitState.id == id { return splitState }
            if let found = findSplitRecursively(in: splitState.first, id: id) { return found }
            return findSplitRecursively(in: splitState.second, id: id)
        }
    }
}

// MARK: - External Tab Drop Request

extension LayoutTreeController {
    struct ExternalTabDropRequest {
        enum Destination {
            case insert(targetPane: PaneID, targetIndex: Int?)
            case split(targetPane: PaneID, orientation: SplitOrientation, insertFirst: Bool)
        }

        let tabId: TabID
        let sourcePaneId: PaneID
        let destination: Destination

        init(tabId: TabID, sourcePaneId: PaneID, destination: Destination) {
            self.tabId = tabId
            self.sourcePaneId = sourcePaneId
            self.destination = destination
        }
    }
}
