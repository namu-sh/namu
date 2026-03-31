import AppKit

final class WindowDecorationsController {
    private var observers: [NSObjectProtocol] = []
    private var didStart = false
    private var trafficLightBaseFrames: [ObjectIdentifier: [NSWindow.ButtonType: NSRect]] = [:]

    func start() {
        guard !didStart else { return }
        didStart = true
        attachToExistingWindows()
        installObservers()
    }

    func apply(to window: NSWindow) {
        let shouldHide = shouldHideTrafficLights(for: window)
        hideStandardButtons(window, hidden: shouldHide)
        applyTrafficLightOffset(window, hidden: shouldHide)
    }

    // MARK: - Public API

    func hideStandardButtons(_ window: NSWindow) {
        hideStandardButtons(window, hidden: true)
    }

    func showStandardButtons(_ window: NSWindow) {
        hideStandardButtons(window, hidden: false)
    }

    func applyTrafficLightOffset(_ window: NSWindow, x: CGFloat, y: CGFloat) {
        DispatchQueue.main.async { [weak self, weak window] in
            guard let self, let window else { return }
            self.applyTrafficLightOffsetNow(on: window, offset: NSPoint(x: x, y: y))
        }
    }

    // MARK: - Private

    private func installObservers() {
        let center = NotificationCenter.default
        let handler: (Notification) -> Void = { [weak self] notification in
            guard let self, let window = notification.object as? NSWindow else { return }
            self.apply(to: window)
        }
        observers.append(center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main, using: handler))
        observers.append(center.addObserver(forName: NSWindow.didBecomeMainNotification, object: nil, queue: .main, using: handler))
    }

    private func attachToExistingWindows() {
        for window in NSApp.windows {
            apply(to: window)
        }
    }

    private func hideStandardButtons(_ window: NSWindow, hidden: Bool) {
        window.standardWindowButton(.closeButton)?.isHidden = hidden
        window.standardWindowButton(.miniaturizeButton)?.isHidden = hidden
        window.standardWindowButton(.zoomButton)?.isHidden = hidden
    }

    private func applyTrafficLightOffset(_ window: NSWindow, hidden: Bool) {
        DispatchQueue.main.async { [weak self, weak window] in
            guard let self, let window else { return }
            let offset = hidden ? NSPoint.zero : self.trafficLightOffset(for: window)
            self.applyTrafficLightOffsetNow(on: window, offset: offset)
        }
    }

    private func applyTrafficLightOffsetNow(on window: NSWindow, offset: NSPoint) {
        let key = ObjectIdentifier(window)
        let buttonTypes: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
        var baseFrames = trafficLightBaseFrames[key] ?? [:]

        for type in buttonTypes {
            guard let button = window.standardWindowButton(type) else { continue }
            if baseFrames[type] == nil {
                baseFrames[type] = button.frame
            }
        }

        trafficLightBaseFrames[key] = baseFrames

        for type in buttonTypes {
            guard let button = window.standardWindowButton(type), let base = baseFrames[type] else { continue }
            button.setFrameOrigin(NSPoint(x: base.origin.x + offset.x, y: base.origin.y + offset.y))
        }
    }

    private func trafficLightOffset(for window: NSWindow) -> NSPoint {
        guard window.identifier?.rawValue == "namu.settings" else { return .zero }
        return NSPoint(x: 7, y: -4)
    }

    private func shouldHideTrafficLights(for window: NSWindow) -> Bool {
        if window.isSheet { return true }
        if window.styleMask.contains(.docModalWindow) { return true }
        if window.styleMask.contains(.nonactivatingPanel) { return true }
        return false
    }
}
