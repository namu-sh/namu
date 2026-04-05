import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Tab drop lifecycle state
enum TabDropLifecycle {
    case idle
    case hovering
}

/// Tab bar view with scrollable tabs, drag/drop support, and split buttons
struct NamuTabBarView: View {
    @Bindable var pane: PaneState
    let controller: LayoutTreeController
    let isFocused: Bool
    var showSplitButtons: Bool = true

    @State private var dropTargetIndex: Int?
    @State private var dropLifecycle: TabDropLifecycle = .idle
    @State private var scrollOffset: CGFloat = 0
    @State private var contentWidth: CGFloat = 0
    @State private var containerWidth: CGFloat = 0

    private var tabBarSaturation: Double {
        (isFocused || controller.dragSourcePaneId == pane.id) ? 1.0 : 0.0
    }

    private var appearance: NamuSplitConfiguration.Appearance {
        controller.configuration.appearance
    }

    private var canScrollLeft: Bool { scrollOffset > 1 }
    private var canScrollRight: Bool {
        contentWidth > containerWidth && scrollOffset < contentWidth - containerWidth - 1
    }

    var body: some View {
        HStack(spacing: 0) {
            GeometryReader { containerGeo in
                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: NamuTabBarMetrics.tabSpacing) {
                            ForEach(Array(pane.tabs.enumerated()), id: \.element.id) { index, tab in
                                tabItem(for: tab, at: index)
                                    .id(tab.id)
                            }

                            // Drop zone after last tab
                            Color.clear
                                .frame(width: 20, height: NamuTabBarMetrics.tabHeight)
                                .contentShape(Rectangle())
                                .onDrop(of: [.namuTabTransfer], delegate: NamuTabDropDelegate(
                                    targetIndex: pane.tabs.count, pane: pane, controller: controller,
                                    dropTargetIndex: $dropTargetIndex, dropLifecycle: $dropLifecycle
                                ))
                        }
                        .padding(.horizontal, NamuTabBarMetrics.barPadding)
                        .animation(nil, value: pane.tabs.map(\.id))
                        .background(
                            GeometryReader { contentGeo in
                                Color.clear
                                    .onChange(of: contentGeo.frame(in: .named("namuTabScroll"))) { _, newFrame in
                                        scrollOffset = -newFrame.minX
                                        contentWidth = newFrame.width
                                    }
                                    .onAppear {
                                        let frame = contentGeo.frame(in: .named("namuTabScroll"))
                                        scrollOffset = -frame.minX
                                        contentWidth = frame.width
                                    }
                            }
                        )
                    }
                    .overlay(alignment: .trailing) {
                        let trailing = max(0, containerGeo.size.width - contentWidth)
                        if trailing >= 1 {
                            Color.clear
                                .frame(width: trailing, height: NamuTabBarMetrics.tabHeight)
                                .contentShape(Rectangle())
                                .onTapGesture(count: 2) {
                                    guard controller.isInteractive else { return }
                                    controller.requestNewTab(kind: "terminal", inPane: pane.id)
                                }
                                .onDrop(of: [.namuTabTransfer], delegate: NamuTabDropDelegate(
                                    targetIndex: pane.tabs.count, pane: pane, controller: controller,
                                    dropTargetIndex: $dropTargetIndex, dropLifecycle: $dropLifecycle
                                ))
                        }
                    }
                    .coordinateSpace(name: "namuTabScroll")
                    .onAppear {
                        containerWidth = containerGeo.size.width
                        if let tabId = pane.selectedTabId {
                            proxy.scrollTo(tabId, anchor: .center)
                        }
                    }
                    .onChange(of: containerGeo.size.width) { _, newWidth in
                        containerWidth = newWidth
                    }
                    .onChange(of: pane.selectedTabId) { _, newTabId in
                        if let tabId = newTabId {
                            withTransaction(Transaction(animation: nil)) {
                                proxy.scrollTo(tabId, anchor: .center)
                            }
                        }
                    }
                }
                .frame(height: NamuTabBarMetrics.barHeight)
                .overlay(fadeOverlays)
            }

            if showSplitButtons {
                splitButtons.saturation(tabBarSaturation)
            }
        }
        .frame(height: NamuTabBarMetrics.barHeight)
        .contentShape(Rectangle())
        .background(
            NamuTabBarColors.tabBarBackground(for: appearance)
        )
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(NamuTabBarColors.separator(for: appearance).opacity(0.5))
                .frame(height: 0.5)
        }
        .onChange(of: controller.draggingTab) { _, newValue in
            if newValue == nil {
                dropTargetIndex = nil
                dropLifecycle = .idle
            }
        }
    }

    // MARK: - Tab Item

    @ViewBuilder
    private func tabItem(for tab: TabItem, at index: Int) -> some View {
        let showsZoomIndicator = controller.zoomedPaneId == pane.id && pane.selectedTabId == tab.id
        NamuTabItemView(
            tab: tab,
            isSelected: pane.selectedTabId == tab.id,
            showsZoomIndicator: showsZoomIndicator,
            appearance: appearance,
            saturation: tabBarSaturation,
            onSelect: {
                withTransaction(Transaction(animation: nil)) {
                    pane.selectTab(tab.id)
                    controller.focusPane(pane.id)
                }
            },
            onClose: {
                guard !tab.isPinned else { return }
                withTransaction(Transaction(animation: nil)) {
                    controller.onTabCloseRequest?(TabID(id: tab.id), pane.id)
                    _ = controller.closeTab(TabID(id: tab.id), inPane: pane.id)
                }
            },
            onZoomToggle: {
                _ = controller.togglePaneZoom(inPane: pane.id)
            },
            onContextAction: { action in
                controller.requestTabContextAction(action, for: TabID(id: tab.id), inPane: pane.id)
            }
        )
        .onDrag {
            createItemProvider(for: tab)
        } preview: {
            NamuTabDragPreview(tab: tab, appearance: appearance)
        }
        .onDrop(of: [.namuTabTransfer], delegate: NamuTabDropDelegate(
            targetIndex: index, pane: pane, controller: controller,
            dropTargetIndex: $dropTargetIndex, dropLifecycle: $dropLifecycle
        ))
        .overlay(alignment: .leading) {
            if dropTargetIndex == index {
                dropIndicator.saturation(tabBarSaturation)
            }
        }
    }

    // MARK: - Drag Provider

    private func createItemProvider(for tab: TabItem) -> NSItemProvider {
        controller.draggingTab = tab
        controller.dragSourcePaneId = pane.id
        controller.dragGeneration += 1
        controller.activeDragTab = tab
        controller.activeDragSourcePaneId = pane.id
        controller.dragHiddenSourceTabId = tab.id
        controller.dragHiddenSourcePaneId = pane.id

        let transfer = TabTransferData(tab: tab, sourcePaneId: pane.id.id)
        let provider = NSItemProvider()

        if let data = try? JSONEncoder().encode(transfer) {
            provider.registerDataRepresentation(
                forTypeIdentifier: UTType.namuTabTransfer.identifier,
                visibility: .ownProcess
            ) { completion in
                completion(data, nil)
                return nil
            }
        }

        // Additional payloads (e.g. namuPaneTab for cross-workspace drops)
        if let payloads = controller.onCreateAdditionalDragPayload?(TabID(id: tab.id)) {
            for (typeId, data) in payloads {
                provider.registerDataRepresentation(
                    forTypeIdentifier: typeId, visibility: .ownProcess
                ) { completion in
                    completion(data, nil)
                    return nil
                }
            }
        }

        let generation = controller.dragGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 8.0) { [weak controller] in
            guard let controller, controller.dragGeneration == generation else { return }
            controller.draggingTab = nil
            controller.dragSourcePaneId = nil
            controller.activeDragTab = nil
            controller.activeDragSourcePaneId = nil
            controller.dragHiddenSourceTabId = nil
            controller.dragHiddenSourcePaneId = nil
        }

        return provider
    }

    // MARK: - Drop Indicator

    private var dropIndicator: some View {
        Rectangle()
            .fill(Color.accentColor)
            .frame(width: 2)
            .padding(.vertical, 4)
    }

    // MARK: - Fade Overlays

    @ViewBuilder
    private var fadeOverlays: some View {
        HStack {
            if canScrollLeft {
                LinearGradient(
                    colors: [NamuTabBarColors.tabBarBackground(for: appearance), .clear],
                    startPoint: .leading, endPoint: .trailing
                ).frame(width: 20)
            }
            Spacer()
            if canScrollRight {
                LinearGradient(
                    colors: [.clear, NamuTabBarColors.tabBarBackground(for: appearance)],
                    startPoint: .leading, endPoint: .trailing
                ).frame(width: 20)
            }
        }
        .allowsHitTesting(false)
    }

    // MARK: - Split Buttons

    @ViewBuilder
    private var splitButtons: some View {
        HStack(spacing: 0) {
            splitButton(icon: "rectangle.split.1x2", tooltip: appearance.splitButtonTooltips.splitDown) {
                _ = controller.splitPane(pane.id, orientation: .vertical)
            }
            splitButton(icon: "rectangle.split.2x1", tooltip: appearance.splitButtonTooltips.splitRight) {
                _ = controller.splitPane(pane.id, orientation: .horizontal)
            }
        }
    }

    @ViewBuilder
    private func splitButton(icon: String, tooltip: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(NamuTabBarColors.inactiveText(for: appearance))
                .frame(width: NamuTabBarMetrics.splitButtonSize, height: NamuTabBarMetrics.barHeight)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(tooltip)
    }
}

// MARK: - Tab Drop Delegate

struct NamuTabDropDelegate: DropDelegate {
    let targetIndex: Int
    let pane: PaneState
    let controller: LayoutTreeController
    @Binding var dropTargetIndex: Int?
    @Binding var dropLifecycle: TabDropLifecycle

    func performDrop(info: DropInfo) -> Bool {
        guard let draggedTab = controller.activeDragTab ?? controller.draggingTab,
              let sourcePaneId = controller.activeDragSourcePaneId ?? controller.dragSourcePaneId else {
            return false
        }

        dropLifecycle = .idle
        dropTargetIndex = nil
        controller.draggingTab = nil
        controller.dragSourcePaneId = nil
        controller.activeDragTab = nil
        controller.activeDragSourcePaneId = nil

        let tabId = TabID(id: draggedTab.id)

        if sourcePaneId == pane.id {
            withTransaction(Transaction(animation: nil)) {
                _ = controller.reorderTab(tabId, toIndex: targetIndex)
            }
        } else {
            withTransaction(Transaction(animation: nil)) {
                _ = controller.moveTab(tabId, toPane: pane.id, atIndex: targetIndex)
            }
        }
        return true
    }

    func dropEntered(info: DropInfo) {
        dropLifecycle = .hovering
        withAnimation(.easeInOut(duration: 0.15)) { dropTargetIndex = targetIndex }
    }

    func dropExited(info: DropInfo) {
        dropLifecycle = .idle
        withAnimation(.easeInOut(duration: 0.15)) { dropTargetIndex = nil }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        guard dropLifecycle == .hovering else { return DropProposal(operation: .move) }
        return DropProposal(operation: .move)
    }

    func validateDrop(info: DropInfo) -> Bool {
        guard controller.isInteractive else { return false }
        return info.hasItemsConforming(to: [.namuTabTransfer])
    }
}

// MARK: - Tab Drag Preview

struct NamuTabDragPreview: View {
    let tab: TabItem
    let appearance: NamuSplitConfiguration.Appearance

    var body: some View {
        HStack(spacing: 6) {
            if let iconName = tab.icon {
                Image(systemName: iconName)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            Text(tab.title)
                .font(.system(size: 12))
                .lineLimit(1)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
    }
}
