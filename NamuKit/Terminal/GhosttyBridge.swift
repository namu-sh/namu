import AppKit
import Bonsplit

// MARK: - Notifications

extension Notification.Name {
    static let ghosttyConfigDidReload = Notification.Name("xyz.omlabs.namu.ghosttyConfigDidReload")
    static let ghosttySurfaceDidClose = Notification.Name("xyz.omlabs.namu.ghosttySurfaceDidClose")
    static let ghosttyBellDidRing = Notification.Name("xyz.omlabs.namu.ghosttyBellDidRing")
    static let ghosttyTitleDidChange = Notification.Name("xyz.omlabs.namu.ghosttyTitleDidChange")
    static let ghosttyPwdDidChange = Notification.Name("xyz.omlabs.namu.ghosttyPwdDidChange")
    static let ghosttyColorSchemeDidChange = Notification.Name("xyz.omlabs.namu.ghosttyColorSchemeDidChange")
    static let namuNotificationCreated = Notification.Name("xyz.omlabs.namu.notificationCreated")
    static let namuTerminalNotification = Notification.Name("xyz.omlabs.namu.terminalNotification")
    static let namuPaneAttentionRequested = Notification.Name("xyz.omlabs.namu.paneAttentionRequested")
    static let namuWorkspaceAutoReorderRequested = Notification.Name("xyz.omlabs.namu.workspaceAutoReorderRequested")
    static let namuWorkspaceDidDelete = Notification.Name("xyz.omlabs.namu.workspaceDidDelete")
    // Search/find overlay
    static let namuSearchStarted = Notification.Name("xyz.omlabs.namu.searchStarted")
    static let namuSearchEnded = Notification.Name("xyz.omlabs.namu.searchEnded")
    static let namuSearchTotalUpdated = Notification.Name("xyz.omlabs.namu.searchTotalUpdated")
    static let namuSearchSelectedUpdated = Notification.Name("xyz.omlabs.namu.searchSelectedUpdated")
    // Cell size / scrollbar / key UI
    static let namuCellSizeUpdated = Notification.Name("xyz.omlabs.namu.cellSizeUpdated")
    static let namuScrollbarUpdated = Notification.Name("xyz.omlabs.namu.scrollbarUpdated")
    static let namuKeySequenceUpdated = Notification.Name("xyz.omlabs.namu.keySequenceUpdated")
    static let namuKeyTableUpdated = Notification.Name("xyz.omlabs.namu.keyTableUpdated")
    // Zoom portal reconciliation — posted after zoom state changes so terminal portal
    // views can reconcile their visibility. userInfo: ["panelID": UUID, "isZoomed": Bool]
    static let namuTerminalPortalReconcile = Notification.Name("xyz.omlabs.namu.terminalPortalReconcile")
}

// MARK: - GhosttyColorScheme

enum GhosttyColorScheme {
    case light, dark
}

// MARK: - GhosttyApp

/// Wraps `ghostty_app_t` lifetime and wires the runtime callbacks.
/// One instance per process. Initialized once in AppDelegate.
final class GhosttyApp {

    // MARK: - Shared

    private(set) static var shared: GhosttyApp?

    // MARK: - State

    private(set) var app: ghostty_app_t?
    private(set) var config: ghostty_config_t?

    // Task 4.7: Retain NSSound until playback completes so custom bell audio is
    // not cut short when the local variable in ringBell() goes out of scope.
    private var bellAudioSound: NSSound?

    // MARK: - Init

    /// Initialize the Ghostty library, load config, and create ghostty_app_t.
    /// Returns nil if Ghostty initialization fails hard.
    init?() {
        // ghostty_init must be called once before anything else.
        let result = ghostty_init(UInt(CommandLine.argc), CommandLine.unsafeArgv)
        guard result == GHOSTTY_SUCCESS else {
            print("[GhosttyApp] ghostty_init failed: \(result)")
            return nil
        }

        // Load primary config.
        guard let primaryConfig = ghostty_config_new() else {
            print("[GhosttyApp] ghostty_config_new failed")
            return nil
        }

        ghostty_config_load_default_files(primaryConfig)
        ghostty_config_load_recursive_files(primaryConfig)
        ghostty_config_finalize(primaryConfig)

        // Build runtime callbacks.
        var runtimeConfig = ghostty_runtime_config_s()
        runtimeConfig.userdata = nil  // not used by app-level callbacks
        runtimeConfig.supports_selection_clipboard = true

        runtimeConfig.wakeup_cb = { _ in
            DispatchQueue.main.async {
                GhosttyApp.shared?.tick()
            }
        }

        runtimeConfig.action_cb = { app, target, action in
            return GhosttyApp.shared?.handleAction(target: target, action: action) ?? false
        }

        runtimeConfig.read_clipboard_cb = { userdata, location, state in
            guard let surface = GhosttyApp.callbackSurface(from: userdata) else { return }
            let value = GhosttyPasteboard.read(from: location) ?? ""
            value.withCString { ptr in
                ghostty_surface_complete_clipboard_request(surface, ptr, state, false)
            }
        }

        runtimeConfig.confirm_read_clipboard_cb = { userdata, content, state, _ in
            guard let content,
                  let surface = GhosttyApp.callbackSurface(from: userdata) else { return }
            ghostty_surface_complete_clipboard_request(surface, content, state, true)
        }

        runtimeConfig.write_clipboard_cb = { _, location, content, len, _ in
            guard let content, len > 0 else { return }
            let buffer = UnsafeBufferPointer(start: content, count: Int(len))
            var fallback: String?
            for item in buffer {
                guard let dataPtr = item.data else { continue }
                let value = String(cString: dataPtr)
                if let mimePtr = item.mime {
                    let mime = String(cString: mimePtr)
                    if mime.hasPrefix("text/plain") {
                        GhosttyPasteboard.write(value, to: location)
                        return
                    }
                }
                if fallback == nil { fallback = value }
            }
            if let fallback { GhosttyPasteboard.write(fallback, to: location) }
        }

        runtimeConfig.close_surface_cb = { userdata, _ in
            // Surface userdata holds the surface pointer itself via the view association.
            // Notify observers — TerminalSession observes this to update its state.
            DispatchQueue.main.async {
                NotificationCenter.default.post(
                    name: .ghosttySurfaceDidClose,
                    object: nil,
                    userInfo: userdata.map { ["userdata": $0] }
                )
            }
        }

        // Try primary config first, fall back to bare config on failure.
        if let created = ghostty_app_new(&runtimeConfig, primaryConfig) {
            self.app = created
            self.config = primaryConfig
        } else {
            ghostty_config_free(primaryConfig)
            guard let fallbackConfig = ghostty_config_new() else {
                print("[GhosttyApp] ghostty_config_new (fallback) failed")
                return nil
            }
            ghostty_config_finalize(fallbackConfig)
            guard let created = ghostty_app_new(&runtimeConfig, fallbackConfig) else {
                print("[GhosttyApp] ghostty_app_new (fallback) failed")
                ghostty_config_free(fallbackConfig)
                return nil
            }
            self.app = created
            self.config = fallbackConfig
        }

        GhosttyApp.shared = self
    }

    deinit {
        if let app { ghostty_app_free(app) }
        if let config { ghostty_config_free(config) }
    }

    // MARK: - App-level API

    func tick() {
        guard let app else { return }
        ghostty_app_tick(app)
    }

    func setFocus(_ focused: Bool) {
        guard let app else { return }
        ghostty_app_set_focus(app, focused)
    }

    func updateConfig(_ config: ghostty_config_t) {
        guard let app else { return }
        ghostty_app_update_config(app, config)
        NotificationCenter.default.post(name: .ghosttyConfigDidReload, object: nil)
    }

    /// Ring the bell according to current config bell-features.
    func ringBell() {
        // Load a fresh GhosttyConfig to read the current bell settings.
        // Using the app-level config handle avoids creating a separate config object.
        guard let configHandle = config else {
            NSSound.beep()
            return
        }

        let cfg = GhosttyConfigReader(configHandle)
        let features = cfg.bellFeatures

        // bit 0: system beep
        if (features & (1 << 0)) != 0 || features == 0 {
            NSSound.beep()
        }

        // bit 1: custom audio file — retain sound as a property so playback is not
        // cut short when the local variable goes out of scope before audio finishes.
        if (features & (1 << 1)) != 0,
           let path = cfg.bellAudioPath,
           let sound = NSSound(contentsOfFile: path, byReference: false) {
            sound.volume = cfg.bellAudioVolume
            bellAudioSound = sound
            sound.play()
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
                self?.bellAudioSound = nil
            }
        }

        // bit 2: dock bounce
        if (features & (1 << 2)) != 0 {
            NSApp.requestUserAttention(.informationalRequest)
        }
    }

    func setColorScheme(_ scheme: GhosttyColorScheme) {
        guard let app else { return }
        let c: ghostty_color_scheme_e = scheme == .dark
            ? GHOSTTY_COLOR_SCHEME_DARK
            : GHOSTTY_COLOR_SCHEME_LIGHT
        ghostty_app_set_color_scheme(app, c)
    }

    // MARK: - Callback helper

    /// Recover the ghostty_surface_t from the `userdata` pointer stored in
    /// close_surface_cb / read_clipboard_cb.  The surface view stores itself
    /// as userdata so we can cast back here.
    static func callbackSurface(from userdata: UnsafeMutableRawPointer?) -> ghostty_surface_t? {
        guard let userdata else { return nil }
        let session = Unmanaged<TerminalSession>.fromOpaque(userdata).takeUnretainedValue()
        return session.surface
    }

    // MARK: - Action handler

    @discardableResult
    func handleAction(target: ghostty_target_s, action: ghostty_action_s) -> Bool {
        switch action.tag {

        case GHOSTTY_ACTION_RING_BELL:
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .ghosttyBellDidRing, object: nil)
                GhosttyApp.shared?.ringBell()
            }
            return true

        case GHOSTTY_ACTION_RELOAD_CONFIG:
            let soft = action.action.reload_config.soft
            if soft {
                // Soft reload: re-apply existing config without reloading from disk.
                DispatchQueue.main.async { [weak self] in
                    guard let self, let app = self.app, let config = self.config else { return }
                    NamuDebug.log("[Namu] Config soft reload")
                    ghostty_app_update_config(app, config)
                    NotificationCenter.default.post(name: .ghosttyConfigDidReload, object: nil)
                }
            } else {
                DispatchQueue.main.async { self.reloadConfig() }
            }
            return true

        case GHOSTTY_ACTION_CONFIG_CHANGE:
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .ghosttyConfigDidReload, object: nil)
            }
            return true

        case GHOSTTY_ACTION_COLOR_CHANGE:
            DispatchQueue.main.async {
                NotificationCenter.default.post(
                    name: .ghosttyColorSchemeDidChange,
                    object: nil
                )
            }
            return true

        case GHOSTTY_ACTION_SET_TITLE:
            if let ptr = action.action.set_title.title {
                let title = String(cString: ptr)
                // Extract surface pointer from target for per-session routing.
                let surfacePtr: ghostty_surface_t? = {
                    if target.tag == GHOSTTY_TARGET_SURFACE {
                        return target.target.surface
                    }
                    return nil
                }()
                DispatchQueue.main.async {
                    var info: [String: Any] = ["title": title]
                    if let s = surfacePtr {
                        info["surface"] = s
                    }
                    NotificationCenter.default.post(
                        name: .ghosttyTitleDidChange,
                        object: nil,
                        userInfo: info
                    )
                }
            }
            return true

        case GHOSTTY_ACTION_PWD:
            if let ptr = action.action.pwd.pwd {
                let pwd = String(cString: ptr)
                DispatchQueue.main.async {
                    NotificationCenter.default.post(
                        name: .ghosttyPwdDidChange,
                        object: nil,
                        userInfo: ["pwd": pwd]
                    )
                }
            }
            return true

        case GHOSTTY_ACTION_DESKTOP_NOTIFICATION:
            let title = action.action.desktop_notification.title
                .flatMap { String(cString: $0) } ?? ""
            let body = action.action.desktop_notification.body
                .flatMap { String(cString: $0) } ?? ""
            // Extract surface pointer to identify which pane sent the notification.
            let surfacePtr: UnsafeMutableRawPointer? = {
                if target.tag == GHOSTTY_TARGET_SURFACE { return target.target.surface }
                return nil
            }()
            DispatchQueue.main.async {
                // Post terminal notification with surface info.
                // The UI layer suppresses this for panes with active Claude sessions.
                NotificationCenter.default.post(
                    name: .namuTerminalNotification,
                    object: nil,
                    userInfo: [
                        "title": title,
                        "body": body,
                        "surface": surfacePtr as Any
                    ]
                )
            }
            return true

        case GHOSTTY_ACTION_OPEN_URL:
            if let urlPtr = action.action.open_url.url {
                let urlString = String(cString: urlPtr)
                DispatchQueue.main.async {
                    if let url = URL(string: urlString) {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
            return true

        case GHOSTTY_ACTION_OPEN_CONFIG:
            DispatchQueue.main.async {
                let pathStr = ghostty_config_open_path()
                defer { ghostty_string_free(pathStr) }
                if pathStr.len > 0, let ptr = pathStr.ptr {
                    let path = String(cString: ptr)
                    NSWorkspace.shared.open(URL(fileURLWithPath: path))
                }
            }
            return true

        case GHOSTTY_ACTION_QUIT:
            DispatchQueue.main.async { NSApp.terminate(nil) }
            return true

        // MARK: - Task 2.1: Split action handlers

        case GHOSTTY_ACTION_NEW_SPLIT:
            let direction = splitDirection(from: action.action.new_split)
            DispatchQueue.main.async {
                AppDelegate.shared?.panelManager?.splitActivePanel(direction: direction)
            }
            return true

        case GHOSTTY_ACTION_GOTO_SPLIT:
            let gotoDir = action.action.goto_split
            DispatchQueue.main.async {
                let pm = AppDelegate.shared?.panelManager
                switch gotoDir {
                case GHOSTTY_GOTO_SPLIT_PREVIOUS:
                    pm?.activatePrevious()
                case GHOSTTY_GOTO_SPLIT_NEXT:
                    pm?.activateNext()
                default:
                    if let direction = navigationDirection(from: gotoDir) {
                        pm?.activateDirection(direction)
                    }
                }
            }
            return true

        case GHOSTTY_ACTION_RESIZE_SPLIT:
            let resizeDir = action.action.resize_split.direction
            let amount = action.action.resize_split.amount
            DispatchQueue.main.async {
                guard let pm = AppDelegate.shared?.panelManager,
                      let wsID = AppDelegate.shared?.workspaceManager?.selectedWorkspaceID else { return }
                let eng = pm.engine(for: wsID)
                guard let focusedPane = eng.focusedPaneID else { return }
                let focusedPaneStr = focusedPane.description
                let tree = eng.treeSnapshot()
                // Determine which split orientation to look for based on direction.
                // LEFT/RIGHT resize the horizontal divider; UP/DOWN resize the vertical divider.
                let targetOrientation: String
                let delta: CGFloat
                switch resizeDir {
                case GHOSTTY_RESIZE_SPLIT_LEFT:
                    targetOrientation = "horizontal"
                    delta = -CGFloat(amount) / 200.0
                case GHOSTTY_RESIZE_SPLIT_RIGHT:
                    targetOrientation = "horizontal"
                    delta = CGFloat(amount) / 200.0
                case GHOSTTY_RESIZE_SPLIT_UP:
                    targetOrientation = "vertical"
                    delta = -CGFloat(amount) / 200.0
                case GHOSTTY_RESIZE_SPLIT_DOWN:
                    targetOrientation = "vertical"
                    delta = CGFloat(amount) / 200.0
                default:
                    return
                }
                // Walk the tree to find the nearest ancestor split of the target
                // orientation that contains the focused pane.
                if let (splitID, currentRatio) = nearestSplit(
                    in: tree,
                    containingPane: focusedPaneStr,
                    orientation: targetOrientation
                ), let splitUUID = UUID(uuidString: splitID) {
                    let newRatio = min(0.95, max(0.05, currentRatio + Double(delta)))
                    pm.resizeSplit(in: wsID, splitID: splitUUID, ratio: newRatio)
                }
            }
            return true

        case GHOSTTY_ACTION_EQUALIZE_SPLITS:
            DispatchQueue.main.async {
                guard let pm = AppDelegate.shared?.panelManager,
                      let wsID = AppDelegate.shared?.workspaceManager?.selectedWorkspaceID else { return }
                let eng = pm.engine(for: wsID)
                let tree = eng.treeSnapshot()
                for (splitIDStr, _) in allSplits(in: tree) {
                    if let splitUUID = UUID(uuidString: splitIDStr) {
                        pm.resizeSplit(in: wsID, splitID: splitUUID, ratio: 0.5)
                    }
                }
            }
            return true

        case GHOSTTY_ACTION_TOGGLE_SPLIT_ZOOM:
            DispatchQueue.main.async {
                guard let pm = AppDelegate.shared?.panelManager,
                      let wsID = AppDelegate.shared?.workspaceManager?.selectedWorkspaceID else { return }
                pm.toggleZoom(in: wsID)
            }
            return true

        // MARK: - Task 2.2: Find/search action handlers

        case GHOSTTY_ACTION_START_SEARCH:
            let needle = action.action.start_search.needle.flatMap { String(cString: $0) } ?? ""
            let surfaceUD: UnsafeMutableRawPointer? = target.tag == GHOSTTY_TARGET_SURFACE
                ? ghostty_surface_userdata(target.target.surface)
                : nil
            DispatchQueue.main.async {
                let panel = surfaceUD.flatMap { GhosttyApp.panel(fromUserdata: $0) }
                if let panel {
                    if panel.searchState != nil {
                        if !needle.isEmpty { panel.searchState?.needle = needle }
                    } else {
                        panel.searchState = SearchState(needle: needle)
                    }
                }
                NotificationCenter.default.post(
                    name: .namuSearchStarted,
                    object: nil,
                    userInfo: surfaceUD.map { ["userdata": $0] }
                )
            }
            return true

        case GHOSTTY_ACTION_END_SEARCH:
            let surfaceUDEnd: UnsafeMutableRawPointer? = target.tag == GHOSTTY_TARGET_SURFACE
                ? ghostty_surface_userdata(target.target.surface)
                : nil
            DispatchQueue.main.async {
                let panel = surfaceUDEnd.flatMap { GhosttyApp.panel(fromUserdata: $0) }
                panel?.searchState = nil
                NotificationCenter.default.post(
                    name: .namuSearchEnded,
                    object: nil,
                    userInfo: surfaceUDEnd.map { ["userdata": $0] }
                )
            }
            return true

        case GHOSTTY_ACTION_SEARCH_TOTAL:
            let rawTotal = action.action.search_total.total
            let total: UInt? = rawTotal >= 0 ? UInt(rawTotal) : nil
            let surfaceUDTotal: UnsafeMutableRawPointer? = target.tag == GHOSTTY_TARGET_SURFACE
                ? ghostty_surface_userdata(target.target.surface)
                : nil
            DispatchQueue.main.async {
                let panel = surfaceUDTotal.flatMap { GhosttyApp.panel(fromUserdata: $0) }
                panel?.searchState?.total = total
                NotificationCenter.default.post(
                    name: .namuSearchTotalUpdated,
                    object: nil,
                    userInfo: surfaceUDTotal.map { ["userdata": $0] }
                )
            }
            return true

        case GHOSTTY_ACTION_SEARCH_SELECTED:
            let rawSelected = action.action.search_selected.selected
            let selected: UInt? = rawSelected >= 0 ? UInt(rawSelected) : nil
            let surfaceUDSel: UnsafeMutableRawPointer? = target.tag == GHOSTTY_TARGET_SURFACE
                ? ghostty_surface_userdata(target.target.surface)
                : nil
            DispatchQueue.main.async {
                let panel = surfaceUDSel.flatMap { GhosttyApp.panel(fromUserdata: $0) }
                panel?.searchState?.selected = selected
                NotificationCenter.default.post(
                    name: .namuSearchSelectedUpdated,
                    object: nil,
                    userInfo: surfaceUDSel.map { ["userdata": $0] }
                )
            }
            return true

        // MARK: - Task 2.3: Utility action handlers

        case GHOSTTY_ACTION_CELL_SIZE:
            let cellW = CGFloat(action.action.cell_size.width)
            let cellH = CGFloat(action.action.cell_size.height)
            let surfaceUDCell: UnsafeMutableRawPointer? = target.tag == GHOSTTY_TARGET_SURFACE
                ? ghostty_surface_userdata(target.target.surface)
                : nil
            DispatchQueue.main.async {
                let panel = surfaceUDCell.flatMap { GhosttyApp.panel(fromUserdata: $0) }
                panel?.cellSize = CGSize(width: cellW, height: cellH)
                NotificationCenter.default.post(
                    name: .namuCellSizeUpdated,
                    object: nil,
                    userInfo: surfaceUDCell.map { ["userdata": $0] }
                )
            }
            return true

        case GHOSTTY_ACTION_SCROLLBAR:
            let sbTotal = action.action.scrollbar.total
            let sbOffset = action.action.scrollbar.offset
            let sbLen = action.action.scrollbar.len
            let surfaceUDSB: UnsafeMutableRawPointer? = target.tag == GHOSTTY_TARGET_SURFACE
                ? ghostty_surface_userdata(target.target.surface)
                : nil
            DispatchQueue.main.async {
                let panel = surfaceUDSB.flatMap { GhosttyApp.panel(fromUserdata: $0) }
                panel?.scrollbarState = ScrollbarState(total: sbTotal, offset: sbOffset, length: sbLen)
                NotificationCenter.default.post(
                    name: .namuScrollbarUpdated,
                    object: nil,
                    userInfo: surfaceUDSB.map { ["userdata": $0] }
                )
            }
            return true

        case GHOSTTY_ACTION_KEY_SEQUENCE:
            let isActive = action.action.key_sequence.active
            let surfaceUDKS: UnsafeMutableRawPointer? = target.tag == GHOSTTY_TARGET_SURFACE
                ? ghostty_surface_userdata(target.target.surface)
                : nil
            DispatchQueue.main.async {
                NotificationCenter.default.post(
                    name: .namuKeySequenceUpdated,
                    object: nil,
                    userInfo: (surfaceUDKS.map { ["userdata": $0, "active": isActive] })
                        ?? ["active": isActive]
                )
            }
            return true

        case GHOSTTY_ACTION_KEY_TABLE:
            let ktTag = action.action.key_table.tag
            var ktName: String? = nil
            if ktTag == GHOSTTY_KEY_TABLE_ACTIVATE,
               let namePtr = action.action.key_table.value.activate.name {
                ktName = String(cString: namePtr)
            }
            let surfaceUDKT: UnsafeMutableRawPointer? = target.tag == GHOSTTY_TARGET_SURFACE
                ? ghostty_surface_userdata(target.target.surface)
                : nil
            DispatchQueue.main.async {
                var info: [String: Any] = ["tag": Int(ktTag.rawValue)]
                if let surfaceUD = surfaceUDKT { info["userdata"] = surfaceUD }
                if let name = ktName { info["name"] = name }
                NotificationCenter.default.post(name: .namuKeyTableUpdated, object: nil, userInfo: info)
            }
            return true

        case GHOSTTY_ACTION_SHOW_CHILD_EXITED:
            // The child shell exited. Close the pane immediately rather than
            // letting Ghostty print "Process exited. Press any key..." prompt.
            // Recover the TerminalSession via surface userdata and reuse the
            // existing ghosttySurfaceDidClose path that ServiceContainer handles.
            let surfacePtr: ghostty_surface_t? = {
                if target.tag == GHOSTTY_TARGET_SURFACE {
                    return target.target.surface
                }
                return nil
            }()
            if let surface = surfacePtr,
               let userdata = ghostty_surface_userdata(surface) {
                // Keep close async to avoid re-entrant surface free during the action callback.
                DispatchQueue.main.async {
                    NotificationCenter.default.post(
                        name: .ghosttySurfaceDidClose,
                        object: nil,
                        userInfo: ["userdata": userdata]
                    )
                }
            }
            // Always return true so Ghostty does not print the fallback prompt.
            return true

        default:
            // Actions handled by the surface view (NEW_SPLIT, GOTO_SPLIT, etc.)
            // return false so Ghostty uses its built-in fallback.
            return false
        }
    }

    // MARK: - Private helpers

    /// Recover the TerminalPanel for a surface userdata pointer.
    /// Searches all window contexts registered on AppDelegate.
    @MainActor
    static func panel(fromUserdata userdata: UnsafeMutableRawPointer) -> TerminalPanel? {
        let session = Unmanaged<TerminalSession>.fromOpaque(userdata).takeUnretainedValue()
        guard let delegate = AppDelegate.shared else { return nil }
        // Build list of (workspaceManager, panelManager) pairs to search.
        var pairs: [(WorkspaceManager, PanelManager)] = []
        if let wm = delegate.workspaceManager, let pm = delegate.panelManager {
            pairs.append((wm, pm))
        }
        for ctx in delegate.windowContexts.values {
            pairs.append((ctx.workspaceManager, ctx.panelManager))
        }
        for (wm, pm) in pairs {
            for workspace in wm.workspaces {
                for panelID in pm.allPanelIDs(in: workspace.id) {
                    if let panel = pm.panel(for: panelID), panel.session.id == session.id {
                        return panel
                    }
                }
            }
        }
        return nil
    }

    /// Reload Ghostty configuration from disk. Called by Cmd+Shift+, shortcut and internal Ghostty action.
    func reloadConfig() {
        NamuDebug.log("[Namu] Config reload from disk: begin")
        guard let oldConfig = config else {
            NamuDebug.log("[Namu] Config reload: no existing config, aborting")
            return
        }

        guard let newConfig = ghostty_config_new() else {
            NamuDebug.log("[Namu] Config reload: ghostty_config_new() failed")
            return
        }
        ghostty_config_load_default_files(newConfig)
        ghostty_config_load_recursive_files(newConfig)
        ghostty_config_finalize(newConfig)

        if let app {
            ghostty_app_update_config(app, newConfig)
        }

        ghostty_config_free(oldConfig)
        self.config = newConfig

        NotificationCenter.default.post(name: .ghosttyConfigDidReload, object: nil)

        // Refresh all terminal surfaces so visual changes (background, font) take effect immediately.
        refreshAllSurfaces()
        NamuDebug.log("[Namu] Config reload from disk: complete")
    }

    /// Force a redraw on all active terminal surfaces.
    private func refreshAllSurfaces() {
        guard let app else { return }
        ghostty_app_set_focus(app, true)
        ghostty_app_set_focus(app, NSApp.isActive)
    }

}

// MARK: - Action direction helpers

/// Map Ghostty split direction to Namu's SplitDirection.
/// Note: Namu always places the new split after the active pane regardless of
/// left-vs-right or up-vs-down intent. Left/Right both map to .horizontal and
/// Up/Down both map to .vertical. A future enhancement could pass the
/// directional placement hint through to `splitActivePanel` so the new pane
/// appears on the requested side.
private func splitDirection(from ghosttyDir: ghostty_action_split_direction_e) -> SplitDirection {
    switch ghosttyDir {
    case GHOSTTY_SPLIT_DIRECTION_LEFT, GHOSTTY_SPLIT_DIRECTION_RIGHT: return .horizontal
    default: return .vertical
    }
}

private func navigationDirection(from ghosttyDir: ghostty_action_goto_split_e) -> NavigationDirection? {
    switch ghosttyDir {
    case GHOSTTY_GOTO_SPLIT_LEFT:     return .left
    case GHOSTTY_GOTO_SPLIT_RIGHT:    return .right
    case GHOSTTY_GOTO_SPLIT_UP:       return .up
    case GHOSTTY_GOTO_SPLIT_DOWN:     return .down
    default: return nil
    }
}

/// Walk the ExternalTreeNode tree and return the (id, dividerPosition) of the
/// nearest ancestor split node that has `orientation` and contains the pane
/// identified by `paneIDStr`. Returns nil if no such split exists.
private func nearestSplit(
    in node: ExternalTreeNode,
    containingPane paneIDStr: String,
    orientation: String
) -> (id: String, dividerPosition: Double)? {
    guard case .split(let split) = node else { return nil }

    let firstContains = containsPane(split.first, paneID: paneIDStr)
    let secondContains = containsPane(split.second, paneID: paneIDStr)

    // Neither child contains the pane — not on this branch.
    guard firstContains || secondContains else { return nil }

    // Try to find a deeper match first (prefer the tightest enclosing split).
    let childResult: (id: String, dividerPosition: Double)?
    if firstContains {
        childResult = nearestSplit(in: split.first, containingPane: paneIDStr, orientation: orientation)
    } else {
        childResult = nearestSplit(in: split.second, containingPane: paneIDStr, orientation: orientation)
    }

    if let deeper = childResult { return deeper }

    // No deeper match — check if this split itself matches the orientation.
    if split.orientation == orientation {
        return (split.id, split.dividerPosition)
    }
    return nil
}

/// Return true if the given tree node contains a pane with the given ID.
private func containsPane(_ node: ExternalTreeNode, paneID: String) -> Bool {
    switch node {
    case .pane(let p):
        return p.id == paneID
    case .split(let s):
        return containsPane(s.first, paneID: paneID) || containsPane(s.second, paneID: paneID)
    }
}

/// Collect all (id, dividerPosition) pairs for every split node in the tree.
private func allSplits(in node: ExternalTreeNode) -> [(id: String, dividerPosition: Double)] {
    switch node {
    case .pane:
        return []
    case .split(let s):
        var result = [(id: s.id, dividerPosition: s.dividerPosition)]
        result.append(contentsOf: allSplits(in: s.first))
        result.append(contentsOf: allSplits(in: s.second))
        return result
    }
}

// MARK: - GhosttyConfigReader

/// Lightweight read-only accessor for an existing ghostty_config_t.
/// Does NOT own or free the config handle.
private struct GhosttyConfigReader {
    let config: ghostty_config_t

    init(_ config: ghostty_config_t) {
        self.config = config
    }

    @discardableResult
    private func get<T>(_ key: String, into value: inout T) -> Bool {
        key.withCString { keyPtr in
            withUnsafeMutablePointer(to: &value) { valuePtr in
                ghostty_config_get(config, valuePtr, keyPtr, UInt(key.utf8.count))
            }
        }
    }

    var bellFeatures: UInt32 {
        var value: CUnsignedInt = 0
        get("bell-features", into: &value)
        return UInt32(value)
    }

    var bellAudioPath: String? {
        var value: UnsafePointer<Int8>?
        guard get("bell-audio-path", into: &value), let value else { return nil }
        let path = String(cString: value)
        return path.isEmpty ? nil : path
    }

    var bellAudioVolume: Float {
        var value: Double = 0.5
        get("bell-audio-volume", into: &value)
        return Float(min(1.0, max(0.0, value)))
    }
}

// MARK: - GhosttyBridge.Surface

/// Namespace for surface lifecycle helpers. Pure static — no stored state.
/// Actual surface ownership lives in TerminalSession.
enum GhosttyBridge {
    enum Surface {
        /// Create a new Ghostty surface attached to `nsView`.
        /// - Parameters:
        ///   - app: The ghostty_app_t from GhosttyApp.
        ///   - nsView: The NSView that will host the Metal layer.
        ///   - workingDirectory: Optional initial working directory.
        ///   - command: Optional command to run instead of the default shell.
        ///   - envVars: Additional environment variables.
        ///   - userdata: Opaque pointer stored on the surface (retrieved via ghostty_surface_userdata).
        ///   - scaleFactor: Backing scale factor of the display.
        /// - Returns: Opaque surface handle or nil on failure.
        static func create(
            app: ghostty_app_t,
            nsView: NSView,
            workingDirectory: String? = nil,
            command: String? = nil,
            envVars: [String: String] = [:],
            userdata: UnsafeMutableRawPointer? = nil,
            scaleFactor: Double = 1.0
        ) -> ghostty_surface_t? {
            var cfg = ghostty_surface_config_new()
            cfg.platform_tag = GHOSTTY_PLATFORM_MACOS
            cfg.platform = ghostty_platform_u(
                macos: ghostty_platform_macos_s(
                    nsview: Unmanaged.passUnretained(nsView).toOpaque()
                )
            )
            cfg.userdata = userdata
            cfg.scale_factor = scaleFactor

            // Build C env var array on the stack, scoped so pointers stay valid.
            var cEnvVars = envVars.map { key, value -> ghostty_env_var_s in
                // withCString lifetimes would escape — we use strdup to keep them alive
                // for the duration of ghostty_surface_new, then free below.
                ghostty_env_var_s(
                    key: strdup(key),
                    value: strdup(value)
                )
            }

            let surface: ghostty_surface_t?

            func createWithStrings() -> ghostty_surface_t? {
                let envCount = cEnvVars.count
                if envCount > 0 {
                    return cEnvVars.withUnsafeMutableBufferPointer { buf in
                        cfg.env_vars = buf.baseAddress
                        cfg.env_var_count = envCount
                        return ghostty_surface_new(app, &cfg)
                    }
                }
                return ghostty_surface_new(app, &cfg)
            }

            // Chain withCString calls for optional strings.
            if let command, !command.isEmpty {
                surface = command.withCString { cCmd in
                    cfg.command = cCmd
                    if let wd = workingDirectory, !wd.isEmpty {
                        return wd.withCString { cWd in
                            cfg.working_directory = cWd
                            return createWithStrings()
                        }
                    }
                    return createWithStrings()
                }
            } else if let wd = workingDirectory, !wd.isEmpty {
                surface = wd.withCString { cWd in
                    cfg.working_directory = cWd
                    return createWithStrings()
                }
            } else {
                surface = createWithStrings()
            }

            // Free the duplicated C strings.
            for item in cEnvVars {
                free(UnsafeMutablePointer(mutating: item.key))
                free(UnsafeMutablePointer(mutating: item.value))
            }

            if surface == nil {
                print("[GhosttyBridge.Surface] ghostty_surface_new returned nil")
            }

            return surface
        }

        static func free(_ surface: ghostty_surface_t) {
            ghostty_surface_free(surface)
        }

        static func userdata(_ surface: ghostty_surface_t) -> UnsafeMutableRawPointer? {
            ghostty_surface_userdata(surface)
        }

        static func inheritedConfig(
            _ surface: ghostty_surface_t,
            context: ghostty_surface_context_e
        ) -> ghostty_surface_config_s {
            ghostty_surface_inherited_config(surface, context)
        }

        /// Best-effort check: reject pointers that no longer belong to an active
        /// malloc zone allocation. NOT a reliable UAF detector — freed-then-reallocated
        /// memory will pass this check. The primary safety mechanism is
        /// TerminalSession.destroy() setting surface = nil.
        static func appearsLive(_ surface: ghostty_surface_t) -> Bool {
            malloc_zone_from_ptr(surface) != nil && malloc_size(surface) > 0
        }
    }
}

// MARK: - GhosttyPasteboard

/// Internal clipboard helpers for the runtime callbacks.
private enum GhosttyPasteboard {
    private static let selectionPasteboard = NSPasteboard(
        name: NSPasteboard.Name("xyz.omlabs.namu.selection")
    )

    static func read(from location: ghostty_clipboard_e) -> String? {
        guard let pb = pasteboard(for: location) else { return nil }
        return pb.string(forType: .string)
    }

    static func write(_ string: String, to location: ghostty_clipboard_e) {
        guard let pb = pasteboard(for: location) else { return }
        pb.clearContents()
        pb.setString(string, forType: .string)
    }

    private static func pasteboard(for location: ghostty_clipboard_e) -> NSPasteboard? {
        switch location {
        case GHOSTTY_CLIPBOARD_STANDARD: return .general
        case GHOSTTY_CLIPBOARD_SELECTION: return selectionPasteboard
        default: return nil
        }
    }
}
