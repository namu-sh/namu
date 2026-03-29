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

    /// Called when this view is clicked — used to activate the panel in PanelManager.
    var onActivate: (() -> Void)?

    /// Backing surface handle — owned by TerminalSession, referenced weakly here.
    var surface: ghostty_surface_t? {
        session?.surface
    }

    override var acceptsFirstResponder: Bool { true }

    // needsPanelToBecomeKey = false ensures correct focus in split panes without
    // requiring the panel to become key first (avoids focus race conditions).
    override var needsPanelToBecomeKey: Bool { false }

    // MARK: - Attention layer (notification ring)

    private lazy var attentionLayer: CAShapeLayer = {
        let layer = CAShapeLayer()
        layer.fillColor = nil
        layer.strokeColor = NSColor.systemBlue.cgColor
        layer.lineWidth = 3
        layer.opacity = 0
        self.wantsLayer = true
        self.layer?.addSublayer(layer)
        return layer
    }()

    /// Show a brief blue border ring to draw attention to this pane.
    func requestAttention() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let inset = self.bounds.insetBy(dx: 1.5, dy: 1.5)
            self.attentionLayer.path = CGPath(roundedRect: inset, cornerWidth: 4, cornerHeight: 4, transform: nil)
            self.attentionLayer.frame = self.bounds
            self.attentionLayer.removeAllAnimations()
            self.attentionLayer.opacity = 0

            let animation = CAKeyframeAnimation(keyPath: "opacity")
            animation.values = [0.0, 0.8, 0.6, 0.8, 0.0]
            animation.keyTimes = [0.0, 0.15, 0.4, 0.6, 1.0]
            animation.duration = 0.8
            animation.timingFunctions = [
                CAMediaTimingFunction(name: .easeIn),
                CAMediaTimingFunction(name: .easeOut),
                CAMediaTimingFunction(name: .easeIn),
                CAMediaTimingFunction(name: .easeOut),
            ]
            self.attentionLayer.add(animation, forKey: "namu.attention")
        }
    }

    // MARK: - Private state

    private var trackingArea: NSTrackingArea?
    private var eventMonitor: Any?
    private var attentionObserver: Any?
    private var lastScrollEventTime: CFTimeInterval = 0

    /// Text accumulated during a single keyDown → interpretKeyEvents round trip.
    private var keyTextAccumulator: [String]?
    /// Whether insertText was called during the current interpretKeyEvents cycle.
    private var didInsertText: Bool = false
    private var markedText = NSMutableAttributedString()

    // Copy mode state
    private var isCopyModeActive: Bool = false
    private var copyModeState = CopyModeInputState()

    // Task 4.5: Find-escape suppression flag.
    // Armed when find overlay closes via Escape; next bare Escape is consumed and
    // not forwarded to the terminal, then the flag is cleared.
    private var isFindEscapeSuppressionArmed: Bool = false

    // MARK: - Private helpers

    private func unshiftedCodepoint(from event: NSEvent) -> UInt32 {
        guard let chars = event.characters(byApplyingModifiers: [])
                          ?? event.charactersIgnoringModifiers
                          ?? event.characters,
              let scalar = chars.unicodeScalars.first else { return 0 }
        return scalar.value
    }

    // MARK: - CAMetalLayer backing

    override func makeBackingLayer() -> CALayer {
        let metalLayer = CAMetalLayer()
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.isOpaque = false
        // framebufferOnly=false lets the macOS compositor read the drawable
        // when blending translucent or blurred window layers. Required for
        // background-opacity and background-blur to render correctly.
        metalLayer.framebufferOnly = false
        return metalLayer
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
            // becomeFirstResponder only tells Ghostty about focus state.
            // It must NEVER mutate the model — that is activatePanel's job.
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
                NamuDebug.log("[Namu] viewDidMoveToWindow: started session displayID=\(displayID), scale=\(window.backingScaleFactor), surface=\(session.surface != nil), size=\(backingSize.width)x\(backingSize.height)")
            } else {
                session?.setContentScale(window.backingScaleFactor)
                if let displayID = window.screen?.displayID, displayID != 0 {
                    session?.setDisplayID(displayID)
                }
                window.makeFirstResponder(self)
            }
        }
        updateTrackingAreas()

        // Observe pane attention requests (notification ring).
        if attentionObserver == nil {
            attentionObserver = NotificationCenter.default.addObserver(
                forName: .namuPaneAttentionRequested,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                guard let self, let session = self.session else { return }
                // Show attention ring if this pane's panel ID matches, or if no specific panel was targeted.
                let targetID = notification.userInfo?["panel_id"] as? UUID
                if targetID == nil || targetID == session.id {
                    self.requestAttention()
                }
            }
        }
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

    // MARK: - Copy mode

    /// Enter or exit copy mode on this surface.
    func setCopyMode(_ active: Bool) {
        isCopyModeActive = active
        if !active {
            copyModeState.reset()
        }
    }

    /// Dispatch a resolved copy mode action to Ghostty via binding_action.
    private func executeCopyModeAction(_ action: CopyModeAction, count: Int) {
        guard let surface else { return }

        if case .exit = action {
            isCopyModeActive = false
            copyModeState.reset()
        }

        if let bindingStr = copyModeBindingAction(for: action, count: count) {
            ghostty_surface_binding_action(surface, bindingStr, UInt(bindingStr.utf8.count))
        }
    }

    // MARK: - Task 4.5: Find-escape suppression

    /// Call this when the find overlay is dismissed via Escape so the next bare
    /// Escape keyDown/keyUp cycle is swallowed and not forwarded to the terminal.
    func beginFindEscapeSuppression() {
        isFindEscapeSuppressionArmed = true
    }

    private func endFindEscapeSuppression() {
        isFindEscapeSuppressionArmed = false
    }

    /// Returns true if the event is a bare Escape that should be suppressed.
    private func shouldConsumeSuppressedFindEscape(_ event: NSEvent) -> Bool {
        guard event.keyCode == 53 else { return false }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.isEmpty else { return false }
        return isFindEscapeSuppressionArmed
    }

    // MARK: - Task 4.3: Focus-follows-mouse

    /// If focus-follows-mouse is enabled in Ghostty config, request first responder
    /// when the mouse enters or moves over this pane (with no buttons pressed,
    /// app active, window key, and not already first responder).
    private func maybeRequestFirstResponderForMouseFocus() {
        guard let window else { return }
        guard window.firstResponder !== self else { return }
        guard NSEvent.pressedMouseButtons == 0 else { return }
        guard NSApp.isActive, window.isKeyWindow else { return }
        guard bounds.width > 1, bounds.height > 1 else { return }
        guard !isHiddenOrHasHiddenAncestor else { return }

        // Read focus-follows-mouse from the app-level config handle.
        guard let appConfig = GhosttyApp.shared?.config else { return }
        var enabled = false
        let key = "focus-follows-mouse"
        let found = ghostty_config_get(appConfig, &enabled, key, UInt(key.utf8.count))
        guard found && enabled else { return }

        window.makeFirstResponder(self)
        onActivate?()
    }

    // MARK: - Keyboard: Phase 1 — performKeyEquivalent

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard let surface else { return false }

        // Task 4.1: IME guard — when composition is active and the key has no Cmd
        // modifier, don't intercept. Let it flow to keyDown so the input method can
        // process it. Cmd-based shortcuts still work since Cmd is never part of IME.
        if hasMarkedText(), !event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.command) {
            return false
        }

        // In copy mode, let Cmd+key shortcuts bypass so window management still works.
        if isCopyModeActive {
            if copyModeShouldBypassForShortcut(modifierFlags: event.modifierFlags) {
                // Let AppKit handle Cmd+ shortcuts normally.
                return false
            }
            // All other key equivalents are consumed by copy mode.
            return handleCopyModeKeyEvent(event)
        }

        let mods = GhosttyKeyboard.translateMods(event.modifierFlags)
        let keyEvent = GhosttyKeyboard.makeKeyInput(
            action: GHOSTTY_ACTION_PRESS,
            mods: mods,
            keycode: UInt32(event.keyCode),
            unshiftedCodepoint: unshiftedCodepoint(from: event)
        )

        // Only handle key equivalents if this view is the first responder.
        // performKeyEquivalent is called on ALL views in the hierarchy, not just
        // the first responder. Without this guard, the first pane in the tree
        // always wins, sending Cmd+V paste to the wrong pane.
        if window?.firstResponder !== self { return false }

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

    /// Handle a key event while copy mode is active. Returns true (consumed).
    @discardableResult
    private func handleCopyModeKeyEvent(_ event: NSEvent) -> Bool {
        guard isCopyModeActive else { return false }
        let hasSelection = session?.hasSelection() ?? false
        let resolution = copyModeResolve(
            keyCode: event.keyCode,
            chars: event.charactersIgnoringModifiers,
            modifiers: event.modifierFlags,
            hasSelection: hasSelection,
            state: &copyModeState
        )
        switch resolution {
        case .consume:
            break
        case .perform(let action, let count):
            executeCopyModeAction(action, count: count)
        }
        return true
    }

    // MARK: - Keyboard: Phase 2 — keyDown

    override func keyDown(with event: NSEvent) {
        NamuDebug.log("[Namu] keyDown: keyCode=\(event.keyCode), surface=\(surface != nil), isFirstResponder=\(window?.firstResponder === self)")

        // Task 4.5: disarm suppression on any non-Escape key; consume suppressed Escape.
        if event.keyCode != 53 {
            endFindEscapeSuppression()
        }
        if shouldConsumeSuppressedFindEscape(event) {
            return
        }

        // In copy mode, intercept all key input (non-Cmd keys not caught by performKeyEquivalent).
        if isCopyModeActive {
            handleCopyModeKeyEvent(event)
            return
        }

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
            NamuDebug.log("[Namu] keyDown: raw key sent (no text from interpretKeyEvents) keyCode=\(event.keyCode)")
        }
    }

    override func keyUp(with event: NSEvent) {
        // Task 4.5: disarm suppression on non-Escape keyUp; consume suppressed Escape keyUp.
        if event.keyCode != 53 {
            endFindEscapeSuppression()
        }
        if shouldConsumeSuppressedFindEscape(event) {
            endFindEscapeSuppression()
            return
        }
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
        // Activate this panel via PanelManager, then claim first responder.
        onActivate?()
        let _ = window?.makeFirstResponder(self)
        guard let surface else { return }
        let mods = GhosttyKeyboard.translateMods(event.modifierFlags)
        // Task 4.6: Only send mouse position on first click. Double-click should
        // select a word without moving the cursor first.
        if event.clickCount == 1 {
            let point = convert(event.locationInWindow, from: nil)
            GhosttyKeyboard.sendMousePos(to: surface, x: point.x, y: bounds.height - point.y, mods: mods)
        }
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

    // Task 4.4: Right-click context menu (non-captured mode).
    // When mouse is NOT captured, NSView.rightMouseDown calls menu(for:) which
    // we override below. The super call in rightMouseDown above triggers this.
    override func menu(for event: NSEvent) -> NSMenu? {
        guard let surface else { return nil }
        if ghostty_surface_mouse_captured(surface) { return nil }

        let _ = window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        GhosttyKeyboard.sendMousePos(to: surface, x: point.x, y: bounds.height - point.y, mods: GhosttyKeyboard.translateMods(event.modifierFlags))
        _ = GhosttyKeyboard.sendMouseButton(to: surface, state: GHOSTTY_MOUSE_PRESS, button: GHOSTTY_MOUSE_RIGHT, mods: GhosttyKeyboard.translateMods(event.modifierFlags))

        let menu = NSMenu()

        if session?.hasSelection() == true {
            let copyItem = menu.addItem(
                withTitle: String(localized: "context-menu.copy", defaultValue: "Copy"),
                action: #selector(copy(_:)),
                keyEquivalent: ""
            )
            copyItem.target = self
        }

        let pasteItem = menu.addItem(
            withTitle: String(localized: "context-menu.paste", defaultValue: "Paste"),
            action: #selector(paste(_:)),
            keyEquivalent: ""
        )
        pasteItem.target = self

        let selectAllItem = menu.addItem(
            withTitle: String(localized: "context-menu.select-all", defaultValue: "Select All"),
            action: #selector(selectAll(_:)),
            keyEquivalent: ""
        )
        selectAllItem.target = self

        menu.addItem(.separator())

        let splitHItem = menu.addItem(
            withTitle: String(localized: "context-menu.split-horizontally", defaultValue: "Split Horizontally"),
            action: #selector(splitHorizontally(_:)),
            keyEquivalent: ""
        )
        splitHItem.target = self
        splitHItem.image = NSImage(systemSymbolName: "rectangle.bottomhalf.inset.filled", accessibilityDescription: nil)

        let splitVItem = menu.addItem(
            withTitle: String(localized: "context-menu.split-vertically", defaultValue: "Split Vertically"),
            action: #selector(splitVertically(_:)),
            keyEquivalent: ""
        )
        splitVItem.target = self
        splitVItem.image = NSImage(systemSymbolName: "rectangle.righthalf.inset.filled", accessibilityDescription: nil)

        return menu
    }

    @objc private func splitHorizontally(_ sender: Any?) {
        guard let surface else { return }
        let action = "new_split:down"
        ghostty_surface_binding_action(surface, action, UInt(action.utf8.count))
    }

    @objc private func splitVertically(_ sender: Any?) {
        guard let surface else { return }
        let action = "new_split:right"
        ghostty_surface_binding_action(surface, action, UInt(action.utf8.count))
    }

    @objc override func selectAll(_ sender: Any?) {
        guard let surface else { return }
        let action = "select_all"
        ghostty_surface_binding_action(surface, action, UInt(action.utf8.count))
    }

    @objc func copy(_ sender: Any?) {
        guard let surface else { return }
        let action = "copy_to_clipboard"
        ghostty_surface_binding_action(surface, action, UInt(action.utf8.count))
    }

    // Task 4.2: Middle mouse button support.
    override func otherMouseDown(with event: NSEvent) {
        guard event.buttonNumber == 2 else {
            super.otherMouseDown(with: event)
            return
        }
        let _ = window?.makeFirstResponder(self)
        guard let surface else { return }
        let point = convert(event.locationInWindow, from: nil)
        GhosttyKeyboard.sendMousePos(to: surface, x: point.x, y: bounds.height - point.y, mods: GhosttyKeyboard.translateMods(event.modifierFlags))
        _ = GhosttyKeyboard.sendMouseButton(to: surface, state: GHOSTTY_MOUSE_PRESS, button: GHOSTTY_MOUSE_MIDDLE, mods: GhosttyKeyboard.translateMods(event.modifierFlags))
    }

    override func otherMouseUp(with event: NSEvent) {
        guard event.buttonNumber == 2 else {
            super.otherMouseUp(with: event)
            return
        }
        guard let surface else { return }
        _ = GhosttyKeyboard.sendMouseButton(to: surface, state: GHOSTTY_MOUSE_RELEASE, button: GHOSTTY_MOUSE_MIDDLE, mods: GhosttyKeyboard.translateMods(event.modifierFlags))
    }

    override func mouseMoved(with event: NSEvent) {
        // Task 4.3: focus-follows-mouse on cursor movement over this pane.
        maybeRequestFirstResponderForMouseFocus()
        guard let surface else { return }
        let point = convert(event.locationInWindow, from: nil)
        let mods = GhosttyKeyboard.translateMods(event.modifierFlags)
        GhosttyKeyboard.sendMousePos(to: surface, x: point.x, y: bounds.height - point.y, mods: mods)
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        // Task 4.3: focus-follows-mouse on cursor entering this pane.
        maybeRequestFirstResponderForMouseFocus()
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

    // MARK: - Paste (clipboard image support)

    @objc func paste(_ sender: Any?) {
        NamuDebug.log("[Namu] paste called on session=\(session?.id.uuidString.prefix(8) ?? "nil") isFirstResponder=\(window?.firstResponder === self)")
        let pb = NSPasteboard.general

        // If the clipboard has an image, route through ImageTransfer
        if pb.canReadObject(forClasses: [NSImage.self], options: nil),
           let sess = session {
            ImageTransfer.transferClipboardImage(session: sess) { [weak self] result in
                guard let self, let surface = self.surface else { return }
                switch result {
                case .kittyInline(let seq):
                    GhosttyKeyboard.sendText(to: surface, text: seq)
                case .remotePath(let path), .localPath(let path):
                    GhosttyKeyboard.sendText(to: surface, text: path)
                case .failure(let msg):
                    NamuDebug.log("[Namu] Clipboard image transfer failed: \(msg)")
                }
            }
            return
        }

        // Default: let Ghostty handle text paste via its own binding
        if let surface {
            ghostty_surface_binding_action(surface, "paste_from_clipboard", UInt("paste_from_clipboard".utf8.count))
        }
    }

    // MARK: - Drag and drop

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        .copy
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let surface else { return false }
        let pb = sender.draggingPasteboard

        if let urls = pb.readObjects(forClasses: [NSURL.self]) as? [URL], !urls.isEmpty {
            // Route file drops through ImageTransfer (handles SSH upload + Kitty images)
            for url in urls where url.isFileURL {
                guard let sess = session else { continue }
                ImageTransfer.transfer(url: url, session: sess) { [weak self] result in
                    guard let self, let surface = self.surface else { return }
                    switch result {
                    case .kittyInline(let seq):
                        GhosttyKeyboard.sendText(to: surface, text: seq)
                    case .remotePath(let path), .localPath(let path):
                        GhosttyKeyboard.sendText(to: surface, text: path + " ")
                    case .failure(let msg):
                        // Fall back to pasting the local path and log the error
                        GhosttyKeyboard.sendText(to: surface, text: url.path + " ")
                        NamuDebug.log("[Namu] ImageTransfer failed: \(msg)")
                    }
                }
            }
            // Handle non-file URLs as plain text
            let nonFileURLs = urls.filter { !$0.isFileURL }
            if !nonFileURLs.isEmpty {
                let text = nonFileURLs.map(\.absoluteString).joined(separator: " ")
                GhosttyKeyboard.sendText(to: surface, text: text)
            }
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
