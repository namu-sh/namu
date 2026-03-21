import AppKit

// MARK: - AppDelegate

final class AppDelegate: NSObject, NSApplicationDelegate {

    // The single GhosttyApp instance for the process lifetime.
    // Created in applicationDidFinishLaunching, freed on deinit via GhosttyApp.deinit.
    private(set) var ghosttyApp: GhosttyApp?

    // Local event monitor for app-level keyboard shortcuts.
    private var keyEventMonitor: Any?

    // Appearance observer token.
    private var appearanceObserver: NSKeyValueObservation?

    // Menu bar status item
    private var statusItem: NSStatusItem?

    // Services — injected after MosaicApp sets them up.
    // These are weak to avoid a retain cycle; they're owned by the SwiftUI environment.
    weak var workspaceManager: WorkspaceManager?
    weak var panelManager: PanelManager?

    // Centralised service container — set by ContentView.onAppear, owns IPC/persistence/AI.
    var serviceContainer: ServiceContainer?

    // Callback to toggle command palette — set by ContentView.
    var toggleCommandPalette: (() -> Void)?

    // Callback to toggle sidebar — set by ContentView.
    var toggleSidebar: (() -> Void)?

    // MARK: - Launch

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 1. Initialize Ghostty (ghostty_init + config + ghostty_app_new) via GhosttyApp.
        //    GhosttyApp.init() handles ghostty_init, config load, and ghostty_app_new.
        MosaicDebug.log("[Mosaic] AppDelegate: initializing GhosttyApp...")
        guard let app = GhosttyApp() else {
            // Ghostty failed to initialize — show an alert and quit gracefully.
            let alert = NSAlert()
            alert.messageText = "Mosaic could not start"
            alert.informativeText = "Ghostty initialization failed. Check Console for details."
            alert.alertStyle = .critical
            alert.addButton(withTitle: "Quit")
            alert.runModal()
            NSApp.terminate(nil)
            return
        }
        MosaicDebug.log("[Mosaic] GhosttyApp initialized successfully, shared=\(GhosttyApp.shared != nil)")
        ghosttyApp = app

        // 2. Set up menu bar status item
        setupStatusItem()

        // 3. Force dark appearance by default.
        NSApp.appearance = NSAppearance(named: .darkAqua)

        // 3. Push initial color scheme to Ghostty so it renders with the right palette.
        app.setColorScheme(.dark)

        // 4. Observe appearance changes (user overrides system appearance at runtime).
        appearanceObserver = NSApp.observe(\.effectiveAppearance, options: [.new]) { [weak app] _, _ in
            guard let app else { return }
            let isDark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            app.setColorScheme(isDark ? .dark : .light)
        }

        // 5. Local key event monitor — lets AppDelegate intercept app-wide shortcuts
        //    (e.g. Cmd+W to close, Cmd+, for settings) before they reach individual views.
        keyEventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            return self.handleLocalKeyEvent(event)
        }
    }

    // MARK: - Termination

    func applicationWillTerminate(_ notification: Notification) {
        // Stop all services (final session save, socket teardown, alert engine).
        serviceContainer?.stop()

        // Clean up the event monitor.
        if let monitor = keyEventMonitor {
            NSEvent.removeMonitor(monitor)
            keyEventMonitor = nil
        }
        appearanceObserver?.invalidate()
        appearanceObserver = nil
        // GhosttyApp.deinit calls ghostty_app_free and ghostty_config_free.
        ghosttyApp = nil
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    // MARK: - Focus

    func applicationDidBecomeActive(_ notification: Notification) {
        ghosttyApp?.setFocus(true)
    }

    func applicationDidResignActive(_ notification: Notification) {
        ghosttyApp?.setFocus(false)
    }

    // MARK: - Private helpers

    /// Handle app-wide local key events. Return nil to consume, event to pass through.
    /// NSEvent local monitors always run on the main thread, so MainActor.assumeIsolated is safe.
    @MainActor private func handleLocalKeyEvent(_ event: NSEvent) -> NSEvent? {
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let cmd = mods == .command
        let cmdShift = mods == [.command, .shift]
        let cmdOpt = mods == [.command, .option]

        // Cmd+K or Cmd+P → Command palette
        if cmd && (event.keyCode == 40 || event.keyCode == 35) {
            toggleCommandPalette?()
            return nil
        }

        // Cmd+B → Toggle sidebar
        if cmd && event.keyCode == 11 {
            toggleSidebar?()
            return nil
        }

        // Cmd+, → Open Settings
        if cmd && event.keyCode == 43 {
            NotificationCenter.default.post(name: .openSettings, object: nil)
            return nil
        }

        // Cmd+I → Toggle AI chat panel
        if cmd && event.keyCode == 34 {
            NotificationCenter.default.post(name: .toggleAIChat, object: nil)
            return nil
        }

        // Cmd+T → New workspace
        if cmd && event.keyCode == 17 {
            workspaceManager?.createWorkspace()
            return nil
        }

        // Cmd+D → Split horizontal
        if cmd && event.keyCode == 2 {
            panelManager?.splitFocusedPanel(direction: .horizontal)
            return nil
        }

        // Cmd+Shift+D → Split vertical
        if cmdShift && event.keyCode == 2 {
            panelManager?.splitFocusedPanel(direction: .vertical)
            return nil
        }

        // Cmd+W → Close pane (if last pane, let AppKit close the window)
        if cmd && event.keyCode == 13 {
            if let ws = workspaceManager?.selectedWorkspace, ws.panelCount <= 1 {
                return event
            }
            panelManager?.closeFocusedPanel()
            return nil
        }

        // Cmd+Shift+[ → Previous workspace
        if cmdShift && event.keyCode == 33 {
            selectAdjacentWorkspace(offset: -1)
            return nil
        }

        // Cmd+Shift+] → Next workspace
        if cmdShift && event.keyCode == 30 {
            selectAdjacentWorkspace(offset: 1)
            return nil
        }

        // Cmd+1…9 → Select workspace by index
        if cmd, let num = event.numericKey, num >= 1, num <= 9 {
            selectWorkspaceByIndex(num - 1)
            return nil
        }

        // Cmd+F → Find in terminal
        if cmd && event.keyCode == 3 {
            NotificationCenter.default.post(name: .toggleFindOverlay, object: nil)
            return nil
        }

        // Cmd+N → New window (handled by WindowGroup automatically)
        // keyCode 45 = N — let AppKit handle it for WindowGroup

        // Cmd+Option+Arrow → Focus adjacent pane
        if cmdOpt {
            switch event.keyCode {
            case 123: panelManager?.focusDirection(.left);  return nil
            case 124: panelManager?.focusDirection(.right); return nil
            case 125: panelManager?.focusDirection(.down);  return nil
            case 126: panelManager?.focusDirection(.up);    return nil
            default: break
            }
        }

        return event
    }

    // MARK: - Workspace navigation helpers

    @MainActor private func selectAdjacentWorkspace(offset: Int) {
        guard let wm = workspaceManager else { return }
        guard let currentID = wm.selectedWorkspaceID,
              let idx = wm.workspaces.firstIndex(where: { $0.id == currentID }) else { return }
        let newIdx = idx + offset
        guard wm.workspaces.indices.contains(newIdx) else { return }
        NotificationCenter.default.post(
            name: .selectWorkspace,
            object: nil,
            userInfo: ["id": wm.workspaces[newIdx].id]
        )
    }

    @MainActor private func selectWorkspaceByIndex(_ index: Int) {
        guard let wm = workspaceManager else { return }
        guard wm.workspaces.indices.contains(index) else { return }
        NotificationCenter.default.post(
            name: .selectWorkspace,
            object: nil,
            userInfo: ["id": wm.workspaces[index].id]
        )
    }

    // MARK: - Menu Bar Status Item

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        guard let button = statusItem?.button else { return }
        button.image = NSImage(systemSymbolName: "terminal", accessibilityDescription: "Mosaic")
        button.image?.size = NSSize(width: 16, height: 16)
        button.action = #selector(statusItemClicked)
        button.target = self

        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Show Mosaic", action: #selector(showMainWindow), keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "New Workspace", action: #selector(newWorkspaceFromMenu), keyEquivalent: "t"))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit Mosaic", action: #selector(quitApp), keyEquivalent: "q"))
        statusItem?.menu = menu
    }

    @objc private func statusItemClicked() {
        showMainWindow()
    }

    @objc private func showMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        if let window = NSApp.windows.first(where: { $0.title == "Mosaic" || $0.isKeyWindow }) {
            window.makeKeyAndOrderFront(nil)
        } else {
            // If no window exists, open the main window
            for window in NSApp.windows {
                if !window.title.isEmpty {
                    window.makeKeyAndOrderFront(nil)
                    break
                }
            }
        }
    }

    @objc private func newWorkspaceFromMenu() {
        showMainWindow()
        DispatchQueue.main.async {
            self.workspaceManager?.createWorkspace()
        }
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }
}

// MARK: - NSEvent key helpers

private extension NSEvent {
    /// Returns 1–9 if the event is a numeric key (main keyboard row), else nil.
    var numericKey: Int? {
        // Key codes for 1–9 on the main keyboard row
        let map: [UInt16: Int] = [
            18: 1, 19: 2, 20: 3, 21: 4, 23: 5,
            22: 6, 26: 7, 28: 8, 25: 9
        ]
        return map[keyCode]
    }
}
