import SwiftUI
import AppKit

/// Global guard to prevent re-entrant programmatic position syncs
private var namuSplitProgrammaticSyncDepth = 0

private class ThemedNSSplitView: NSSplitView {
    var customDividerColor: NSColor?
    override var dividerColor: NSColor {
        customDividerColor ?? super.dividerColor
    }
    override var isOpaque: Bool { false }
}

/// SwiftUI wrapper around NSSplitView for native split behavior
struct NamuSplitContainerView<Content: View, EmptyContent: View>: NSViewRepresentable {
    @Bindable var splitState: SplitState
    let controller: LayoutTreeController
    let contentBuilder: (TabItem, PaneID) -> Content
    let emptyPaneBuilder: (PaneID) -> EmptyContent

    private var appearance: NamuSplitConfiguration.Appearance {
        controller.configuration.appearance
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(
            splitState: splitState,
            minimumPaneWidth: appearance.minimumPaneWidth,
            minimumPaneHeight: appearance.minimumPaneHeight,
            onGeometryChange: { [weak controller] isDragging in
                controller?.notifyGeometryChange(isDragging: isDragging)
            }
        )
    }

    func makeNSView(context: Context) -> NSSplitView {
        let splitView = ThemedNSSplitView()
        splitView.customDividerColor = NamuTabBarColors.nsColorSeparator(for: appearance)
        splitView.isVertical = splitState.orientation == .horizontal
        splitView.dividerStyle = .thin
        splitView.delegate = context.coordinator
        splitView.wantsLayer = true
        splitView.layer?.backgroundColor = NSColor.clear.cgColor
        splitView.layer?.isOpaque = false

        let firstContainer = NSView()
        firstContainer.wantsLayer = true
        firstContainer.layer?.backgroundColor = NSColor.clear.cgColor
        firstContainer.layer?.isOpaque = false
        firstContainer.layer?.masksToBounds = true
        let firstController = makeHostingController(for: splitState.first)
        installHostingController(firstController, into: firstContainer)
        splitView.addArrangedSubview(firstContainer)
        context.coordinator.firstHostingController = firstController

        let secondContainer = NSView()
        secondContainer.wantsLayer = true
        secondContainer.layer?.backgroundColor = NSColor.clear.cgColor
        secondContainer.layer?.isOpaque = false
        secondContainer.layer?.masksToBounds = true
        let secondController = makeHostingController(for: splitState.second)
        installHostingController(secondController, into: secondContainer)
        splitView.addArrangedSubview(secondContainer)
        context.coordinator.secondHostingController = secondController

        context.coordinator.splitView = splitView

        let animationOrigin = splitState.animationOrigin
        let newPaneIndex = animationOrigin == .fromFirst ? 0 : 1
        let shouldAnimate = appearance.enableAnimations && animationOrigin != nil
        let duration = appearance.animationDuration

        if animationOrigin != nil {
            splitState.animationOrigin = nil
            if shouldAnimate {
                splitView.arrangedSubviews[newPaneIndex].isHidden = true
                context.coordinator.isAnimating = true
            }
        }

        func applyInitialDividerPosition() {
            if context.coordinator.didApplyInitialDividerPosition { return }

            let totalSize = splitState.orientation == .horizontal
                ? splitView.bounds.width : splitView.bounds.height
            let availableSize = max(totalSize - splitView.dividerThickness, 0)

            guard availableSize > 0 else {
                context.coordinator.initialDividerApplyAttempts += 1
                if context.coordinator.initialDividerApplyAttempts < 12 {
                    DispatchQueue.main.async { applyInitialDividerPosition() }
                    return
                }
                context.coordinator.didApplyInitialDividerPosition = true
                if animationOrigin != nil, shouldAnimate {
                    splitView.arrangedSubviews[newPaneIndex].isHidden = false
                    context.coordinator.isAnimating = false
                }
                return
            }

            context.coordinator.didApplyInitialDividerPosition = true
            context.coordinator.initialDividerApplyAttempts = 0

            if animationOrigin != nil {
                let targetPosition = availableSize * 0.5
                splitState.dividerPosition = 0.5

                if shouldAnimate {
                    let startPosition: CGFloat = animationOrigin == .fromFirst ? 0 : availableSize
                    context.coordinator.setPositionSafely(startPosition, in: splitView, layout: true)

                    DispatchQueue.main.async {
                        splitView.arrangedSubviews[newPaneIndex].isHidden = false
                        NamuSplitAnimator.shared.animate(
                            splitView: splitView, from: startPosition, to: targetPosition, duration: duration
                        ) {
                            context.coordinator.isAnimating = false
                            splitState.dividerPosition = 0.5
                            context.coordinator.lastAppliedPosition = 0.5
                        }
                    }
                } else {
                    context.coordinator.setPositionSafely(targetPosition, in: splitView, layout: false)
                }
            } else {
                let position = availableSize * splitState.dividerPosition
                context.coordinator.setPositionSafely(position, in: splitView, layout: false)
            }
        }

        DispatchQueue.main.async { applyInitialDividerPosition() }
        return splitView
    }

    func updateNSView(_ splitView: NSSplitView, context: Context) {
        context.coordinator.update(
            splitState: splitState,
            minimumPaneWidth: appearance.minimumPaneWidth,
            minimumPaneHeight: appearance.minimumPaneHeight,
            onGeometryChange: { [weak controller] isDragging in
                controller?.notifyGeometryChange(isDragging: isDragging)
            }
        )

        splitView.isHidden = !controller.isInteractive
        splitView.wantsLayer = true
        splitView.layer?.backgroundColor = NSColor.clear.cgColor
        splitView.layer?.isOpaque = false
        (splitView as? ThemedNSSplitView)?.customDividerColor = NamuTabBarColors.nsColorSeparator(for: appearance)
        splitView.isVertical = splitState.orientation == .horizontal

        let arranged = splitView.arrangedSubviews
        if arranged.count >= 2 {
            let firstType = splitState.first.nodeType
            let secondType = splitState.second.nodeType

            for container in arranged {
                container.wantsLayer = true
                container.layer?.backgroundColor = NSColor.clear.cgColor
                container.layer?.isOpaque = false
            }

            updateHostedContent(
                in: arranged[0], node: splitState.first,
                nodeTypeChanged: firstType != context.coordinator.firstNodeType,
                controller: &context.coordinator.firstHostingController
            )
            context.coordinator.firstNodeType = firstType

            updateHostedContent(
                in: arranged[1], node: splitState.second,
                nodeTypeChanged: secondType != context.coordinator.secondNodeType,
                controller: &context.coordinator.secondHostingController
            )
            context.coordinator.secondNodeType = secondType
        }

        let currentPosition = splitState.dividerPosition
        context.coordinator.syncPosition(currentPosition, in: splitView)
    }

    // MARK: - Helpers

    private func makeHostingController(for node: SplitNode) -> NSHostingController<AnyView> {
        let hc = NSHostingController(rootView: AnyView(makeView(for: node)))
        if #available(macOS 13.0, *) { hc.sizingOptions = [] }
        let v = hc.view
        v.translatesAutoresizingMaskIntoConstraints = true
        v.autoresizingMask = [.width, .height]
        let relaxed = NSLayoutConstraint.Priority(1)
        v.setContentHuggingPriority(relaxed, for: .horizontal)
        v.setContentCompressionResistancePriority(relaxed, for: .horizontal)
        v.setContentHuggingPriority(relaxed, for: .vertical)
        v.setContentCompressionResistancePriority(relaxed, for: .vertical)
        return hc
    }

    private func installHostingController(_ hc: NSHostingController<AnyView>, into container: NSView) {
        hc.view.frame = container.bounds
        hc.view.autoresizingMask = [.width, .height]
        if hc.view.superview !== container {
            container.addSubview(hc.view)
        }
    }

    private func updateHostedContent(
        in container: NSView, node: SplitNode, nodeTypeChanged: Bool,
        controller: inout NSHostingController<AnyView>?
    ) {
        _ = nodeTypeChanged
        if let current = controller {
            current.rootView = AnyView(makeView(for: node))
            current.view.frame = container.bounds
            return
        }
        let newController = makeHostingController(for: node)
        installHostingController(newController, into: container)
        controller = newController
    }

    @ViewBuilder
    private func makeView(for node: SplitNode) -> some View {
        switch node {
        case .pane(let paneState):
            NamuPaneContainerView(
                pane: paneState,
                controller: controller,
                contentBuilder: contentBuilder,
                emptyPaneBuilder: emptyPaneBuilder
            )
        case .split(let nestedSplitState):
            NamuSplitContainerView(
                splitState: nestedSplitState,
                controller: controller,
                contentBuilder: contentBuilder,
                emptyPaneBuilder: emptyPaneBuilder
            )
        }
    }

    // MARK: - Coordinator

    class Coordinator: NSObject, NSSplitViewDelegate {
        var splitState: SplitState
        private var splitStateId: UUID
        private var minimumPaneWidth: CGFloat
        private var minimumPaneHeight: CGFloat
        weak var splitView: NSSplitView?
        var isAnimating = false
        var didApplyInitialDividerPosition = false
        var initialDividerApplyAttempts = 0
        var onGeometryChange: ((_ isDragging: Bool) -> Void)?
        var lastAppliedPosition: CGFloat = 0.5
        var isSyncingProgrammatically = false
        var isDragging = false
        var firstNodeType: SplitNode.NodeType
        var secondNodeType: SplitNode.NodeType
        var firstHostingController: NSHostingController<AnyView>?
        var secondHostingController: NSHostingController<AnyView>?

        init(splitState: SplitState, minimumPaneWidth: CGFloat,
             minimumPaneHeight: CGFloat, onGeometryChange: ((_ isDragging: Bool) -> Void)?) {
            self.splitState = splitState
            self.splitStateId = splitState.id
            self.minimumPaneWidth = minimumPaneWidth
            self.minimumPaneHeight = minimumPaneHeight
            self.onGeometryChange = onGeometryChange
            self.lastAppliedPosition = splitState.dividerPosition
            self.firstNodeType = splitState.first.nodeType
            self.secondNodeType = splitState.second.nodeType
        }

        func update(splitState newState: SplitState, minimumPaneWidth: CGFloat,
                     minimumPaneHeight: CGFloat, onGeometryChange: ((_ isDragging: Bool) -> Void)?) {
            self.onGeometryChange = onGeometryChange
            self.minimumPaneWidth = minimumPaneWidth
            self.minimumPaneHeight = minimumPaneHeight

            if newState.id != splitStateId {
                splitStateId = newState.id
                splitState = newState
                lastAppliedPosition = newState.dividerPosition
                didApplyInitialDividerPosition = false
                initialDividerApplyAttempts = 0
                isAnimating = false
                isDragging = false
                firstNodeType = newState.first.nodeType
                secondNodeType = newState.second.nodeType
                return
            }
            splitState = newState
        }

        private func splitAvailableSize(in sv: NSSplitView) -> CGFloat {
            let total = splitState.orientation == .horizontal ? sv.bounds.width : sv.bounds.height
            return max(total - sv.dividerThickness, 0)
        }

        private func effectiveMinimumPaneSize(in sv: NSSplitView) -> CGFloat {
            let available = splitAvailableSize(in: sv)
            guard available > 0 else { return 0 }
            let requested = max(
                splitState.orientation == .horizontal ? minimumPaneWidth : minimumPaneHeight, 1
            )
            return min(requested, available / 2)
        }

        private func normalizedDividerBounds(in sv: NSSplitView) -> ClosedRange<CGFloat> {
            let available = splitAvailableSize(in: sv)
            guard available > 0 else { return 0...1 }
            let minNorm = min(0.5, effectiveMinimumPaneSize(in: sv) / available)
            return minNorm...(1 - minNorm)
        }

        private func clampedDividerPosition(_ position: CGFloat, in sv: NSSplitView) -> CGFloat {
            let available = splitAvailableSize(in: sv)
            guard available > 0 else { return 0 }
            let minSize = effectiveMinimumPaneSize(in: sv)
            return min(max(position, minSize), max(minSize, available - minSize))
        }

        func setPositionSafely(_ position: CGFloat, in sv: NSSplitView, layout: Bool = true) {
            isSyncingProgrammatically = true
            namuSplitProgrammaticSyncDepth += 1
            defer {
                isSyncingProgrammatically = false
                namuSplitProgrammaticSyncDepth = max(0, namuSplitProgrammaticSyncDepth - 1)
            }
            sv.setPosition(clampedDividerPosition(position, in: sv), ofDividerAt: 0)
            if layout { sv.layoutSubtreeIfNeeded() }
        }

        func syncPosition(_ statePosition: CGFloat, in sv: NSSplitView) {
            guard !isAnimating, !isSyncingProgrammatically,
                  namuSplitProgrammaticSyncDepth == 0,
                  sv.arrangedSubviews.count >= 2 else { return }

            let available = splitAvailableSize(in: sv)
            guard available > 0 else { return }

            let bounds = normalizedDividerBounds(in: sv)
            let clamped = max(bounds.lowerBound, min(bounds.upperBound, statePosition))

            let firstSubview = sv.arrangedSubviews[0]
            let currentPx = splitState.orientation == .horizontal
                ? firstSubview.frame.width : firstSubview.frame.height
            let currentNorm = max(bounds.lowerBound, min(bounds.upperBound, currentPx / available))

            if abs(clamped - lastAppliedPosition) <= 0.01 &&
                abs(currentNorm - clamped) <= 0.01 { return }

            setPositionSafely(available * clamped, in: sv, layout: true)
            lastAppliedPosition = clamped
        }

        // MARK: - NSSplitViewDelegate

        func splitViewWillResizeSubviews(_ notification: Notification) {
            guard (NSEvent.pressedMouseButtons & 1) != 0 else {
                isDragging = false
                return
            }
            if isDragging { return }
            guard let event = NSApp.currentEvent,
                  let sv = notification.object as? NSSplitView else { return }
            let now = ProcessInfo.processInfo.systemUptime
            guard (now - event.timestamp) < 0.1,
                  event.type == .leftMouseDown || event.type == .leftMouseDragged,
                  event.window == sv.window,
                  sv.arrangedSubviews.count >= 2 else { return }

            let location = sv.convert(event.locationInWindow, from: nil)
            let a = sv.arrangedSubviews[0].frame
            let b = sv.arrangedSubviews[1].frame
            let thickness = sv.dividerThickness

            let dividerRect: NSRect
            if sv.isVertical {
                guard a.width > 1, b.width > 1 else { return }
                dividerRect = NSRect(x: max(0, a.maxX), y: 0, width: thickness, height: sv.bounds.height)
            } else {
                guard a.height > 1, b.height > 1 else { return }
                dividerRect = NSRect(x: 0, y: max(0, a.maxY), width: sv.bounds.width, height: thickness)
            }

            if dividerRect.insetBy(dx: -4, dy: -4).contains(location) {
                isDragging = true
            }
        }

        func splitViewDidResizeSubviews(_ notification: Notification) {
            guard !isAnimating else { return }
            guard let sv = notification.object as? NSSplitView else { return }
            if isSyncingProgrammatically || namuSplitProgrammaticSyncDepth > 0 { return }

            let leftDown = (NSEvent.pressedMouseButtons & 1) != 0
            if !leftDown { isDragging = false }

            guard sv.arrangedSubviews.count >= 2 else { return }
            let available = splitAvailableSize(in: sv)
            guard available > 0 else { return }

            if let first = sv.arrangedSubviews.first {
                let px = splitState.orientation == .horizontal
                    ? first.frame.width : first.frame.height
                var norm = px / available
                let bounds = normalizedDividerBounds(in: sv)
                norm = max(bounds.lowerBound, min(bounds.upperBound, norm))
                if abs(norm - 0.5) < 0.01 { norm = 0.5 }

                let wasDragging = isDragging && leftDown
                if let event = NSApp.currentEvent, event.type == .leftMouseUp {
                    isDragging = false
                }

                guard wasDragging else {
                    syncPosition(splitState.dividerPosition, in: sv)
                    onGeometryChange?(false)
                    return
                }

                Task { @MainActor in
                    self.splitState.dividerPosition = norm
                    self.lastAppliedPosition = norm
                    self.onGeometryChange?(wasDragging)
                }
            }
        }

        func splitView(_ sv: NSSplitView, effectiveRect proposedRect: NSRect,
                        forDrawnRect drawnRect: NSRect, ofDividerAt idx: Int) -> NSRect {
            proposedRect.union(drawnRect.insetBy(dx: -5, dy: -5))
        }

        func splitView(_ sv: NSSplitView, additionalEffectiveRectOfDividerAt idx: Int) -> NSRect {
            guard sv.arrangedSubviews.count >= idx + 2 else { return .zero }
            let a = sv.arrangedSubviews[idx].frame
            let b = sv.arrangedSubviews[idx + 1].frame
            let t = sv.dividerThickness
            let rect: NSRect
            if sv.isVertical {
                guard a.width > 1, b.width > 1 else { return .zero }
                rect = NSRect(x: max(0, a.maxX), y: 0, width: t, height: sv.bounds.height)
            } else {
                guard a.height > 1, b.height > 1 else { return .zero }
                rect = NSRect(x: 0, y: max(0, a.maxY), width: sv.bounds.width, height: t)
            }
            return rect.insetBy(dx: -5, dy: -5)
        }

        func splitView(_ sv: NSSplitView, constrainMinCoordinate proposed: CGFloat, ofSubviewAt idx: Int) -> CGFloat {
            guard !isAnimating else { return proposed }
            return max(proposed, effectiveMinimumPaneSize(in: sv))
        }

        func splitView(_ sv: NSSplitView, constrainMaxCoordinate proposed: CGFloat, ofSubviewAt idx: Int) -> CGFloat {
            guard !isAnimating else { return proposed }
            let available = splitAvailableSize(in: sv)
            let minSize = effectiveMinimumPaneSize(in: sv)
            return min(proposed, max(minSize, available - minSize))
        }
    }
}
