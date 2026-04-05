import SwiftUI
import AppKit

/// Recursively renders a split node (pane or split)
struct LayoutNodeView<Content: View, EmptyContent: View>: View {
    let node: SplitNode
    let controller: LayoutTreeController
    let contentBuilder: (TabItem, PaneID) -> Content
    let emptyPaneBuilder: (PaneID) -> EmptyContent

    var body: some View {
        switch node {
        case .pane(let paneState):
            NamuSinglePaneWrapper(
                pane: paneState,
                controller: controller,
                contentBuilder: contentBuilder,
                emptyPaneBuilder: emptyPaneBuilder
            )

        case .split(let splitState):
            NamuSplitContainerView(
                splitState: splitState,
                controller: controller,
                contentBuilder: contentBuilder,
                emptyPaneBuilder: emptyPaneBuilder
            )
        }
    }
}

// MARK: - Single Pane Wrapper (NSViewRepresentable)

/// Container NSView for a pane.
private class PaneDragContainerView: NSView {
    override var isOpaque: Bool { false }
}

/// Wraps PaneContainerView in NSHostingController for proper AppKit layout constraints
struct NamuSinglePaneWrapper<Content: View, EmptyContent: View>: NSViewRepresentable {
    let pane: PaneState
    let controller: LayoutTreeController
    let contentBuilder: (TabItem, PaneID) -> Content
    let emptyPaneBuilder: (PaneID) -> EmptyContent

    func makeNSView(context: Context) -> NSView {
        let paneView = NamuPaneContainerView(
            pane: pane,
            controller: controller,
            contentBuilder: contentBuilder,
            emptyPaneBuilder: emptyPaneBuilder
        )
        let hostingController = NSHostingController(rootView: paneView)
        hostingController.view.translatesAutoresizingMaskIntoConstraints = false

        let containerView = PaneDragContainerView()
        containerView.wantsLayer = true
        containerView.layer?.backgroundColor = NSColor.clear.cgColor
        containerView.layer?.isOpaque = false
        containerView.layer?.masksToBounds = true
        containerView.addSubview(hostingController.view)

        NSLayoutConstraint.activate([
            hostingController.view.topAnchor.constraint(equalTo: containerView.topAnchor),
            hostingController.view.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
            hostingController.view.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),
            hostingController.view.bottomAnchor.constraint(equalTo: containerView.bottomAnchor)
        ])

        context.coordinator.hostingController = hostingController
        return containerView
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        nsView.isHidden = !controller.isInteractive
        nsView.wantsLayer = true
        nsView.layer?.backgroundColor = NSColor.clear.cgColor
        nsView.layer?.isOpaque = false
        nsView.layer?.masksToBounds = true

        let paneView = NamuPaneContainerView(
            pane: pane,
            controller: controller,
            contentBuilder: contentBuilder,
            emptyPaneBuilder: emptyPaneBuilder
        )
        context.coordinator.hostingController?.rootView = paneView
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    class Coordinator {
        var hostingController: NSHostingController<NamuPaneContainerView<Content, EmptyContent>>?
    }
}
