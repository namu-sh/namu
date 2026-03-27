import AppKit

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

        // bit 1: custom audio file
        if (features & (1 << 1)) != 0,
           let path = cfg.bellAudioPath,
           let sound = NSSound(contentsOfFile: path, byReference: false) {
            sound.volume = cfg.bellAudioVolume
            sound.play()
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
            if !soft {
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

        default:
            // Actions handled by the surface view (NEW_SPLIT, GOTO_SPLIT, etc.)
            // return false so Ghostty uses its built-in fallback.
            return false
        }
    }

    // MARK: - Private helpers

    private func reloadConfig() {
        guard let oldConfig = config else { return }

        guard let newConfig = ghostty_config_new() else { return }
        ghostty_config_load_default_files(newConfig)
        ghostty_config_load_recursive_files(newConfig)
        ghostty_config_finalize(newConfig)

        if let app {
            ghostty_app_update_config(app, newConfig)
        }

        ghostty_config_free(oldConfig)
        self.config = newConfig

        NotificationCenter.default.post(name: .ghosttyConfigDidReload, object: nil)
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
