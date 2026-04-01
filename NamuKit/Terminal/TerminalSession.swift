import Foundation
import AppKit
import Combine
import OSLog

/// Manages the lifecycle of a single terminal session backed by a Ghostty surface.
///
/// Concrete terminal session class conforming to TerminalBackend.
///
/// Display link defense: display ID is set at surface creation AND re-asserted
/// on every focus gain to prevent frozen-surface regressions.
final class TerminalSession: ObservableObject, TerminalBackend {

    private let logger = Logger(subsystem: "com.namu.app", category: "TerminalSession")

    // MARK: - Published state

    @Published private(set) var state: SessionState = .created
    @Published private(set) var title: String = ""

    /// Backward-compatible alive check delegating to state machine.
    var isAlive: Bool { state.isAlive }

    // MARK: - Identity

    let id: UUID
    let workingDirectory: String?
    let command: String?
    let environmentVariables: [String: String]
    let waitAfterCommand: Bool
    let initialInput: String?
    /// Optional font size (points) to apply at surface creation.
    /// Set when splitting so the new pane inherits the parent's runtime zoom level
    /// regardless of the inherit-font-size config option.
    let fontSizeOverride: Float?

    // MARK: - Private state

    private(set) var surface: ghostty_surface_t?

    /// Returns the surface if it is non-nil and passes the malloc-zone liveness check.
    /// Logs a warning (once per call site) if a non-nil pointer appears dead — this
    /// indicates a use-after-free that destroy() did not catch.
    /// Also cross-validates via TerminalSurfaceRegistry that the pointer still belongs
    /// to this session, guarding against address reuse after a free.
    private func liveSurface(function: String = #function) -> ghostty_surface_t? {
        guard let s = surface else { return nil }
        guard GhosttyBridge.Surface.appearsLive(s) else {
            logger.warning("[\(function)] dead ghostty_surface_t pointer detected — surface not nil but malloc zone returned nil")
            return nil
        }
        // Cross-validate: the registry must confirm this pointer belongs to our session.
        // A mismatch means the pointer was reused by a new allocation after our surface
        // was freed without being unregistered — treat it as dead.
        if TerminalSurfaceRegistry.shared.ownerID(for: s) != id {
            logger.warning("[\(function)] ghostty_surface_t registry mismatch — pointer does not belong to session \(self.id), treating as dead")
            surface = nil
            return nil
        }
        return s
    }

    private weak var hostView: NSView?
    private var currentDisplayID: UInt32 = 0
    private var titleObserver: Any?

    // MARK: - Init

    /// Create a terminal session.
    /// The surface is not created until `start(hostView:displayID:)` is called.
    init(
        id: UUID = UUID(),
        workingDirectory: String? = nil,
        command: String? = nil,
        environmentVariables: [String: String] = [:],
        waitAfterCommand: Bool = false,
        initialInput: String? = nil,
        fontSizeOverride: Float? = nil
    ) {
        self.id = id
        self.workingDirectory = workingDirectory
        self.command = command
        self.environmentVariables = environmentVariables
        self.waitAfterCommand = waitAfterCommand
        self.initialInput = initialInput
        self.fontSizeOverride = fontSizeOverride
    }

    deinit {
        if surface != nil {
            destroy()
        }
    }

    // MARK: - Lifecycle

    /// Create the Ghostty surface and start the shell.
    /// Must be called on the main thread after the hosting NSView is available.
    ///
    /// - Parameters:
    ///   - hostView: The NSView that Ghostty will render into.
    ///   - displayID: The CGDirectDisplayID of the screen (for CVDisplayLink).
    ///   - app: The GhosttyApp singleton.
    ///   - config: The GhosttyConfig to use for surface configuration.
    @MainActor
    func start(hostView: NSView, displayID: UInt32, app: GhosttyApp, config: GhosttyConfig) {
        guard surface == nil else { return }
        guard let ghosttyApp = app.app else {
            print("[TerminalSession:\(id)] GhosttyApp has no app handle")
            return
        }

        try? state.handle(.start)

        self.hostView = hostView
        self.currentDisplayID = displayID

        let scaleFactor = hostView.window?.backingScaleFactor ?? 1.0

        // Use GhosttyConfig.withSurfaceConfig to keep C string lifetimes valid
        // for the duration of ghostty_surface_new.
        // Merge init-time per-pane env with app-level env resolved at start time.
        // This ensures NAMU_SOCKET, PATH, ZDOTDIR etc. reflect the latest state.
        var resolvedEnv = Self.appLevelEnvironment()
        for (key, value) in environmentVariables {
            resolvedEnv[key] = value  // per-pane values take precedence
        }

        let fontOverride = self.fontSizeOverride
        let created: ghostty_surface_t? = config.withSurfaceConfig(
            nsView: hostView,
            userdata: Unmanaged.passUnretained(self).toOpaque(),
            scaleFactor: scaleFactor,
            workingDirectory: workingDirectory,
            command: command,
            envVars: resolvedEnv,
            context: GHOSTTY_SURFACE_CONTEXT_WINDOW,
            waitAfterCommand: waitAfterCommand,
            initialInput: initialInput
        ) { cfg in
            // Override font size with the runtime zoom value from the parent surface
            // so new splits inherit interactive font zoom regardless of the
            // inherit-font-size config option.
            if let size = fontOverride, size > 0 {
                cfg.font_size = size
            }
            return ghostty_surface_new(ghosttyApp, &cfg)
        }

        guard let s = created else {
            print("[TerminalSession:\(id)] ghostty_surface_new failed")
            return
        }

        surface = s
        TerminalSurfaceRegistry.shared.register(surface: s, ownerID: id)
        try? state.handle(.surfaceReady)

        // Frozen-surface defense: set display ID immediately after creation.
        ghostty_surface_set_display_id(s, displayID)

        // Font zoom post-create repair: if a font size override was requested but
        // the surface was created at a different size (e.g. Ghostty clamped it),
        // apply a corrective config update so the runtime size matches the request.
        if let requested = fontSizeOverride, requested > 0 {
            if let actual = currentFontSizePoints(), abs(actual - requested) > 0.05 {
                let repairConfig = GhosttyConfig()
                repairConfig.loadDefaultFiles()
                repairConfig.loadRecursiveFiles()
                repairConfig.finalize()
                updateConfig(repairConfig)
                logger.debug("[TerminalSession:\(self.id)] font zoom repair: requested=\(requested) actual=\(actual)")
            }
        }

        // Observe Ghostty title changes for this surface.
        titleObserver = NotificationCenter.default.addObserver(
            forName: .ghosttyTitleDidChange,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self, let mySurface = self.surface else { return }
            // Match by surface pointer if available, otherwise accept all.
            if let notifSurface = notification.userInfo?["surface"] as? UnsafeMutableRawPointer,
               notifSurface != mySurface {
                return
            }
            if let newTitle = notification.userInfo?["title"] as? String, !newTitle.isEmpty {
                self.title = newTitle
            }
        }
    }

    /// Destroy the Ghostty surface and mark the session dead.
    /// If an active portal host lease is held, the surface free is deferred —
    /// the session will be destroyed once the lease is released.
    /// Safe to call multiple times.
    func destroy() {
        if let obs = titleObserver {
            NotificationCenter.default.removeObserver(obs)
            titleObserver = nil
        }
        guard let s = surface else { return }

        // Lease guard: if a portal host lease is active, defer the free.
        // This prevents crashes when SwiftUI rebuilds split panes and temporarily
        // removes/re-adds the hosting view.
        if PortalHostLeaseManager.shared.isLeaseActive(for: id) {
            logger.debug("[TerminalSession:\(self.id)] destroy deferred — portal host lease active")
            try? state.handle(.destroy)
            return
        }

        TerminalSurfaceRegistry.shared.unregister(surface: s)
        GhosttyBridge.Surface.free(s)
        surface = nil
        try? state.handle(.destroy)
    }

    // MARK: - Portal host leasing

    /// Acquire a lease to prevent this surface from being freed during SwiftUI
    /// view churn (e.g. split pane rebuild). Call before removing the hosting view.
    /// Retain the returned lease and pass it to `releaseLease(_:)` when done.
    func acquireLease() -> PortalHostLease {
        let lease = PortalHostLeaseManager.shared.acquire(surfaceID: id)
        logger.debug("[TerminalSession:\(self.id)] lease acquired leaseID=\(lease.leaseID)")
        return lease
    }

    /// Release a portal host lease. If a deferred destroy was requested while
    /// the lease was held, the surface is freed now.
    func releaseLease(_ lease: PortalHostLease) {
        guard lease.surfaceID == id else { return }
        PortalHostLeaseManager.shared.release(lease)
        logger.debug("[TerminalSession:\(self.id)] lease released leaseID=\(lease.leaseID)")

        // If destroy was called while the lease was active (state is dead but
        // surface pointer is still live), complete the free now.
        if !state.isAlive, let s = surface {
            TerminalSurfaceRegistry.shared.unregister(surface: s)
            GhosttyBridge.Surface.free(s)
            surface = nil
            logger.debug("[TerminalSession:\(self.id)] deferred destroy completed after lease release")
        }
    }

    /// Whether any active lease is protecting this session's surface.
    var isLeaseActive: Bool {
        PortalHostLeaseManager.shared.isLeaseActive(for: id)
    }

    /// Complete a deferred destroy if destroy() was called while a lease was held
    /// but the lease was reaped by the TTL reaper rather than released normally.
    /// Safe to call when no deferred destroy is pending — it is a no-op in that case.
    func completeDestroyIfDeferred() {
        guard !state.isAlive, let s = surface else { return }
        TerminalSurfaceRegistry.shared.unregister(surface: s)
        GhosttyBridge.Surface.free(s)
        surface = nil
        logger.debug("[TerminalSession:\(self.id)] deferred destroy completed after lease expiry")
    }

    // MARK: - App-level environment

    /// Environment variables that apply to all terminal surfaces.
    /// Resolved at surface creation time so values like NAMU_SOCKET
    /// reflect the current state, not the state at PanelManager init.
    static func appLevelEnvironment() -> [String: String] {
        var env: [String: String] = [:]
        let processEnv = ProcessInfo.processInfo.environment

        // Socket path.
        if let socket = processEnv["NAMU_SOCKET"] {
            env["NAMU_SOCKET"] = socket
        }

        // Prepend Resources/bin to PATH for claude wrapper + namu CLI.
        if let binPath = Bundle.main.resourceURL?.appendingPathComponent("bin").path {
            let currentPath = processEnv["PATH"] ?? "/usr/bin:/bin"
            if !currentPath.split(separator: ":").contains(Substring(binPath)) {
                env["PATH"] = "\(binPath):\(currentPath)"
            }
        }

        // Bundle identifier
        if let bundleID = Bundle.main.bundleIdentifier {
            env["NAMU_BUNDLE_ID"] = bundleID
        }

        // Bundled CLI path
        if let cliPath = Bundle.main.resourceURL?.appendingPathComponent("bin/namu").path {
            env["NAMU_BUNDLED_CLI_PATH"] = cliPath
        }

        // Claude hooks disabled setting
        let hooksEnabled = UserDefaults.standard.object(forKey: "namu.claudeHooksEnabled") == nil
            ? true
            : UserDefaults.standard.bool(forKey: "namu.claudeHooksEnabled")
        if !hooksEnabled {
            env["NAMU_CLAUDE_HOOKS_DISABLED"] = "1"
        }

        // Shell integration via ZDOTDIR override (zsh) or PROMPT_COMMAND (bash).
        if let integrationDir = Bundle.main.resourceURL?.appendingPathComponent("shell-integration").path {
            env["NAMU_SHELL_INTEGRATION_DIR"] = integrationDir

            let shell = processEnv["SHELL"] ?? "/bin/zsh"
            let shellName = (shell as NSString).lastPathComponent
            if shellName == "zsh" {
                if let existingZdotdir = processEnv["ZDOTDIR"], !existingZdotdir.isEmpty {
                    env["NAMU_ZSH_ZDOTDIR"] = existingZdotdir
                }
                env["ZDOTDIR"] = integrationDir
            } else if shellName == "bash" {
                let integScript = "\(integrationDir)/namu.bash"
                env["PROMPT_COMMAND"] = "unset PROMPT_COMMAND; [ -r '\(integScript)' ] && source '\(integScript)'"
            }
        }

        return env
    }

    // MARK: - Surface operations

    /// Resize the terminal grid to match the host view in points.
    func resize(width: UInt32, height: UInt32) {
        guard let s = liveSurface() else { return }
        ghostty_surface_set_size(s, width, height)
    }

    /// Set keyboard/mouse focus for this surface.
    /// Re-asserts the display ID on focus gain (frozen-surface defense).
    func setFocus(_ focused: Bool) {
        guard let s = liveSurface() else { return }
        ghostty_surface_set_focus(s, focused)
        if focused {
            // Re-assert display ID every time focus is gained to prevent the
            // display link from freezing after the window moves to another screen.
            ghostty_surface_set_display_id(s, currentDisplayID)
        }
    }

    /// Update the display ID for the CVDisplayLink.
    /// Call at creation AND whenever the window moves to a different screen.
    func setDisplayID(_ displayID: UInt32) {
        currentDisplayID = displayID
        guard let s = liveSurface() else { return }
        ghostty_surface_set_display_id(s, displayID)
    }

    /// Update the backing scale factor (e.g. when moving between Retina and non-Retina screens).
    func setContentScale(_ scale: Double) {
        guard let s = liveSurface() else { return }
        ghostty_surface_set_content_scale(s, scale, scale)
    }

    /// Notify Ghostty whether the surface is occluded (offscreen / hidden).
    func setOcclusion(_ occluded: Bool) {
        guard let s = liveSurface() else { return }
        ghostty_surface_set_occlusion(s, occluded)
    }

    /// Trigger an immediate render of the surface.
    func draw() {
        guard let s = liveSurface() else { return }
        ghostty_surface_draw(s)
    }

    /// Request a refresh (marks the surface dirty; does not draw immediately).
    func refresh() {
        guard let s = liveSurface() else { return }
        ghostty_surface_refresh(s)
    }

    /// Returns the current surface size (columns, rows, pixel dimensions).
    func surfaceSize() -> ghostty_surface_size_s? {
        guard let s = liveSurface() else { return nil }
        return ghostty_surface_size(s)
    }

    // MARK: - Selection

    func hasSelection() -> Bool {
        guard let s = liveSurface() else { return false }
        return ghostty_surface_has_selection(s)
    }

    /// Read the current text selection. Returns nil if nothing is selected.
    func readSelection() -> String? {
        guard let s = liveSurface() else { return nil }
        var text = ghostty_text_s()
        guard ghostty_surface_read_selection(s, &text) else { return nil }
        defer { ghostty_surface_free_text(s, &text) }
        guard let ptr = text.text, text.text_len > 0 else { return nil }
        return String(cString: ptr)
    }

    @discardableResult
    func clearSelection() -> Bool {
        // ghostty_surface_clear_selection not in public API — use binding action
        guard let s = liveSurface() else { return false }
        return ghostty_surface_binding_action(s, "reset", 5)
    }

    // MARK: - Split actions

    func split(direction: ghostty_action_split_direction_e) {
        guard let s = liveSurface() else { return }
        ghostty_surface_split(s, direction)
    }

    func focusSplit(direction: ghostty_action_goto_split_e) {
        guard let s = liveSurface() else { return }
        ghostty_surface_split_focus(s, direction)
    }

    func resizeSplit(direction: ghostty_action_resize_split_direction_e, amount: UInt16) {
        guard let s = liveSurface() else { return }
        ghostty_surface_split_resize(s, direction, amount)
    }

    func equalizeSplits() {
        guard let s = liveSurface() else { return }
        ghostty_surface_split_equalize(s)
    }

    // MARK: - Config

    /// Apply a new config to this surface.
    func updateConfig(_ config: GhosttyConfig) {
        guard let s = liveSurface(), let configHandle = config.config else { return }
        ghostty_surface_update_config(s, configHandle)
    }

    /// Return the config that a child surface should inherit from this surface.
    /// Overrides font_size with the runtime CTFont value so font zoom applied
    /// interactively is propagated to new splits even when Ghostty's
    /// inherit-font-size config option is disabled.
    func inheritedConfig(context: ghostty_surface_context_e) -> ghostty_surface_config_s? {
        guard let s = liveSurface() else { return nil }
        var cfg = GhosttyBridge.Surface.inheritedConfig(s, context: context)
        // Force-override font_size with the live CTFont value so interactive
        // font zoom (Cmd+/Cmd-) is always propagated to the new split surface,
        // regardless of the inherit-font-size config setting.
        if let runtimeSize = currentFontSizePoints(), runtimeSize != cfg.font_size {
            cfg.font_size = runtimeSize
        }
        return cfg
    }

    // MARK: - IPC text/key injection

    /// Send raw text to the terminal (e.g. from pane.send_keys / surface.send_text).
    func sendText(_ text: String) {
        guard let s = liveSurface() else { return }
        GhosttyKeyboard.sendText(to: s, text: text)
    }

    /// Send a named key (e.g. "ctrl-c", "enter", "escape") to the terminal.
    /// Returns true if the key name was recognised and dispatched.
    @discardableResult
    func sendNamedKey(_ name: String) -> Bool {
        guard let s = liveSurface() else { return false }
        // Map common named keys to Ghostty key input.
        // This covers the most useful IPC key names; extend as needed.
        let lower = name.lowercased()

        // Control sequences: "ctrl-<char>"
        if lower.hasPrefix("ctrl-"), lower.count == 6 {
            let ch = lower.dropFirst(5)
            guard let scalar = ch.unicodeScalars.first,
                  scalar.value >= 97 && scalar.value <= 122 else { return false }
            // Ctrl+A..Z → code points 1..26
            let ctrlChar = String(UnicodeScalar(scalar.value - 96)!)
            GhosttyKeyboard.sendText(to: s, text: ctrlChar)
            return true
        }

        // Named keys mapped to text equivalents
        switch lower {
        case "enter", "return":
            GhosttyKeyboard.sendText(to: s, text: "\r")
            return true
        case "tab":
            GhosttyKeyboard.sendText(to: s, text: "\t")
            return true
        case "escape", "esc":
            GhosttyKeyboard.sendText(to: s, text: "\u{1B}")
            return true
        case "backspace":
            GhosttyKeyboard.sendText(to: s, text: "\u{7F}")
            return true
        case "space":
            GhosttyKeyboard.sendText(to: s, text: " ")
            return true
        case "up":
            GhosttyKeyboard.sendText(to: s, text: "\u{1B}[A")
            return true
        case "down":
            GhosttyKeyboard.sendText(to: s, text: "\u{1B}[B")
            return true
        case "right":
            GhosttyKeyboard.sendText(to: s, text: "\u{1B}[C")
            return true
        case "left":
            GhosttyKeyboard.sendText(to: s, text: "\u{1B}[D")
            return true
        default:
            return false
        }
    }

    /// Read the visible (viewport) text from the terminal.
    /// Returns nil if the surface is not yet ready.
    func readVisibleText() -> String? {
        guard let s = liveSurface() else { return nil }
        let selection = ghostty_selection_s(
            top_left: ghostty_point_s(
                tag: GHOSTTY_POINT_VIEWPORT,
                coord: GHOSTTY_POINT_COORD_TOP_LEFT,
                x: 0, y: 0
            ),
            bottom_right: ghostty_point_s(
                tag: GHOSTTY_POINT_VIEWPORT,
                coord: GHOSTTY_POINT_COORD_BOTTOM_RIGHT,
                x: 0, y: 0
            ),
            rectangle: false
        )
        var text = ghostty_text_s()
        guard ghostty_surface_read_text(s, selection, &text) else { return nil }
        defer { ghostty_surface_free_text(s, &text) }
        guard let ptr = text.text, text.text_len > 0 else { return "" }
        return String(cString: ptr)
    }

    /// Read scrollback + visible text from the terminal (GHOSTTY_POINT_SCREEN covers full buffer).
    /// Returns nil if the surface is not ready.
    /// Truncates to charLimit characters at a safe UTF-8 boundary, then repairs any partial
    /// ANSI CSI sequence at the cut point. The result is prefixed with ESC[0m (SGR reset) so
    /// replaying the content always starts from a clean terminal state.
    func readScrollbackText(charLimit: Int) -> String? {
        guard let s = liveSurface() else { return nil }
        let selection = ghostty_selection_s(
            top_left: ghostty_point_s(
                tag: GHOSTTY_POINT_SCREEN,
                coord: GHOSTTY_POINT_COORD_TOP_LEFT,
                x: 0, y: 0
            ),
            bottom_right: ghostty_point_s(
                tag: GHOSTTY_POINT_SCREEN,
                coord: GHOSTTY_POINT_COORD_BOTTOM_RIGHT,
                x: 0, y: 0
            ),
            rectangle: false
        )
        var text = ghostty_text_s()
        guard ghostty_surface_read_text(s, selection, &text) else { return nil }
        defer { ghostty_surface_free_text(s, &text) }
        guard let ptr = text.text, text.text_len > 0 else { return "" }
        let full = String(cString: ptr)
        guard full.utf8.count > charLimit else { return "\u{1B}[0m" + full }
        // Step 1: Truncate at charLimit bytes, stepping back to a valid UTF-8 scalar boundary.
        var bytes = Array(full.utf8)
        var cutByte = min(charLimit, bytes.count)
        // Step back over UTF-8 continuation bytes (0x80–0xBF) to a leading byte.
        while cutByte > 0 && cutByte < bytes.count && bytes[cutByte] & 0xC0 == 0x80 {
            cutByte -= 1
        }
        // Step 2: ANSI CSI safety — scan backward up to 20 bytes from the cut point for ESC (0x1B).
        // If found and followed by '[' (CSI), check whether a final byte (0x40–0x7E) exists before
        // the cut. If not, the CSI is partial; move the cut to just before the ESC.
        let lookback = min(20, cutByte)
        var escPos: Int? = nil
        for i in stride(from: cutByte - 1, through: cutByte - lookback, by: -1) {
            if bytes[i] == 0x1B {
                escPos = i
                break
            }
        }
        if let esc = escPos, esc + 1 < bytes.count, bytes[esc + 1] == UInt8(ascii: "[") {
            // Search for a CSI final byte between esc+2 and cutByte (exclusive).
            let searchStart = esc + 2
            let hasFinal = searchStart < cutByte && (searchStart..<cutByte).contains { bytes[$0] >= 0x40 && bytes[$0] <= 0x7E }
            if !hasFinal {
                // Partial CSI — drop the ESC and everything after it.
                cutByte = esc
            }
        }
        // Step 3: Build the truncated string and prefix with SGR reset for clean replay.
        let truncated = String(bytes: Array(bytes.prefix(cutByte)), encoding: .utf8) ?? ""
        return "\u{1B}[0m" + truncated
    }

    // MARK: - Font size

    /// Returns the current font size (in points) from the live CTFont on the surface.
    /// Uses ghostty_surface_quicklook_font (returns a CTFont via void*) to read the
    /// runtime font — this captures font zoom applied interactively, unlike the inherited
    /// config which only reflects the config-file value.
    /// Used to propagate font zoom to new splits so the split inherits the zoomed size.
    func currentFontSizePoints() -> Float? {
        guard let s = liveSurface() else { return nil }
        guard let fontPtr = ghostty_surface_quicklook_font(s) else { return nil }
        let ctFont = Unmanaged<CTFont>.fromOpaque(fontPtr).takeUnretainedValue()
        let size = Float(CTFontGetSize(ctFont))
        return size > 0 ? size : nil
    }

    // MARK: - Process state

    /// Whether the child process (shell) has exited.
    var processExited: Bool {
        guard let s = liveSurface() else { return true }
        return ghostty_surface_process_exited(s)
    }
}
