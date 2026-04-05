import SwiftUI

/// Main entry point for the NamuSplit layout system.
///
/// Usage:
/// ```swift
/// NamuSplitView(controller: controller) { tab, paneId in
///     MyContentView(for: tab)
/// } emptyPane: { paneId in
///     Text("Empty pane")
/// }
/// ```
struct NamuSplitView<Content: View, EmptyContent: View>: View {
    @Bindable private var controller: LayoutTreeController
    private let contentBuilder: (Tab, PaneID) -> Content
    private let emptyPaneBuilder: (PaneID) -> EmptyContent

    init(
        controller: LayoutTreeController,
        @ViewBuilder content: @escaping (Tab, PaneID) -> Content,
        @ViewBuilder emptyPane: @escaping (PaneID) -> EmptyContent
    ) {
        self.controller = controller
        self.contentBuilder = content
        self.emptyPaneBuilder = emptyPane
    }

    var body: some View {
        GeometryReader { geometry in
            splitNodeContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(NamuTabBarColors.paneBackground(for: controller.configuration.appearance))
                .focusable()
                .focusEffectDisabled()
                .onChange(of: geometry.size) { _, _ in
                    updateContainerFrame(geometry: geometry)
                }
                .onAppear {
                    updateContainerFrame(geometry: geometry)
                }
        }
        .environment(controller)
    }

    private func updateContainerFrame(geometry: GeometryProxy) {
        let frame = geometry.frame(in: .global)
        controller.containerFrame = frame
        controller.notifyGeometryChange()
    }

    @ViewBuilder
    private var splitNodeContent: some View {
        let nodeToRender: SplitNode = {
            if let zoomedPaneId = controller.zoomedPaneId,
               let zoomedNode = controller.rootNode.findNode(containing: zoomedPaneId) {
                return zoomedNode
            }
            return controller.rootNode
        }()

        LayoutNodeView(
            node: nodeToRender,
            controller: controller,
            contentBuilder: { tabItem, paneId in
                contentBuilder(Tab(from: tabItem), paneId)
            },
            emptyPaneBuilder: emptyPaneBuilder
        )
    }
}

// MARK: - Convenience initializer with default empty view

extension NamuSplitView where EmptyContent == NamuDefaultEmptyPaneView {
    init(
        controller: LayoutTreeController,
        @ViewBuilder content: @escaping (Tab, PaneID) -> Content
    ) {
        self.controller = controller
        self.contentBuilder = content
        self.emptyPaneBuilder = { _ in NamuDefaultEmptyPaneView() }
    }
}

struct NamuDefaultEmptyPaneView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "doc.text")
                .font(.system(size: 48))
                .foregroundStyle(.tertiary)
            Text("No Open Tabs")
                .font(.headline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
