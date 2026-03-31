import AppKit
import SwiftUI
import os.log
import ObjectiveC

private let dragLog = Logger(subsystem: "dev.namu", category: "WindowDragHandle")
private var suppressionKey: UInt8 = 0

/// A transparent view that enables dragging the window when clicking in empty titlebar space.
/// Keeps `window.isMovableByWindowBackground = false` so drags in the app content
/// (e.g. sidebar reordering) don't move the whole window.
struct WindowDragHandleView: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        DraggableView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        // No-op
    }

    private final class DraggableView: NSView {
        override var mouseDownCanMoveWindow: Bool { false }

        /// Re-entrancy guard: prevents recursive `performDrag` calls that can occur
        /// when `performDrag` triggers another mouseDown/mouseDragged before it returns.
        private var isDragging = false

        /// Suppression depth stored as an ObjC associated object on self so it survives
        /// SwiftUI view recreation. Depth > 0 suppresses drag initiation.
        private var objcSuppressionDepth: Int {
            get { objc_getAssociatedObject(self, &suppressionKey) as? Int ?? 0 }
            set { objc_setAssociatedObject(self, &suppressionKey, newValue, .OBJC_ASSOCIATION_RETAIN) }
        }

        override func mouseDown(with event: NSEvent) {
            if event.clickCount >= 2 {
                handleDoubleClick()
                return
            }

            let depth = objcSuppressionDepth
            if depth > 0 {
                dragLog.debug("drag suppressed: suppression depth = \(depth)")
                super.mouseDown(with: event)
                return
            }

            // Walk window content view hierarchy to detect interactive controls at the click point.
            if clickHitsInteractiveControl(event) {
                dragLog.debug("drag suppressed: interactive control at point")
                super.mouseDown(with: event)
                return
            }

            performWindowDrag(with: event)
        }

        override func mouseDragged(with event: NSEvent) {
            performWindowDrag(with: event)
        }

        // MARK: - Private

        /// Perform a window drag, guarded against re-entrancy.
        private func performWindowDrag(with event: NSEvent) {
            guard !isDragging, objcSuppressionDepth == 0 else { return }
            guard let window else { return }

            let loc = event.locationInWindow
            dragLog.debug("drag started at (\(loc.x, format: .fixed(precision: 1)), \(loc.y, format: .fixed(precision: 1)))")
            isDragging = true
            let previousMovable = window.isMovable
            if !previousMovable { window.isMovable = true }
            defer {
                if window.isMovable != previousMovable {
                    window.isMovable = previousMovable
                }
                isDragging = false
                dragLog.debug("drag ended")
            }
            window.performDrag(with: event)
        }

        /// Handle a double-click by respecting the system "AppleActionOnDoubleClick" preference.
        /// Values: "Maximize" (default zoom), "Minimize", "None" (no-op).
        /// Falls back to the legacy "AppleMiniaturizeOnDoubleClick" key if the primary key is absent.
        private func handleDoubleClick() {
            let defaults = UserDefaults.standard
            if let action = defaults.string(forKey: "AppleActionOnDoubleClick") {
                dragLog.debug("double-click: action=\(action)")
                switch action {
                case "Minimize":
                    window?.miniaturize(nil)
                case "None":
                    break
                default:
                    // "Maximize" and any unknown value fall through to zoom.
                    window?.zoom(nil)
                }
            } else {
                // Legacy fallback: AppleMiniaturizeOnDoubleClick (Bool)
                let miniaturize = defaults.bool(forKey: "AppleMiniaturizeOnDoubleClick")
                let action = miniaturize ? "Minimize" : "Maximize"
                dragLog.debug("double-click: action=\(action)")
                if miniaturize {
                    window?.miniaturize(nil)
                } else {
                    window?.zoom(nil)
                }
            }
        }

        /// Returns true if the click point falls on any interactive control in the window's
        /// content view hierarchy — standard window buttons, toolbar items, or any NSControl.
        private func clickHitsInteractiveControl(_ event: NSEvent) -> Bool {
            guard let window else { return false }
            let pointInWindow = event.locationInWindow

            // Check standard window buttons explicitly (close / minimize / zoom).
            for buttonType: NSWindow.ButtonType in [.closeButton, .miniaturizeButton, .zoomButton] {
                if let btn = window.standardWindowButton(buttonType) {
                    let pointInBtn = btn.convert(pointInWindow, from: nil)
                    if btn.bounds.contains(pointInBtn) { return true }
                }
            }

            // Walk the full content-view hierarchy for NSControl subclasses.
            guard let contentView = window.contentView else { return false }
            let pointInContent = contentView.convert(pointInWindow, from: nil)
            if let control = hitTestForControlView(in: contentView, point: pointInContent) {
                dragLog.debug("drag: blocked by control \(type(of: control))")
                return true
            }

            // Check toolbar items via NSToolbar's visible items.
            if let toolbar = window.toolbar {
                for item in toolbar.visibleItems ?? [] {
                    if let itemView = item.view {
                        let pointInItem = itemView.convert(pointInWindow, from: nil)
                        if itemView.bounds.contains(pointInItem) { return true }
                    }
                }
            }

            return false
        }

        /// Recursively walk `view`'s subviews to find any NSControl that contains `point`.
        /// Returns the matched control view, or nil if none found.
        private func hitTestForControlView(in view: NSView, point: NSPoint) -> NSView? {
            guard view.bounds.contains(point) else { return nil }
            if view is NSControl, view !== self {
                let hit = view.hitTest(view.superview?.convert(point, to: nil) ?? point)
                if hit != nil { return view }
            }
            for sub in view.subviews {
                let pointInSub = sub.convert(point, from: view)
                if let found = hitTestForControlView(in: sub, point: pointInSub) { return found }
            }
            return nil
        }
    }
}
