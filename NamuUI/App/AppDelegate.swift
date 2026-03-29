import AppKit
import SwiftUI

// MARK: - AppDelegate

final class AppDelegate: NSObject, NSApplicationDelegate {

    /// Shared accessor for ServiceContainer's window routing helper.
    static weak var shared: AppDelegate?

    // The single GhosttyApp instance for the process lifetime.
    // Created in applicationDidFinishLaunching, freed on deinit via GhosttyApp.deinit.
    private(set) var ghosttyApp: GhosttyApp?

    // Local event monitor for app-level keyboard shortcuts.
    private var keyEventMonitor: Any?

    // Appearance observer token.
    private var appearanceObserver: NSKeyValueObservation?

    // Menu bar status item
    private var statusItem: NSStatusItem?

    // Services — injected after NamuApp sets them up.
    // These are weak to avoid a retain cycle; they're owned by the SwiftUI environment.
    weak var workspaceManager: WorkspaceManager?
    weak var panelManager: PanelManager?

    // Centralised service container — set by ContentView.onAppear, owns IPC/persistence/AI.
    var serviceContainer: ServiceContainer?

    // Callback to toggle command palette — set by ContentView.
    var toggleCommandPalette: (() -> Void)?

    // Callback to toggle sidebar — set by ContentView.
    var toggleSidebar: (() -> Void)?

    // MARK: - Multi-window state

    /// All live window contexts keyed by windowID.
    var windowContexts: [UUID: WindowContext] = [:]

    /// The most-recently-activated window context (for IPC fallback when no surface_id given).
    private(set) var keyWindowContext: WindowContext?

    // MARK: - Launch

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppDelegate.shared = self

        // 0. Clean inherited env vars and set Namu identity for child shells.
        unsetenv("CLAUDECODE")
        unsetenv("CLAUDE_CODE")
        setenv("TERM_PROGRAM", "Namu", 1)
        setenv("NAMU", "1", 1)
        // Pre-set socket path so initial terminal panes inherit it.
        // ServiceContainer.start() will overwrite with the actual path if different.
        setenv("NAMU_SOCKET", "/tmp/namu.sock", 1)

        // Prepend Resources/bin to PATH at process level so all terminals
        // get the claude wrapper and namu CLI automatically.
        if let binPath = Bundle.main.resourceURL?.appendingPathComponent("bin").path {
            let currentPath = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"
            if !currentPath.split(separator: ":").contains(Substring(binPath)) {
                setenv("PATH", "\(binPath):\(currentPath)", 1)
            }
        }

        // 1. Initialize Ghostty (ghostty_init + config + ghostty_app_new) via GhosttyApp.
        //    GhosttyApp.init() handles ghostty_init, config load, and ghostty_app_new.
        NamuDebug.log("[Namu] AppDelegate: initializing GhosttyApp...")
        guard let app = GhosttyApp() else {
            // Ghostty failed to initialize — show an alert and quit gracefully.
            let alert = NSAlert()
            alert.messageText = "Namu could not start"
            alert.informativeText = "Ghostty initialization failed. Check Console for details."
            alert.alertStyle = .critical
            alert.addButton(withTitle: "Quit")
            alert.runModal()
            NSApp.terminate(nil)
            return
        }
        NamuDebug.log("[Namu] GhosttyApp initialized successfully, shared=\(GhosttyApp.shared != nil)")
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
        // Capture window frame before the final session save.
        if let window = NSApp.windows.first(where: { $0.identifier?.rawValue == "namu-primary" }) ?? NSApp.windows.first(where: { $0.isKeyWindow }),
           let sc = serviceContainer {
            sc.sessionPersistence.primaryWindowFrame = window.frame
        }

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

        // Cmd+T → New workspace (create AND select so the shell starts)
        if cmd && event.keyCode == 17 {
            if let ws = workspaceManager?.createWorkspace() {
                workspaceManager?.selectWorkspace(id: ws.id)
            }
            return nil
        }

        // Cmd+D → Split horizontal
        if cmd && event.keyCode == 2 {
            panelManager?.splitActivePanel(direction: .horizontal)
            return nil
        }

        // Cmd+Shift+D → Split vertical
        if cmdShift && event.keyCode == 2 {
            panelManager?.splitActivePanel(direction: .vertical)
            return nil
        }

        // Cmd+W → Close pane (if last pane, let AppKit close the window)
        if cmd && event.keyCode == 13 {
            if let ws = workspaceManager?.selectedWorkspace, ws.panelCount <= 1 {
                return event
            }
            closePanelWithConfirmation()
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

        // Ctrl+Tab → Next workspace
        if mods == .control && event.keyCode == 48 {
            selectAdjacentWorkspace(offset: 1)
            return nil
        }

        // Ctrl+Shift+Tab → Previous workspace
        if mods == [.control, .shift] && event.keyCode == 48 {
            selectAdjacentWorkspace(offset: -1)
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

        // Cmd+Shift+N → New window
        if cmdShift && event.keyCode == 45 {
            createMainWindow()
            return nil
        }

        // Cmd+N → New window (handled by WindowGroup automatically)
        // keyCode 45 = N — let AppKit handle it for WindowGroup

        // Cmd+Option+Arrow → Focus adjacent pane
        if cmdOpt {
            switch event.keyCode {
            case 123: panelManager?.activateDirection(.left);  return nil
            case 124: panelManager?.activateDirection(.right); return nil
            case 125: panelManager?.activateDirection(.down);  return nil
            case 126: panelManager?.activateDirection(.up);    return nil
            default: break
            }
        }

        return event
    }

    // MARK: - Close with confirmation

    /// Close the active panel, showing a confirmation alert if a process is running
    /// or the workspace is pinned.
    @MainActor func closePanelWithConfirmation() {
        guard let pm = panelManager, let wm = workspaceManager else { return }
        guard let ws = wm.selectedWorkspace else { return }
        guard let activeID = ws.activePanelID else { return }

        let needsConfirmation = ws.isPinned || pm.isProcessRunning(id: activeID)
        guard needsConfirmation else {
            pm.closeActivePanel()
            return
        }

        let alert = NSAlert()
        alert.messageText = String(
            localized: "close.confirmation.title",
            defaultValue: "Process is running"
        )
        alert.informativeText = String(
            localized: "close.confirmation.body",
            defaultValue: "A process is running in this pane. Close anyway?"
        )
        alert.addButton(withTitle: String(
            localized: "close.confirmation.close",
            defaultValue: "Close"
        ))
        alert.addButton(withTitle: String(
            localized: "close.confirmation.cancel",
            defaultValue: "Cancel"
        ))
        alert.alertStyle = .warning

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            pm.closeActivePanel()
        }
    }

    // MARK: - Workspace navigation helpers

    @MainActor private func selectAdjacentWorkspace(offset: Int) {
        guard let wm = workspaceManager else { return }
        guard let currentID = wm.selectedWorkspaceID,
              let idx = wm.workspaces.firstIndex(where: { $0.id == currentID }) else { return }
        let count = wm.workspaces.count
        guard count > 0 else { return }
        let newIdx = (idx + offset + count) % count
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

    // MARK: - Multi-window management

    /// Register a window and its associated context. Called from ContentView.onAppear for each new window.
    @MainActor func registerMainWindow(window: NSWindow, context: WindowContext) {
        windowContexts[context.windowID] = context
        serviceContainer?.sessionPersistence.additionalWindowContexts = Array(windowContexts.values)
        NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: window,
            queue: .main
        ) { [weak self, weak window] _ in
            guard let self, let _ = window else { return }
            self.keyWindowContext = context
        }
    }

    /// Unregister a window context when its window closes.
    @MainActor func unregisterWindowContext(windowID: UUID) {
        windowContexts.removeValue(forKey: windowID)
        if keyWindowContext?.windowID == windowID {
            keyWindowContext = nil
        }
        serviceContainer?.sessionPersistence.additionalWindowContexts = Array(windowContexts.values)
    }

    /// Open a new Namu window with its own WorkspaceManager and PanelManager.
    @discardableResult
    @MainActor func createMainWindow() -> NSWindow {
        let windowID = UUID()
        let wm = WorkspaceManager()
        let pm = PanelManager(workspaceManager: wm)
        let context = WindowContext(windowID: windowID, workspaceManager: wm, panelManager: pm)

        let contentView = ContentView(appDelegate: self, windowContext: context)
        let hostingController = NSHostingController(rootView: contentView)

        let window = NSWindow(contentViewController: hostingController)
        window.title = "Namu"
        window.setContentSize(NSSize(width: 900, height: 600))
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.toolbarStyle = .unifiedCompact
        window.setFrameAutosaveName("NamuWindow-\(windowID.uuidString)")
        window.makeKeyAndOrderFront(nil)

        registerMainWindow(window: window, context: context)
        return window
    }

    /// Find the WorkspaceManager that owns a workspace ID.
    @MainActor private func findSourceManager(for workspaceId: UUID) -> WorkspaceManager? {
        // Check primary window first
        if let wm = workspaceManager, wm.workspaces.contains(where: { $0.id == workspaceId }) {
            return wm
        }
        // Check secondary windows
        for ctx in windowContexts.values {
            if ctx.workspaceManager.workspaces.contains(where: { $0.id == workspaceId }) {
                return ctx.workspaceManager
            }
        }
        return nil
    }

    /// Move a workspace by ID into a new window.
    @MainActor func moveWorkspaceToNewWindow(workspaceId: UUID) {
        guard let sourceWm = findSourceManager(for: workspaceId),
              let idx = sourceWm.workspaces.firstIndex(where: { $0.id == workspaceId }),
              sourceWm.workspaces.count > 1 else { return }

        let workspace = sourceWm.workspaces[idx]
        sourceWm.deleteWorkspace(id: workspaceId)

        let window = createMainWindow()
        // Find the context we just created and add the workspace
        if let ctx = windowContexts.values.first(where: { $0.workspaceManager.workspaces.count == 1 && $0.workspaceManager !== sourceWm }) {
            ctx.workspaceManager.workspaces = [workspace]
            ctx.workspaceManager.selectedWorkspaceID = workspace.id
        }
        window.makeKeyAndOrderFront(nil)
    }

    /// Move a workspace by ID to an existing window.
    @MainActor func moveWorkspaceToWindow(workspaceId: UUID, targetWindowId: UUID) {
        guard let sourceWm = findSourceManager(for: workspaceId),
              let idx = sourceWm.workspaces.firstIndex(where: { $0.id == workspaceId }),
              sourceWm.workspaces.count > 1,
              let targetCtx = windowContexts[targetWindowId] else { return }

        let workspace = sourceWm.workspaces[idx]
        sourceWm.deleteWorkspace(id: workspaceId)
        targetCtx.workspaceManager.workspaces.append(workspace)
        targetCtx.workspaceManager.selectedWorkspaceID = workspace.id
    }

    // MARK: - Menu Bar Status Item

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        guard let button = statusItem?.button else { return }
        button.image = NSImage(systemSymbolName: "terminal", accessibilityDescription: "Namu")
        button.image?.size = NSSize(width: 16, height: 16)
        button.action = #selector(statusItemClicked)
        button.target = self

        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Show Namu", action: #selector(showMainWindow), keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "New Workspace", action: #selector(newWorkspaceFromMenu), keyEquivalent: "t"))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit Namu", action: #selector(quitApp), keyEquivalent: "q"))
        statusItem?.menu = menu
    }

    @objc private func statusItemClicked() {
        showMainWindow()
    }

    @objc private func showMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        if let window = NSApp.windows.first(where: { $0.identifier?.rawValue == "namu-primary" }) ?? NSApp.windows.first(where: { $0.isKeyWindow }) {
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
