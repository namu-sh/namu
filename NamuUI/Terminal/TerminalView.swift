import SwiftUI
import AppKit

/// NSViewRepresentable that bridges a TerminalPanel's Ghostty surface into SwiftUI.
///
/// Returns the panel's persistent GhosttySurfaceView directly as the represented view.
/// With the ZStack visibility pattern in ContentView, SwiftUI never destroys these views
/// on tab switch — it only toggles opacity/hitTesting.
struct TerminalView: NSViewRepresentable {

    @ObservedObject var panel: TerminalPanel
    var onActivate: (() -> Void)? = nil
    var isActive: Bool = true
    var isKeyPane: Bool = false

    func makeNSView(context: Context) -> GhosttySurfaceView {
        let surfaceView = panel.surfaceView
        surfaceView.onActivate = onActivate
        return surfaceView
    }

    func updateNSView(_ surfaceView: GhosttySurfaceView, context: Context) {
        surfaceView.onActivate = onActivate
        surfaceView.isHidden = !isActive

        let session = panel.session

        // Start session if not alive yet and view is in a window.
        if !session.isAlive && isActive {
            if let window = surfaceView.window, let app = GhosttyApp.shared {
                let config = GhosttyConfig()
                config.loadDefaultFiles()
                config.loadRecursiveFiles()
                config.finalize()
                let displayID = window.screen?.displayID ?? 0
                session.start(
                    hostView: surfaceView,
                    displayID: displayID,
                    app: app,
                    config: config
                )
                session.setContentScale(window.backingScaleFactor)
                let backingSize = surfaceView.convertToBacking(surfaceView.bounds).size
                if backingSize.width > 0, backingSize.height > 0 {
                    session.resize(width: UInt32(backingSize.width), height: UInt32(backingSize.height))
                }
                session.refresh()
                NamuDebug.log("[Namu] updateNSView: started session displayID=\(displayID)")
            }
        }

        // Apply current frame size for active terminal.
        if session.isAlive && isActive {
            let size = surfaceView.bounds.size
            if size.width > 0, size.height > 0 {
                let backingSize = surfaceView.convertToBacking(surfaceView.bounds).size
                session.resize(width: UInt32(backingSize.width), height: UInt32(backingSize.height))
            }
            if let displayID = surfaceView.window?.screen?.displayID, displayID != 0 {
                session.setDisplayID(displayID)
            }
        }

        // Defer first responder changes out of the SwiftUI update cycle
        // to avoid re-render loops from focus change callbacks.
        let shouldFocus = isKeyPane && isActive && session.isAlive
        let wasFocused = context.coordinator.lastFocusedState
        context.coordinator.lastFocusedState = shouldFocus

        if shouldFocus && !wasFocused {
            DispatchQueue.main.async { [weak surfaceView] in
                guard let surfaceView, let window = surfaceView.window else { return }
                if window.firstResponder !== surfaceView {
                    window.makeFirstResponder(surfaceView)
                }
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    class Coordinator {
        var lastFocusedState: Bool = false
    }
}
