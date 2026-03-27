import Foundation
import AppKit
import Combine

/// Manages the lifecycle of a single terminal session backed by a Ghostty surface.
///
/// Concrete terminal session class.
///
/// Display link defense: display ID is set at surface creation AND re-asserted
/// on every focus gain to prevent frozen-surface regressions.
final class TerminalSession: ObservableObject {

    // MARK: - Published state

    @Published private(set) var isAlive: Bool = false
    @Published private(set) var title: String = ""

    // MARK: - Identity

    let id: UUID
    let workingDirectory: String?
    let command: String?
    let environmentVariables: [String: String]

    // MARK: - Private state

    private(set) var surface: ghostty_surface_t?
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
        environmentVariables: [String: String] = [:]
    ) {
        self.id = id
        self.workingDirectory = workingDirectory
        self.command = command
        self.environmentVariables = environmentVariables
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

        let created: ghostty_surface_t? = config.withSurfaceConfig(
            nsView: hostView,
            userdata: Unmanaged.passUnretained(self).toOpaque(),
            scaleFactor: scaleFactor,
            workingDirectory: workingDirectory,
            command: command,
            envVars: resolvedEnv,
            context: GHOSTTY_SURFACE_CONTEXT_WINDOW
        ) { cfg in
            ghostty_surface_new(ghosttyApp, &cfg)
        }

        guard let s = created else {
            print("[TerminalSession:\(id)] ghostty_surface_new failed")
            return
        }

        surface = s
        isAlive = true

        // Frozen-surface defense: set display ID immediately after creation.
        ghostty_surface_set_display_id(s, displayID)

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
    /// Safe to call multiple times.
    func destroy() {
        if let obs = titleObserver {
            NotificationCenter.default.removeObserver(obs)
            titleObserver = nil
        }
        guard let s = surface else { return }
        GhosttyBridge.Surface.free(s)
        surface = nil
        isAlive = false
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
        guard let s = surface else { return }
        ghostty_surface_set_size(s, width, height)
    }

    /// Set keyboard/mouse focus for this surface.
    /// Re-asserts the display ID on focus gain (frozen-surface defense).
    func setFocus(_ focused: Bool) {
        guard let s = surface else { return }
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
        guard let s = surface else { return }
        ghostty_surface_set_display_id(s, displayID)
    }

    /// Update the backing scale factor (e.g. when moving between Retina and non-Retina screens).
    func setContentScale(_ scale: Double) {
        guard let s = surface else { return }
        ghostty_surface_set_content_scale(s, scale, scale)
    }

    /// Notify Ghostty whether the surface is occluded (offscreen / hidden).
    func setOcclusion(_ occluded: Bool) {
        guard let s = surface else { return }
        ghostty_surface_set_occlusion(s, occluded)
    }

    /// Trigger an immediate render of the surface.
    func draw() {
        guard let s = surface else { return }
        ghostty_surface_draw(s)
    }

    /// Request a refresh (marks the surface dirty; does not draw immediately).
    func refresh() {
        guard let s = surface else { return }
        ghostty_surface_refresh(s)
    }

    /// Returns the current surface size (columns, rows, pixel dimensions).
    func surfaceSize() -> ghostty_surface_size_s? {
        guard let s = surface else { return nil }
        return ghostty_surface_size(s)
    }

    // MARK: - Selection

    func hasSelection() -> Bool {
        guard let s = surface else { return false }
        return ghostty_surface_has_selection(s)
    }

    /// Read the current text selection. Returns nil if nothing is selected.
    func readSelection() -> String? {
        guard let s = surface else { return nil }
        var text = ghostty_text_s()
        guard ghostty_surface_read_selection(s, &text) else { return nil }
        defer { ghostty_surface_free_text(s, &text) }
        guard let ptr = text.text, text.text_len > 0 else { return nil }
        return String(cString: ptr)
    }

    @discardableResult
    func clearSelection() -> Bool {
        // ghostty_surface_clear_selection not in public API — use binding action
        guard let s = surface else { return false }
        return ghostty_surface_binding_action(s, "reset", 5)
    }

    // MARK: - Split actions

    func split(direction: ghostty_action_split_direction_e) {
        guard let s = surface else { return }
        ghostty_surface_split(s, direction)
    }

    func focusSplit(direction: ghostty_action_goto_split_e) {
        guard let s = surface else { return }
        ghostty_surface_split_focus(s, direction)
    }

    func resizeSplit(direction: ghostty_action_resize_split_direction_e, amount: UInt16) {
        guard let s = surface else { return }
        ghostty_surface_split_resize(s, direction, amount)
    }

    func equalizeSplits() {
        guard let s = surface else { return }
        ghostty_surface_split_equalize(s)
    }

    // MARK: - Config

    /// Apply a new config to this surface.
    func updateConfig(_ config: GhosttyConfig) {
        guard let s = surface, let configHandle = config.config else { return }
        ghostty_surface_update_config(s, configHandle)
    }

    /// Return the config that a child surface should inherit from this surface.
    func inheritedConfig(context: ghostty_surface_context_e) -> ghostty_surface_config_s? {
        guard let s = surface else { return nil }
        return GhosttyBridge.Surface.inheritedConfig(s, context: context)
    }

    // MARK: - IPC text/key injection

    /// Send raw text to the terminal (e.g. from pane.send_keys / surface.send_text).
    func sendText(_ text: String) {
        guard let s = surface else { return }
        GhosttyKeyboard.sendText(to: s, text: text)
    }

    /// Send a named key (e.g. "ctrl-c", "enter", "escape") to the terminal.
    /// Returns true if the key name was recognised and dispatched.
    @discardableResult
    func sendNamedKey(_ name: String) -> Bool {
        guard let s = surface else { return false }
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
        guard let s = surface else { return nil }
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

    // MARK: - Font size

    /// Returns the current font size (in points) from the surface's inherited config.
    /// Used to propagate font zoom to new splits so the split inherits the zoomed size.
    func currentFontSizePoints() -> Float? {
        guard let s = surface else { return nil }
        let cfg = ghostty_surface_inherited_config(s, GHOSTTY_SURFACE_CONTEXT_SPLIT)
        let size = Float(cfg.font_size)
        return size > 0 ? size : nil
    }

    // MARK: - Process state

    /// Whether the child process (shell) has exited.
    var processExited: Bool {
        guard let s = surface else { return true }
        return ghostty_surface_process_exited(s)
    }
}
