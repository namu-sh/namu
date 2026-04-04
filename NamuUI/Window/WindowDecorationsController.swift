import AppKit

/// Repositions traffic light buttons (close/minimize/zoom) to align with
/// the sidebar header. Uses the Tauri approach: resize the NSTitlebarContainerView
/// frame, then reposition buttons within it.
final class WindowDecorationsController {
    private var observers: [NSObjectProtocol] = []
    private var didStart = false
    private var burstTimer: Timer?

    /// Desired traffic light position (points from top-left of window content).
    var trafficLightPosition = NSPoint(x: 14, y: 14)

    func start() {
        guard !didStart else { return }
        didStart = true
        installObservers()
        // Delay initial apply to let SwiftUI finish window setup
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.applyToAllWindows()
        }
    }

    // MARK: - Public

    func apply(to window: NSWindow) {
        if shouldHideTrafficLights(for: window) {
            hideStandardButtons(window, hidden: true)
            return
        }
        hideStandardButtons(window, hidden: false)
        repositionTrafficLights(in: window)
    }

    // MARK: - Private

    private func installObservers() {
        let center = NotificationCenter.default
        let handler: (Notification) -> Void = { [weak self] notification in
            guard let self, let window = notification.object as? NSWindow else { return }
            // Delay slightly — macOS resets positions during layout
            DispatchQueue.main.async { [weak self] in
                self?.apply(to: window)
            }
        }
        for name in [
            NSWindow.didBecomeKeyNotification,
            NSWindow.didBecomeMainNotification,
            NSWindow.didResizeNotification,
            NSWindow.didEndLiveResizeNotification,
            NSWindow.didExitFullScreenNotification,
        ] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main, using: handler))
        }

        // Reapply after appearance/config change — macOS resets titlebar layout when theme switches.
        // Rapidly reapply for 0.5s to override macOS's layout resets during the transition.
        for name: Notification.Name in [
            .ghosttyConfigDidReload,
            NSApplication.didChangeScreenParametersNotification,
        ] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.reapplyBurst()
            })
        }
    }

    /// Rapidly reapply traffic light positions for 0.5s to override
    /// macOS's layout resets during appearance transitions.
    private func reapplyBurst() {
        burstTimer?.invalidate()
        var remaining = 10 // 10 ticks × 50ms = 0.5s
        applyToAllWindows()
        burstTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] timer in
            remaining -= 1
            self?.applyToAllWindows()
            if remaining <= 0 { timer.invalidate() }
        }
    }

    private func applyToAllWindows() {
        for window in NSApp.windows {
            apply(to: window)
        }
    }

    /// Core repositioning logic — resize the titlebar container, then move buttons.
    private func repositionTrafficLights(in window: NSWindow) {
        guard let closeButton = window.standardWindowButton(.closeButton),
              let titlebarContainerView = closeButton.superview?.superview else { return }

        let buttonHeight = closeButton.frame.height

        // Resize the titlebar container to accommodate the new Y position
        let containerHeight = buttonHeight + trafficLightPosition.y * 2
        var containerFrame = titlebarContainerView.frame
        containerFrame.size.height = containerHeight
        containerFrame.origin.y = window.frame.height - containerHeight
        titlebarContainerView.frame = containerFrame

        // Reposition each button within the container
        let buttons: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
        let spaceBetween: CGFloat = {
            guard let close = window.standardWindowButton(.closeButton),
                  let minimize = window.standardWindowButton(.miniaturizeButton) else { return 20 }
            return minimize.frame.origin.x - close.frame.origin.x
        }()

        for (i, type) in buttons.enumerated() {
            guard let button = window.standardWindowButton(type) else { continue }
            var btnFrame = button.frame
            btnFrame.origin.x = trafficLightPosition.x + CGFloat(i) * spaceBetween
            // Center vertically in the resized container's superview
            btnFrame.origin.y = (closeButton.superview!.frame.height - buttonHeight) / 2
            button.setFrameOrigin(btnFrame.origin)
        }
    }

    private func hideStandardButtons(_ window: NSWindow, hidden: Bool) {
        window.standardWindowButton(.closeButton)?.isHidden = hidden
        window.standardWindowButton(.miniaturizeButton)?.isHidden = hidden
        window.standardWindowButton(.zoomButton)?.isHidden = hidden
    }

    private func shouldHideTrafficLights(for window: NSWindow) -> Bool {
        if window.isSheet { return true }
        if window.styleMask.contains(.docModalWindow) { return true }
        if window.styleMask.contains(.nonactivatingPanel) { return true }
        return false
    }
}
