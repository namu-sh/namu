import SwiftUI
import AppKit

/// NSViewRepresentable that bridges a TerminalPanel's Ghostty surface into SwiftUI.
///
/// Returns the panel's persistent GhosttySurfaceView directly as the represented view.
/// With the ZStack visibility pattern in ContentView, SwiftUI never destroys these views
/// on tab switch — it only toggles opacity/hitTesting.
struct TerminalView: NSViewRepresentable {

    @ObservedObject var panel: TerminalPanel
    var onFocus: (() -> Void)? = nil
    var isActive: Bool = true

    func makeNSView(context: Context) -> GhosttySurfaceView {
        let surfaceView = panel.surfaceView
        surfaceView.onFocus = onFocus
        return surfaceView
    }

    func updateNSView(_ surfaceView: GhosttySurfaceView, context: Context) {
        surfaceView.onFocus = onFocus
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
                window.makeFirstResponder(surfaceView)
                MosaicDebug.log("[Mosaic] updateNSView: started session displayID=\(displayID)")
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
            // Don't call makeFirstResponder here — it steals focus from the
            // pane the user just clicked. mouseDown handles focus correctly.
        }
    }
}
