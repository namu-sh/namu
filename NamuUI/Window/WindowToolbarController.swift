import AppKit

/// Configures windows for transparent titlebar with fullSizeContentView.
/// No NSToolbar is created — all toolbar UI is rendered as custom SwiftUI views
/// inside the sidebar and content areas. This eliminates the toolbar gap between
/// the traffic lights and the content.
@MainActor
final class WindowToolbarController: NSObject {
    private var observers: [NSObjectProtocol] = []

    override init() {
        super.init()
    }

    deinit {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    func start() {
        configureExistingWindows()
        installObservers()
    }

    // MARK: - Private

    private func installObservers() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: NSWindow.didBecomeMainNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let window = notification.object as? NSWindow else { return }
            Task { @MainActor [weak self] in
                self?.configure(window)
            }
        })
    }

    private func configureExistingWindows() {
        for window in NSApp.windows {
            configure(window)
        }
    }

    private func configure(_ window: NSWindow) {
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.tabbingMode = .disallowed
        if !window.styleMask.contains(.fullSizeContentView) {
            window.styleMask.insert(.fullSizeContentView)
        }

        // Hide the NSTitlebarContainerView entirely — this eliminates the safe area
        // inset that SwiftUI uses for the titlebar, allowing content to extend to the
        // very top of the window. Same technique used by Ghostty's HiddenTitlebarTerminalWindow.
        if let themeFrame = window.contentView?.superview {
            for subview in themeFrame.subviews {
                if type(of: subview).description() == "NSTitlebarContainerView" {
                    subview.isHidden = true
                    break
                }
            }
        }
    }
}
