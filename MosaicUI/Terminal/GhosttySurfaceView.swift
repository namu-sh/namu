import AppKit
import QuartzCore

// MARK: - GhosttySurfaceView

/// NSView subclass that hosts a Metal-rendered Ghostty terminal surface.
/// Owns keyboard routing (three-phase), mouse events, focus management,
/// and display link lifecycle.
///
/// Keyboard routing (three phases):
///   1. performKeyEquivalent  → ghostty_surface_key_is_binding fast path
///   2. keyDown               → Ctrl+key direct path or fall through to interpretKeyEvents
///   3. interpretKeyEvents    → IME composition, text accumulation, ghostty_surface_key
final class GhosttySurfaceView: NSView, NSTextInputClient {

    // MARK: - Properties

    weak var session: TerminalSession?

    /// Called when this view becomes first responder.
    var onFocus: (() -> Void)?

    /// Backing surface handle — owned by TerminalSession, referenced weakly here.
    var surface: ghostty_surface_t? {
        session?.surface
    }

    override var acceptsFirstResponder: Bool { true }

    // needsPanelToBecomeKey = false ensures correct focus in split panes without
    // requiring the panel to become key first (avoids focus race conditions).
    override var needsPanelToBecomeKey: Bool { false }

    // MARK: - Private state

    private var trackingArea: NSTrackingArea?
    private var eventMonitor: Any?
    private var lastScrollEventTime: CFTimeInterval = 0

    /// Text accumulated during a single keyDown → interpretKeyEvents round trip.
    private var keyTextAccumulator: [String]?
    /// Whether insertText was called during the current interpretKeyEvents cycle.
    private var didInsertText: Bool = false
    private var markedText = NSMutableAttributedString()

    // MARK: - Private helpers

    private func unshiftedCodepoint(from event: NSEvent) -> UInt32 {
        guard let chars = event.characters(byApplyingModifiers: [])
                          ?? event.charactersIgnoringModifiers
                          ?? event.characters,
              let scalar = chars.unicodeScalars.first else { return 0 }
        return scalar.value
    }

    // MARK: - Init

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        wantsLayer = true
        layer?.masksToBounds = true

        installEventMonitor()
        updateTrackingAreas()

        registerForDraggedTypes([.string, .fileURL])
    }

    deinit {
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
        }
    }

    // MARK: - Focus

    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        if result {
            onFocus?()
            if let surface {
                ghostty_surface_set_focus(surface, true)
                // Reassert display ID after becoming first responder to defend against
                // frozen-surface "stuck-vsync" where CVDisplayLink starts before
                // display ID is valid.
                if let displayID = window?.screen?.displayID, displayID != 0 {
                    ghostty_surface_set_display_id(surface, displayID)
                }
            }
        }
        return result
    }

    override func resignFirstResponder() -> Bool {
        let result = super.resignFirstResponder()
        if result, let surface {
            ghostty_surface_set_focus(surface, false)
        }
        return result
    }

    // MARK: - Layout / window changes

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let window {
            // If the session hasn't started yet (surface was deferred until window was available),
            // start it now that we have a valid window and display.
            if let session, !session.isAlive, let app = GhosttyApp.shared {
                let config = GhosttyConfig()
                config.loadDefaultFiles()
                config.loadRecursiveFiles()
                config.finalize()
                let displayID = window.screen?.displayID ?? 0
                session.start(
                    hostView: self,
                    displayID: displayID,
                    app: app,
                    config: config
                )
                session.setContentScale(window.backingScaleFactor)
                let backingSize = convertToBacking(bounds).size
                if backingSize.width > 0, backingSize.height > 0 {
                    session.resize(width: UInt32(backingSize.width), height: UInt32(backingSize.height))
                }
                session.refresh()
                window.makeFirstResponder(self)
                MosaicDebug.log("[Mosaic] viewDidMoveToWindow: started session displayID=\(displayID), scale=\(window.backingScaleFactor), surface=\(session.surface != nil), size=\(backingSize.width)x\(backingSize.height)")
            } else {
                session?.setContentScale(window.backingScaleFactor)
                if let displayID = window.screen?.displayID, displayID != 0 {
                    session?.setDisplayID(displayID)
                }
                window.makeFirstResponder(self)
            }
        }
        updateTrackingAreas()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        guard let window else { return }
        session?.setContentScale(window.backingScaleFactor)
        let backingSize = convertToBacking(bounds).size
        session?.resize(width: UInt32(backingSize.width), height: UInt32(backingSize.height))
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        guard newSize.width > 0, newSize.height > 0 else { return }
        let backingSize = convertToBacking(NSRect(origin: .zero, size: newSize)).size
        session?.resize(width: UInt32(backingSize.width), height: UInt32(backingSize.height))
    }

    // MARK: - Tracking area

    override func updateTrackingAreas() {
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let opts: NSTrackingArea.Options = [
            .inVisibleRect,
            .activeAlways,
            .mouseMoved,
            .mouseEnteredAndExited,
            .cursorUpdate,
        ]
        let area = NSTrackingArea(rect: .zero, options: opts, owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
        super.updateTrackingAreas()
    }

    // MARK: - Scroll wheel local monitor

    private func installEventMonitor() {
        guard eventMonitor == nil else { return }
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel]) { [weak self] event in
            self?.localScrollWheelHandler(event) ?? event
        }
    }

    private func localScrollWheelHandler(_ event: NSEvent) -> NSEvent? {
        // Only intercept if this view is the intended target.
        guard event.window === window,
              hitTest(convert(event.locationInWindow, from: nil)) === self else {
            return event
        }
        scrollWheel(with: event)
        return nil
    }

    // MARK: - Keyboard: Phase 1 — performKeyEquivalent

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard let surface else { return false }

        let mods = GhosttyKeyboard.translateMods(event.modifierFlags)
        let keyEvent = GhosttyKeyboard.makeKeyInput(
            action: GHOSTTY_ACTION_PRESS,
            mods: mods,
            keycode: UInt32(event.keyCode),
            unshiftedCodepoint: unshiftedCodepoint(from: event)
        )

        // Check if this keystroke is a Ghostty binding.
        let (isBinding, bindingFlags) = GhosttyKeyboard.isBinding(surface: surface, key: keyEvent)
        guard isBinding, let flags = bindingFlags else { return false }

        // GHOSTTY_BINDING_FLAGS_ALL means the binding should also go to AppKit menus.
        // If that flag is set, let AppKit try the menu first.
        let isAll = flags.rawValue & GHOSTTY_BINDING_FLAGS_ALL.rawValue != 0
        let isPerformable = flags.rawValue & GHOSTTY_BINDING_FLAGS_PERFORMABLE.rawValue != 0
        if isAll || isPerformable {
            if let menu = NSApp.mainMenu, menu.performKeyEquivalent(with: event) {
                return true
            }
        }

        return GhosttyKeyboard.sendKey(to: surface, key: keyEvent)
    }

    // MARK: - Keyboard: Phase 2 — keyDown

    override func keyDown(with event: NSEvent) {
        MosaicDebug.log("[Mosaic] keyDown: keyCode=\(event.keyCode), surface=\(surface != nil), isFirstResponder=\(window?.firstResponder === self)")
        guard let surface else { return }

        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let isCtrlOnly = flags.contains(.control) && !flags.contains(.command) && !flags.contains(.option)

        // Ctrl+key fast path: bypass interpretKeyEvents (zero IME overhead).
        if isCtrlOnly && !hasMarkedText() {
            ghostty_surface_set_focus(surface, true)
            let mods = GhosttyKeyboard.translateMods(event.modifierFlags)
            var keyEvent = GhosttyKeyboard.makeKeyInput(
                action: event.isARepeat ? GHOSTTY_ACTION_REPEAT : GHOSTTY_ACTION_PRESS,
                mods: mods,
                keycode: UInt32(event.keyCode),
                unshiftedCodepoint: unshiftedCodepoint(from: event)
            )
            let text = event.charactersIgnoringModifiers ?? event.characters ?? ""
            let handled: Bool
            if text.isEmpty {
                handled = GhosttyKeyboard.sendKey(to: surface, key: keyEvent)
            } else {
                handled = text.withCString { ptr in
                    keyEvent.text = ptr
                    return GhosttyKeyboard.sendKey(to: surface, key: keyEvent)
                }
            }
            if handled { return }
        }

        // Phase 3: IME / full key routing via interpretKeyEvents.
        keyTextAccumulator = []
        defer { keyTextAccumulator = nil }

        // Translate mods for macos-option-as-alt support
        let translatedMods = GhosttyKeyboard.translationMods(surface: surface, mods: GhosttyKeyboard.translateMods(event.modifierFlags))
        let originalMods = GhosttyKeyboard.translateMods(event.modifierFlags)

        let eventForInterpret: NSEvent
        if translatedMods != originalMods {
            var adjustedFlags = event.modifierFlags
            if originalMods.rawValue & GHOSTTY_MODS_ALT.rawValue != 0 && translatedMods.rawValue & GHOSTTY_MODS_ALT.rawValue == 0 {
                adjustedFlags.remove(.option)
            }
            if let synthetic = NSEvent.keyEvent(with: event.type, location: event.locationInWindow,
                                                 modifierFlags: adjustedFlags, timestamp: event.timestamp,
                                                 windowNumber: event.windowNumber, context: nil,
                                                 characters: event.characters ?? "",
                                                 charactersIgnoringModifiers: event.charactersIgnoringModifiers ?? "",
                                                 isARepeat: event.isARepeat, keyCode: event.keyCode) {
                eventForInterpret = synthetic
            } else {
                eventForInterpret = event
            }
        } else {
            eventForInterpret = event
        }
        didInsertText = false
        interpretKeyEvents([eventForInterpret])

        // If interpretKeyEvents didn't produce any text (e.g. Enter, Backspace, arrows,
        // Tab, Escape), send the raw key event directly to Ghostty.
        if !didInsertText {
            let mods = GhosttyKeyboard.translateMods(event.modifierFlags)
            var keyEvent = GhosttyKeyboard.makeKeyInput(
                action: event.isARepeat ? GHOSTTY_ACTION_REPEAT : GHOSTTY_ACTION_PRESS,
                mods: mods,
                keycode: UInt32(event.keyCode),
                unshiftedCodepoint: unshiftedCodepoint(from: event)
            )
            let text = event.characters ?? ""
            if !text.isEmpty {
                text.withCString { ptr in
                    keyEvent.text = ptr
                    _ = GhosttyKeyboard.sendKey(to: surface, key: keyEvent)
                }
            } else {
                _ = GhosttyKeyboard.sendKey(to: surface, key: keyEvent)
            }
            MosaicDebug.log("[Mosaic] keyDown: raw key sent (no text from interpretKeyEvents) keyCode=\(event.keyCode)")
        }
    }

    override func keyUp(with event: NSEvent) {
        guard let surface else { return }
        let mods = GhosttyKeyboard.translateMods(event.modifierFlags)
        let keyEvent = GhosttyKeyboard.makeKeyInput(
            action: GHOSTTY_ACTION_RELEASE,
            mods: mods,
            keycode: UInt32(event.keyCode)
        )
        GhosttyKeyboard.sendKey(to: surface, key: keyEvent)
    }

    override func flagsChanged(with event: NSEvent) {
        guard let surface else { return }
        let mods = GhosttyKeyboard.translateMods(event.modifierFlags)
        let keyEvent = GhosttyKeyboard.makeKeyInput(
            action: GHOSTTY_ACTION_PRESS,
            mods: mods,
            keycode: UInt32(event.keyCode)
        )
        GhosttyKeyboard.sendKey(to: surface, key: keyEvent)
    }

    // Suppress NSBeep for unhandled actions from interpretKeyEvents.
    override func doCommand(by selector: Selector) {}

    override func insertText(_ insertString: Any) {
        insertText(insertString, replacementRange: NSRange(location: NSNotFound, length: 0))
    }

    // MARK: - Keyboard: Phase 3 — NSTextInputClient

    func insertText(_ string: Any, replacementRange: NSRange) {
        let text: String
        if let attributed = string as? NSAttributedString {
            text = attributed.string
        } else if let plain = string as? String {
            text = plain
        } else {
            return
        }
        guard !text.isEmpty else { return }
        didInsertText = true

        if keyTextAccumulator != nil {
            keyTextAccumulator?.append(text)
        } else {
            // Committed text outside a keyDown round-trip (e.g. voice input).
            guard let surface else { return }
            GhosttyKeyboard.sendText(to: surface, text: text)
        }

        // Flush accumulated text to Ghostty at the end of each keyDown cycle.
        flushKeyTextAccumulatorIfReady()
    }

    private func flushKeyTextAccumulatorIfReady() {
        guard let accumulator = keyTextAccumulator,
              let surface else { return }
        for text in accumulator {
            let action = GHOSTTY_ACTION_PRESS
            let mods = ghostty_input_mods_e(rawValue: GHOSTTY_MODS_NONE.rawValue)
            var keyEvent = GhosttyKeyboard.makeKeyInput(
                action: action,
                mods: mods,
                keycode: 0
            )
            text.withCString { ptr in
                keyEvent.text = ptr
                _ = GhosttyKeyboard.sendKey(to: surface, key: keyEvent)
            }
        }
        keyTextAccumulator = []
    }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        markedText = NSMutableAttributedString()
        if let attributed = string as? NSAttributedString {
            markedText.append(attributed)
        } else if let plain = string as? String {
            markedText.append(NSAttributedString(string: plain))
        }
        let text = markedText.string.isEmpty ? nil : markedText.string
        guard let surface else { return }
        GhosttyKeyboard.sendPreedit(to: surface, text: text)
    }

    func unmarkText() {
        markedText = NSMutableAttributedString()
        guard let surface else { return }
        GhosttyKeyboard.sendPreedit(to: surface, text: nil)
    }

    func hasMarkedText() -> Bool {
        markedText.length > 0
    }

    func markedRange() -> NSRange {
        hasMarkedText()
            ? NSRange(location: 0, length: markedText.length)
            : NSRange(location: NSNotFound, length: 0)
    }

    func selectedRange() -> NSRange {
        NSRange(location: NSNotFound, length: 0)
    }

    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? {
        nil
    }

    func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }

    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        guard let surface else { return .zero }
        let (x, y, w, h) = GhosttyKeyboard.imePoint(surface: surface)
        // Ghostty returns top-origin Y; convert to screen coordinates.
        let viewRect = NSRect(x: x, y: bounds.height - y, width: w, height: h)
        guard let window else { return viewRect }
        let windowRect = convert(viewRect, to: nil)
        return window.convertToScreen(windowRect)
    }

    func characterIndex(for point: NSPoint) -> Int { 0 }

    // MARK: - Mouse events

    override func mouseDown(with event: NSEvent) {
        MosaicDebug.log("[Mosaic] mouseDown: window=\(window != nil), surface=\(surface != nil), onFocus=\(onFocus != nil), session=\(session?.id.uuidString.prefix(8) ?? "nil")")
        // Always claim first responder and notify focus on click.
        let ok = window?.makeFirstResponder(self) ?? false
        MosaicDebug.log("[Mosaic] mouseDown: makeFirstResponder=\(ok)")
        onFocus?()
        guard let surface else { return }
        let mods = GhosttyKeyboard.translateMods(event.modifierFlags)
        GhosttyKeyboard.sendMouseButton(
            to: surface,
            state: GHOSTTY_MOUSE_PRESS,
            button: GHOSTTY_MOUSE_LEFT,
            mods: mods
        )
    }

    override func mouseUp(with event: NSEvent) {
        guard let surface else { return }
        let mods = GhosttyKeyboard.translateMods(event.modifierFlags)
        GhosttyKeyboard.sendMouseButton(
            to: surface,
            state: GHOSTTY_MOUSE_RELEASE,
            button: GHOSTTY_MOUSE_LEFT,
            mods: mods
        )
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let surface else { return }
        if !ghostty_surface_mouse_captured(surface) {
            super.rightMouseDown(with: event)
            return
        }
        let mods = GhosttyKeyboard.translateMods(event.modifierFlags)
        _ = GhosttyKeyboard.sendMouseButton(to: surface, state: GHOSTTY_MOUSE_PRESS, button: GHOSTTY_MOUSE_RIGHT, mods: mods)
    }

    override func rightMouseUp(with event: NSEvent) {
        guard let surface else { return }
        let mods = GhosttyKeyboard.translateMods(event.modifierFlags)
        GhosttyKeyboard.sendMouseButton(
            to: surface,
            state: GHOSTTY_MOUSE_RELEASE,
            button: GHOSTTY_MOUSE_RIGHT,
            mods: mods
        )
    }

    override func mouseMoved(with event: NSEvent) {
        guard let surface else { return }
        let point = convert(event.locationInWindow, from: nil)
        let mods = GhosttyKeyboard.translateMods(event.modifierFlags)
        GhosttyKeyboard.sendMousePos(to: surface, x: point.x, y: bounds.height - point.y, mods: mods)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let surface else { return }
        let point = convert(event.locationInWindow, from: nil)
        let mods = GhosttyKeyboard.translateMods(event.modifierFlags)
        GhosttyKeyboard.sendMousePos(to: surface, x: point.x, y: bounds.height - point.y, mods: mods)
    }

    override func mouseExited(with event: NSEvent) {
        guard let surface else { return }
        let mods = GhosttyKeyboard.translateMods(event.modifierFlags)
        // Send (-1, -1) to signal mouse left the surface.
        ghostty_surface_mouse_pos(surface, -1, -1, mods)
    }

    override func scrollWheel(with event: NSEvent) {
        guard let surface else { return }
        lastScrollEventTime = CACurrentMediaTime()

        var dx = event.scrollingDeltaX
        var dy = event.scrollingDeltaY

        let precise = event.hasPreciseScrollingDeltas
        if precise {
            dx *= 2
            dy *= 2
        }

        // ghostty_input_scroll_mods_t is a packed int:
        //   bit 0      = precise (trackpad)
        //   bits 1..3  = momentum phase (ghostty_input_mouse_momentum_e)
        var mods: Int32 = 0
        if precise { mods |= 0b0000_0001 }

        let momentum: Int32
        switch event.momentumPhase {
        case .began:      momentum = Int32(GHOSTTY_MOUSE_MOMENTUM_BEGAN.rawValue)
        case .stationary: momentum = Int32(GHOSTTY_MOUSE_MOMENTUM_STATIONARY.rawValue)
        case .changed:    momentum = Int32(GHOSTTY_MOUSE_MOMENTUM_CHANGED.rawValue)
        case .ended:      momentum = Int32(GHOSTTY_MOUSE_MOMENTUM_ENDED.rawValue)
        case .cancelled:  momentum = Int32(GHOSTTY_MOUSE_MOMENTUM_CANCELLED.rawValue)
        case .mayBegin:   momentum = Int32(GHOSTTY_MOUSE_MOMENTUM_MAY_BEGIN.rawValue)
        default:          momentum = Int32(GHOSTTY_MOUSE_MOMENTUM_NONE.rawValue)
        }
        mods |= momentum << 1

        GhosttyKeyboard.sendMouseScroll(to: surface, dx: dx, dy: dy, scrollMods: ghostty_input_scroll_mods_t(mods))
    }

    // MARK: - Drag and drop

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        .copy
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let surface else { return false }
        let pb = sender.draggingPasteboard
        if let urls = pb.readObjects(forClasses: [NSURL.self]) as? [URL], !urls.isEmpty {
            let paths = urls.map { $0.isFileURL ? $0.path : $0.absoluteString }.joined(separator: " ")
            GhosttyKeyboard.sendText(to: surface, text: paths)
            return true
        }
        if let text = pb.string(forType: .string) {
            GhosttyKeyboard.sendText(to: surface, text: text)
            return true
        }
        return false
    }
}

// MARK: - NSScreen display ID helper

extension NSScreen {
    var displayID: UInt32? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }
}
