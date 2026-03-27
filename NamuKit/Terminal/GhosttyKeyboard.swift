import AppKit

// GhosttyKeyboard — keyboard and mouse input translation for Ghostty surfaces.
//
// HOT PATH: All keystroke functions must allocate zero heap memory.
// Use stack-allocated structs and withCString for temporary C string pointers.
enum GhosttyKeyboard {

    // MARK: - Key Input Construction

    /// Build a ghostty_input_key_s for a given action/mods/keycode.
    /// The `text` pointer is caller-managed — must remain valid for the duration of
    /// any ghostty_surface_key call. Use withCString to scope it correctly.
    static func makeKeyInput(
        action: ghostty_input_action_e,
        mods: ghostty_input_mods_e,
        consumedMods: ghostty_input_mods_e = ghostty_input_mods_e(rawValue: GHOSTTY_MODS_NONE.rawValue),
        keycode: UInt32,
        text: UnsafePointer<CChar>? = nil,
        unshiftedCodepoint: UInt32 = 0,
        composing: Bool = false
    ) -> ghostty_input_key_s {
        var key = ghostty_input_key_s()
        key.action = action
        key.mods = mods
        key.consumed_mods = consumedMods
        key.keycode = keycode
        key.text = text
        key.unshifted_codepoint = unshiftedCodepoint
        key.composing = composing
        return key
    }

    // MARK: - Modifier Translation

    /// Translate NSEvent.ModifierFlags → ghostty_input_mods_e (all modifiers).
    static func translateMods(_ flags: NSEvent.ModifierFlags) -> ghostty_input_mods_e {
        var mods = GHOSTTY_MODS_NONE.rawValue
        if flags.contains(.shift)    { mods |= GHOSTTY_MODS_SHIFT.rawValue }
        if flags.contains(.control)  { mods |= GHOSTTY_MODS_CTRL.rawValue }
        if flags.contains(.option)   { mods |= GHOSTTY_MODS_ALT.rawValue }
        if flags.contains(.command)  { mods |= GHOSTTY_MODS_SUPER.rawValue }
        if flags.contains(.capsLock) { mods |= GHOSTTY_MODS_CAPS.rawValue }
        return ghostty_input_mods_e(rawValue: mods)
    }

    /// Translate modifiers that can be consumed for text production (Shift + Option only).
    /// Control and Command never contribute to text translation.
    static func consumedMods(from flags: NSEvent.ModifierFlags) -> ghostty_input_mods_e {
        var mods = GHOSTTY_MODS_NONE.rawValue
        if flags.contains(.shift)  { mods |= GHOSTTY_MODS_SHIFT.rawValue }
        if flags.contains(.option) { mods |= GHOSTTY_MODS_ALT.rawValue }
        return ghostty_input_mods_e(rawValue: mods)
    }

    /// Ask Ghostty to translate mods respecting the surface's config
    /// (e.g. macos-option-as-alt). Returns the mods Ghostty wants used for
    /// text key translation.
    static func translationMods(surface: ghostty_surface_t, mods: ghostty_input_mods_e) -> ghostty_input_mods_e {
        ghostty_surface_key_translation_mods(surface, mods)
    }

    // MARK: - Key Event Processing

    /// Send a key event to a surface. Returns true if Ghostty consumed the event.
    /// Caller must ensure `key.text` pointer is valid for the duration of this call.
    @discardableResult
    static func sendKey(to surface: ghostty_surface_t, key: ghostty_input_key_s) -> Bool {
        ghostty_surface_key(surface, key)
    }

    /// Check whether a key event matches a Ghostty binding without dispatching it.
    /// Returns (isBinding, flags) — flags is nil when not a binding.
    static func isBinding(
        surface: ghostty_surface_t,
        key: ghostty_input_key_s
    ) -> (Bool, ghostty_binding_flags_e?) {
        var flags = ghostty_binding_flags_e(0)
        // ghostty_surface_key_is_binding takes key by value; text pointer must be valid here.
        let matched = ghostty_surface_key_is_binding(surface, key, &flags)
        return (matched, matched ? flags : nil)
    }

    // MARK: - IME / Preedit Support

    /// Send IME preedit text to the surface.
    /// Pass nil/0 to clear an active preedit state.
    static func sendPreedit(to surface: ghostty_surface_t, text: String?) {
        if let text, !text.isEmpty {
            text.withCString { ptr in
                let len = text.utf8.count
                ghostty_surface_preedit(surface, ptr, UInt(max(len, 0)))
            }
        } else {
            ghostty_surface_preedit(surface, nil, 0)
        }
    }

    /// Query the surface for the IME candidate window anchor rectangle.
    /// Returns (x, y, width, height) in view-local coordinates (top-origin Y).
    static func imePoint(surface: ghostty_surface_t) -> (x: Double, y: Double, w: Double, h: Double) {
        var x: Double = 0
        var y: Double = 0
        var w: Double = 0
        var h: Double = 0
        ghostty_surface_ime_point(surface, &x, &y, &w, &h)
        return (x, y, w, h)
    }

    /// Send committed text to the surface (e.g. from insertText: or paste).
    static func sendText(to surface: ghostty_surface_t, text: String) {
        guard !text.isEmpty else { return }
        text.withCString { ptr in
            let len = text.utf8CString.count - 1
            ghostty_surface_text(surface, ptr, UInt(max(len, 0)))
        }
    }

    // MARK: - Mouse Input

    /// Send a mouse button press or release to the surface.
    /// Returns true if Ghostty consumed the event.
    @discardableResult
    static func sendMouseButton(
        to surface: ghostty_surface_t,
        state: ghostty_input_mouse_state_e,
        button: ghostty_input_mouse_button_e,
        mods: ghostty_input_mods_e
    ) -> Bool {
        ghostty_surface_mouse_button(surface, state, button, mods)
    }

    /// Send the current mouse position to the surface.
    /// `y` should be bottom-origin (bounds.height - viewY) as required by Ghostty.
    static func sendMousePos(
        to surface: ghostty_surface_t,
        x: Double,
        y: Double,
        mods: ghostty_input_mods_e
    ) {
        ghostty_surface_mouse_pos(surface, x, y, mods)
    }

    /// Send a scroll event to the surface.
    /// `scrollMods` encodes both modifier keys and momentum phase bits.
    static func sendMouseScroll(
        to surface: ghostty_surface_t,
        dx: Double,
        dy: Double,
        scrollMods: ghostty_input_scroll_mods_t
    ) {
        ghostty_surface_mouse_scroll(surface, dx, dy, scrollMods)
    }
}
