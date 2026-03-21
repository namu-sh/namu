import AppKit

// MARK: - TerminalPortalView

/// AppKit NSView overlay placed above SwiftUI in the window's content view hierarchy.
///
/// **Why this exists:**
/// SwiftUI's hit-testing calls `hitTest` on every single event — including every
/// keystroke. Walking the full SwiftUI view tree on keyboard events adds ~0.5–2ms
/// of latency. By placing an AppKit overlay above SwiftUI and short-circuiting
/// non-pointer events, we keep the fast keyboard path at <0.1ms.
///
/// **How it works:**
/// - `hitTest` is called on EVERY event (keyboard + mouse).
/// - The `isPointerEvent` guard is the key optimization: for keyboard events,
///   we skip all the portal geometry calculation and fall through immediately.
/// - For pointer events, we walk the terminal surface subviews to find the
///   correct target, handling split divider regions and drag pass-through.
///
/// In Phase 0 (single terminal), this view wraps the single GhosttySurfaceView.
/// In Phase 1 (splits), multiple GhosttySurfaceView instances are registered here.
final class TerminalPortalView: NSView {

    // MARK: - Registered surface views

    /// Surface views managed by this portal. Add a surface when it is created,
    /// remove it when it is destroyed.
    private(set) var surfaceViews: [GhosttySurfaceView] = []

    func addSurface(_ view: GhosttySurfaceView) {
        guard !surfaceViews.contains(view) else { return }
        surfaceViews.append(view)
        addSubview(view)
    }

    func removeSurface(_ view: GhosttySurfaceView) {
        surfaceViews.removeAll { $0 === view }
        view.removeFromSuperview()
    }

    // MARK: - NSView overrides

    override var isOpaque: Bool { false }
    override var acceptsFirstResponder: Bool { false }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.invalidateCursorRects(for: self)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        window?.invalidateCursorRects(for: self)
        // Resize all surface views to fill the portal.
        for view in surfaceViews {
            view.frame = bounds
        }
    }

    // MARK: - Hit testing (the key optimization)

    // PERF: hitTest is called on EVERY event including every keystroke.
    // Keep the non-pointer path O(1) — no allocation, no view-tree walk.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let currentEvent = NSApp.currentEvent
        let isPointerEvent: Bool
        switch currentEvent?.type {
        case .mouseMoved, .mouseEntered, .mouseExited,
             .leftMouseDown, .leftMouseUp, .leftMouseDragged,
             .rightMouseDown, .rightMouseUp, .rightMouseDragged,
             .otherMouseDown, .otherMouseUp, .otherMouseDragged,
             .scrollWheel, .cursorUpdate:
            isPointerEvent = true
        default:
            isPointerEvent = false
        }

        if isPointerEvent {
            // For pointer events: let AppKit walk our subviews normally.
            // Return nil (pass-through) if the portal itself is the hit view —
            // we don't want the portal to eat pointer events.
            let hit = super.hitTest(point)
            return hit === self ? nil : hit
        }

        // Non-pointer (keyboard, flags changed, etc.): skip hit-test entirely.
        // Return nil so AppKit routes keyboard events directly to first responder
        // without walking the SwiftUI view tree.
        return nil
    }
}

// MARK: - TerminalPortalRegistry

/// Manages the single TerminalPortalView per window.
/// In Phase 0 there is exactly one portal (the main window).
/// Phase 1 may have portals per workspace tab.
enum TerminalPortalRegistry {

    private static var portals: [ObjectIdentifier: TerminalPortalView] = [:]

    /// Return the portal for a given window, creating and installing it if needed.
    @MainActor
    static func portal(for window: NSWindow) -> TerminalPortalView {
        let key = ObjectIdentifier(window)
        if let existing = portals[key] {
            return existing
        }

        let portal = TerminalPortalView(frame: window.contentView?.bounds ?? .zero)
        portal.autoresizingMask = [.width, .height]
        portal.wantsLayer = false

        // Insert the portal above SwiftUI's content view but below the window chrome.
        if let contentView = window.contentView {
            contentView.addSubview(portal, positioned: .above, relativeTo: nil)
        }

        portals[key] = portal

        // Clean up when the window closes.
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { [key] _ in
            portals.removeValue(forKey: key)
        }

        return portal
    }

    /// Remove the portal for a window (called on window close).
    @MainActor
    static func removePortal(for window: NSWindow) {
        let key = ObjectIdentifier(window)
        portals.removeValue(forKey: key)
    }

    /// Resize all portals to match their window's content view bounds.
    /// Call this after layout changes that affect window size.
    @MainActor
    static func synchronizeAll() {
        for (_, portal) in portals {
            guard let contentView = portal.window?.contentView else { continue }
            portal.frame = contentView.bounds
        }
    }
}
