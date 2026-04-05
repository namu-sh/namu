import SwiftUI
import UniformTypeIdentifiers
import AppKit

/// Container for a single pane with its tab bar and content area
struct NamuPaneContainerView<Content: View, EmptyContent: View>: View {
    @Bindable var pane: PaneState
    let controller: LayoutTreeController
    let contentBuilder: (TabItem, PaneID) -> Content
    let emptyPaneBuilder: (PaneID) -> EmptyContent

    @State private var activeDropZone: NamuDropZone?
    @State private var dropLifecycle: NamuPaneDropLifecycle = .idle

    private var isFocused: Bool {
        controller.focusedPaneId == pane.id
    }

    private var isTabDragActive: Bool {
        controller.draggingTab != nil || controller.activeDragTab != nil
    }

    private var appearance: NamuSplitConfiguration.Appearance {
        controller.configuration.appearance
    }

    var body: some View {
        VStack(spacing: 0) {
            NamuTabBarView(
                pane: pane,
                controller: controller,
                isFocused: isFocused,
                showSplitButtons: controller.configuration.allowSplits && appearance.showSplitButtons
            )

            contentAreaWithDropZones
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: controller.draggingTab) { _, newValue in
            if newValue == nil {
                activeDropZone = nil
                dropLifecycle = .idle
            }
        }
    }

    // MARK: - Content Area with Drop Zones

    @ViewBuilder
    private var contentAreaWithDropZones: some View {
        GeometryReader { geometry in
            let size = geometry.size

            contentArea
                .frame(width: size.width, height: size.height)
                .overlay {
                    dropZonesLayer(size: size)
                }
                .overlay(alignment: .topLeading) {
                    NamuDropPlaceholderOverlay(zone: activeDropZone, size: size)
                        .allowsHitTesting(false)
                }
        }
        .clipped()
    }

    // MARK: - Content Area

    @ViewBuilder
    private var contentArea: some View {
        Group {
            if pane.tabs.isEmpty {
                emptyPaneBuilder(pane.id)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                switch controller.configuration.contentViewLifecycle {
                case .recreateOnSwitch:
                    if let selectedTab = pane.selectedTab ?? pane.tabs.first {
                        contentBuilder(selectedTab, pane.id)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .allowsHitTesting(!isTabDragActive)
                            .transition(.identity)
                            .transaction { tx in tx.animation = nil }
                    }

                case .keepAllAlive:
                    let effectiveSelectedTabId = pane.selectedTabId ?? pane.tabs.first?.id
                    ZStack {
                        ForEach(pane.tabs) { tab in
                            contentBuilder(tab, pane.id)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .opacity(tab.id == effectiveSelectedTabId ? 1 : 0)
                                .allowsHitTesting(!isTabDragActive && tab.id == effectiveSelectedTabId)
                        }
                    }
                    .transaction { tx in tx.disablesAnimations = true }
                }
            }
        }
        .animation(nil, value: pane.selectedTabId)
        .environment(\.namuPaneDropZone, activeDropZone)
    }

    // MARK: - Drop Zones Layer

    @ViewBuilder
    private func dropZonesLayer(size: CGSize) -> some View {
        ZStack {
            Color.clear
                .onTapGesture { controller.focusPane(pane.id) }
                .allowsHitTesting(!isTabDragActive)

            Color.clear
                .onDrop(of: [.namuTabTransfer], delegate: NamuUnifiedPaneDropDelegate(
                    size: size, pane: pane, controller: controller,
                    activeDropZone: $activeDropZone, dropLifecycle: $dropLifecycle
                ))
        }
    }
}

// MARK: - Drop Lifecycle

enum NamuPaneDropLifecycle {
    case idle
    case hovering
}

// MARK: - Drop Placeholder Overlay

private struct NamuDropPlaceholderOverlay: View {
    let zone: NamuDropZone?
    let size: CGSize

    private let placeholderColor = Color.accentColor.opacity(0.25)
    private let borderColor = Color.accentColor
    private let padding: CGFloat = 4

    var body: some View {
        let frame = overlayFrame(for: zone, in: size)
        RoundedRectangle(cornerRadius: 8)
            .fill(placeholderColor)
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(borderColor, lineWidth: 2))
            .frame(width: frame.width, height: frame.height)
            .offset(x: frame.minX, y: frame.minY)
            .opacity(zone != nil ? 1 : 0)
            .animation(.spring(duration: 0.25, bounce: 0.15), value: zone)
    }

    private func overlayFrame(for zone: NamuDropZone?, in size: CGSize) -> CGRect {
        switch zone {
        case .center, .none:
            return CGRect(x: padding, y: padding, width: size.width - padding * 2, height: size.height - padding * 2)
        case .left:
            return CGRect(x: padding, y: padding, width: size.width / 2 - padding, height: size.height - padding * 2)
        case .right:
            return CGRect(x: size.width / 2, y: padding, width: size.width / 2 - padding, height: size.height - padding * 2)
        case .top:
            return CGRect(x: padding, y: padding, width: size.width - padding * 2, height: size.height / 2 - padding)
        case .bottom:
            return CGRect(x: padding, y: size.height / 2, width: size.width - padding * 2, height: size.height / 2 - padding)
        }
    }
}

// MARK: - Unified Pane Drop Delegate

struct NamuUnifiedPaneDropDelegate: DropDelegate {
    let size: CGSize
    let pane: PaneState
    let controller: LayoutTreeController
    @Binding var activeDropZone: NamuDropZone?
    @Binding var dropLifecycle: NamuPaneDropLifecycle

    private func zoneForLocation(_ location: CGPoint) -> NamuDropZone {
        let edgeRatio: CGFloat = 0.25
        let horizontalEdge = max(80, size.width * edgeRatio)
        let verticalEdge = max(80, size.height * edgeRatio)

        if location.x < horizontalEdge { return .left }
        else if location.x > size.width - horizontalEdge { return .right }
        else if location.y < verticalEdge { return .top }
        else if location.y > size.height - verticalEdge { return .bottom }
        else { return .center }
    }

    private func effectiveZone(for info: DropInfo) -> NamuDropZone {
        let defaultZone = zoneForLocation(info.location)
        guard let draggedTab = controller.activeDragTab ?? controller.draggingTab,
              let sourcePaneId = controller.activeDragSourcePaneId ?? controller.dragSourcePaneId else {
            return defaultZone
        }

        // Adjacent pane optimization: if dragging a terminal from an adjacent pane,
        // treat the shared edge as center (drop into pane) rather than split
        if draggedTab.kind == "terminal", sourcePaneId != pane.id {
            if defaultZone == .left,
               controller.adjacentPane(to: sourcePaneId, direction: .right) == pane.id {
                return .center
            }
            if defaultZone == .right,
               controller.adjacentPane(to: sourcePaneId, direction: .left) == pane.id {
                return .center
            }
        }
        return defaultZone
    }

    func performDrop(info: DropInfo) -> Bool {
        if !Thread.isMainThread {
            return DispatchQueue.main.sync { performDrop(info: info) }
        }

        let zone = effectiveZone(for: info)

        guard let draggedTab = controller.activeDragTab ?? controller.draggingTab,
              let sourcePaneId = controller.activeDragSourcePaneId ?? controller.dragSourcePaneId else {
            // Try external tab drop
            guard let transfer = decodeTransfer(from: info), transfer.isFromCurrentProcess else {
                return false
            }
            let destination: LayoutTreeController.ExternalTabDropRequest.Destination
            if zone == .center {
                destination = .insert(targetPane: pane.id, targetIndex: nil)
            } else if let orientation = zone.orientation {
                destination = .split(targetPane: pane.id, orientation: orientation, insertFirst: zone.insertsFirst)
            } else {
                return false
            }
            let request = LayoutTreeController.ExternalTabDropRequest(
                tabId: TabID(id: transfer.tab.id), sourcePaneId: PaneID(id: transfer.sourcePaneId),
                destination: destination
            )
            let handled = controller.onExternalTabDrop?(request) ?? false
            if handled {
                dropLifecycle = .idle
                activeDropZone = nil
            }
            return handled
        }

        dropLifecycle = .idle
        activeDropZone = nil
        controller.draggingTab = nil
        controller.dragSourcePaneId = nil
        controller.activeDragTab = nil
        controller.activeDragSourcePaneId = nil

        if zone == .center {
            if sourcePaneId != pane.id {
                withTransaction(Transaction(animation: nil)) {
                    _ = controller.moveTab(TabID(id: draggedTab.id), toPane: pane.id, atIndex: nil)
                }
            }
        } else if let orientation = zone.orientation {
            _ = controller.splitPane(
                pane.id, orientation: orientation,
                movingTab: TabID(id: draggedTab.id), insertFirst: zone.insertsFirst
            )
        }
        return true
    }

    func dropEntered(info: DropInfo) {
        dropLifecycle = .hovering
        activeDropZone = effectiveZone(for: info)
    }

    func dropExited(info: DropInfo) {
        dropLifecycle = .idle
        activeDropZone = nil
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        guard dropLifecycle == .hovering else { return DropProposal(operation: .move) }
        activeDropZone = effectiveZone(for: info)
        return DropProposal(operation: .move)
    }

    func validateDrop(info: DropInfo) -> Bool {
        guard controller.isInteractive else { return false }
        let hasType = info.hasItemsConforming(to: [.namuTabTransfer])
        guard hasType else { return false }
        if controller.activeDragTab != nil || controller.draggingTab != nil { return true }
        guard let transfer = decodeTransfer(from: info), transfer.isFromCurrentProcess else { return false }
        return true
    }

    private func decodeTransfer(from info: DropInfo) -> TabTransferData? {
        let pasteboard = NSPasteboard(name: .drag)
        let type = NSPasteboard.PasteboardType(UTType.namuTabTransfer.identifier)
        if let data = pasteboard.data(forType: type),
           let transfer = try? JSONDecoder().decode(TabTransferData.self, from: data) {
            return transfer
        }
        if let raw = pasteboard.string(forType: type),
           let data = raw.data(using: .utf8),
           let transfer = try? JSONDecoder().decode(TabTransferData.self, from: data) {
            return transfer
        }
        return nil
    }
}
