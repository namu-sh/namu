import Foundation
import AppKit

/// Type-safe Swift wrapper around the ghostty_config_* C API.
/// Separate from GhosttyBridge because the config API is large (~50 calls).
final class GhosttyConfig {

    // MARK: - Lifecycle

    private(set) var config: ghostty_config_t?

    init() {
        config = ghostty_config_new()
    }

    deinit {
        free()
    }

    /// Load config from Ghostty's default file locations.
    func loadDefaultFiles() {
        guard let config else { return }
        ghostty_config_load_default_files(config)
    }

    /// Load config files recursively from the XDG config directories.
    func loadRecursiveFiles() {
        guard let config else { return }
        ghostty_config_load_recursive_files(config)
    }

    /// Load a config file from a specific path.
    func loadFile(_ path: String) {
        guard let config else { return }
        path.withCString { ghostty_config_load_file(config, $0) }
    }

    /// Finalize the config. Must be called before use.
    func finalize() {
        guard let config else { return }
        ghostty_config_finalize(config)
    }

    /// Free the underlying config object. Called automatically on deinit.
    func free() {
        guard let config else { return }
        ghostty_config_free(config)
        self.config = nil
    }

    // MARK: - Generic getter

    /// Read a config value by key into an inout value.
    /// Returns true if the key was found and the type matched.
    @discardableResult
    func get<T>(_ key: String, into value: inout T) -> Bool {
        guard let config else { return false }
        return key.withCString { keyPtr in
            withUnsafeMutablePointer(to: &value) { valuePtr in
                ghostty_config_get(config, valuePtr, keyPtr, UInt(key.utf8.count))
            }
        }
    }

    // MARK: - Convenience properties

    var backgroundColor: NSColor? {
        var color = ghostty_config_color_s()
        guard get("background", into: &color) else { return nil }
        return NSColor(
            red: CGFloat(color.r) / 255,
            green: CGFloat(color.g) / 255,
            blue: CGFloat(color.b) / 255,
            alpha: 1.0
        )
    }

    var backgroundOpacity: Double {
        var value: Double = 1.0
        get("background-opacity", into: &value)
        return min(1.0, max(0.0, value))
    }

    var foregroundColor: NSColor? {
        var color = ghostty_config_color_s()
        guard get("foreground", into: &color) else { return nil }
        return NSColor(
            red: CGFloat(color.r) / 255,
            green: CGFloat(color.g) / 255,
            blue: CGFloat(color.b) / 255,
            alpha: 1.0
        )
    }

    var cursorColor: NSColor? {
        var color = ghostty_config_color_s()
        guard get("cursor-color", into: &color) else { return nil }
        return NSColor(
            red: CGFloat(color.r) / 255,
            green: CGFloat(color.g) / 255,
            blue: CGFloat(color.b) / 255,
            alpha: 1.0
        )
    }

    var fontFamily: String? {
        var value: UnsafePointer<Int8>?
        guard get("font-family", into: &value), let value else { return nil }
        return String(cString: value)
    }

    var fontSize: CGFloat {
        var value: Float = 12.0
        get("font-size", into: &value)
        return CGFloat(value)
    }

    var scrollbackLimit: Int {
        var value: UInt32 = 10000
        get("scrollback-limit", into: &value)
        return Int(value)
    }

    /// Bell feature flags bitmask.
    /// bit 0 = system beep, bit 1 = custom audio, bit 2 = dock attention.
    var bellFeatures: UInt32 {
        var value: CUnsignedInt = 0
        get("bell-features", into: &value)
        return UInt32(value)
    }

    /// Path to a custom audio file played when the bell rings (bit 1 of bellFeatures).
    var bellAudioPath: String? {
        var value: UnsafePointer<Int8>?
        guard get("bell-audio-path", into: &value), let value else { return nil }
        let path = String(cString: value)
        return path.isEmpty ? nil : path
    }

    /// Volume for the custom bell audio file, clamped to [0, 1].
    var bellAudioVolume: Float {
        var value: Double = 0.5
        get("bell-audio-volume", into: &value)
        return Float(min(1.0, max(0.0, value)))
    }

    var boldIsBright: Bool {
        var value = false
        get("bold-is-bright", into: &value)
        return value
    }

    var mouseHideWhileTyping: Bool {
        var value = false
        get("mouse-hide-while-typing", into: &value)
        return value
    }

    var confirmCloseSurface: Bool {
        var value = false
        get("confirm-close-surface", into: &value)
        return value
    }

    var focusFollowsMouse: Bool {
        var value = false
        get("focus-follows-mouse", into: &value)
        return value
    }

    var shellIntegration: String {
        var value: UnsafePointer<Int8>?
        guard get("shell-integration", into: &value), let value else { return "detect" }
        return String(cString: value)
    }

    // MARK: - Color palette access

    /// Read all 256 palette colors at once.
    /// The C array imports as a tuple in Swift; use Mirror to access by index.
    func paletteColor(at index: Int) -> NSColor? {
        guard index >= 0, index <= 255 else { return nil }
        var palette = ghostty_config_palette_s()
        guard get("palette", into: &palette) else { return nil }
        // C fixed-size array ghostty_config_color_s[256] imports as a 256-element tuple.
        // Use withUnsafePointer to treat it as a contiguous buffer.
        return withUnsafePointer(to: &palette.colors) { tuplePtr in
            tuplePtr.withMemoryRebound(to: ghostty_config_color_s.self, capacity: 256) { colors in
                let c = colors[index]
                return NSColor(
                    red: CGFloat(c.r) / 255,
                    green: CGFloat(c.g) / 255,
                    blue: CGFloat(c.b) / 255,
                    alpha: 1.0
                )
            }
        }
    }

    // MARK: - Trigger lookup

    /// Look up the key binding trigger for an action string.
    func trigger(_ action: String) -> ghostty_input_trigger_s {
        guard let config else { return ghostty_input_trigger_s() }
        return action.withCString { ptr in
            ghostty_config_trigger(config, ptr, UInt(action.utf8.count))
        }
    }

    // MARK: - Diagnostics

    var diagnosticsCount: Int {
        guard let config else { return 0 }
        return Int(ghostty_config_diagnostics_count(config))
    }

    func diagnostic(at index: Int) -> ghostty_diagnostic_s {
        guard let config else { return ghostty_diagnostic_s() }
        return ghostty_config_get_diagnostic(config, UInt32(index))
    }

    var hasErrors: Bool {
        diagnosticsCount > 0
    }

    func logDiagnostics(label: String = "GhosttyConfig") {
        let count = diagnosticsCount
        guard count > 0 else { return }
        for i in 0..<count {
            let diag = diagnostic(at: i)
            let msg = diag.message.flatMap { String(cString: $0) } ?? "(null)"
            print("[\(label)] diagnostic[\(i)]: \(msg)")
        }
    }

    // MARK: - SurfaceConfig factory

    /// Build a ghostty_surface_config_s and call the provided closure with it.
    /// The closure is called while C string lifetimes (working_directory, command)
    /// are still valid. Do NOT escape the config struct out of the closure.
    ///
    /// - Parameters:
    ///   - nsView: The NSView that will host the Metal surface.
    ///   - userdata: Opaque pointer stored by Ghostty; passed back in callbacks.
    ///   - scaleFactor: Backing scale factor (window.backingScaleFactor).
    ///   - workingDirectory: Optional working directory for the shell.
    ///   - command: Optional command to run instead of the default shell.
    ///   - context: Surface context (window / tab / split).
    ///   - body: Closure receiving the fully configured ghostty_surface_config_s.
    func withSurfaceConfig<R>(
        nsView: NSView,
        userdata: UnsafeMutableRawPointer?,
        scaleFactor: Double,
        workingDirectory: String? = nil,
        command: String? = nil,
        envVars: [String: String] = [:],
        context: ghostty_surface_context_e = GHOSTTY_SURFACE_CONTEXT_WINDOW,
        body: (inout ghostty_surface_config_s) -> R
    ) -> R {
        var cfg = ghostty_surface_config_new()
        cfg.platform_tag = GHOSTTY_PLATFORM_MACOS
        cfg.platform = ghostty_platform_u(
            macos: ghostty_platform_macos_s(
                nsview: Unmanaged.passUnretained(nsView).toOpaque()
            )
        )
        cfg.userdata = userdata
        cfg.scale_factor = scaleFactor
        cfg.context = context

        // Build C env var array — strdup keeps pointers alive for the body closure.
        var cEnvVars = envVars.map { key, value in
            ghostty_env_var_s(key: strdup(key), value: strdup(value))
        }
        defer {
            for item in cEnvVars {
                Darwin.free(UnsafeMutablePointer(mutating: item.key))
                Darwin.free(UnsafeMutablePointer(mutating: item.value))
            }
        }

        // withCString scopes ensure the C string pointers remain valid for the
        // duration of body, which is where ghostty_surface_new must be called.
        func withOptionalCString(_ s: String?, body: (UnsafePointer<Int8>?) -> R) -> R {
            if let s {
                return s.withCString { body($0) }
            }
            return body(nil)
        }

        return withOptionalCString(workingDirectory) { wdPtr in
            cfg.working_directory = wdPtr
            return withOptionalCString(command) { cmdPtr in
                cfg.command = cmdPtr
                if cEnvVars.isEmpty {
                    return body(&cfg)
                }
                return cEnvVars.withUnsafeMutableBufferPointer { buf in
                    cfg.env_vars = buf.baseAddress
                    cfg.env_var_count = buf.count
                    return body(&cfg)
                }
            }
        }
    }
}
