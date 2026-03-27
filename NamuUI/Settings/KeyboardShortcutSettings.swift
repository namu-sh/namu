import AppKit
import SwiftUI

/// Stores customizable keyboard shortcuts (definitions + persistence).
enum KeyboardShortcutSettings {
    enum Action: String, CaseIterable, Identifiable {
        // Workspaces
        case newWorkspace
        case closeWorkspace
        case renameWorkspace
        case nextWorkspace
        case prevWorkspace

        // Panels / splits
        case splitRight
        case splitDown
        case toggleSplitZoom
        case focusLeft
        case focusRight
        case focusUp
        case focusDown

        // App UI
        case toggleSidebar

        var id: String { rawValue }

        var label: String {
            switch self {
            case .newWorkspace:     return "New Workspace"
            case .closeWorkspace:   return "Close Workspace"
            case .renameWorkspace:  return "Rename Workspace"
            case .nextWorkspace:    return "Next Workspace"
            case .prevWorkspace:    return "Previous Workspace"
            case .splitRight:       return "Split Right"
            case .splitDown:        return "Split Down"
            case .toggleSplitZoom:  return "Toggle Pane Zoom"
            case .focusLeft:        return "Focus Pane Left"
            case .focusRight:       return "Focus Pane Right"
            case .focusUp:          return "Focus Pane Up"
            case .focusDown:        return "Focus Pane Down"
            case .toggleSidebar:    return "Toggle Sidebar"
            }
        }

        var category: String {
            switch self {
            case .newWorkspace, .closeWorkspace, .renameWorkspace,
                 .nextWorkspace, .prevWorkspace:
                return "Workspaces"
            case .splitRight, .splitDown, .toggleSplitZoom,
                 .focusLeft, .focusRight, .focusUp, .focusDown:
                return "Panels"
            case .toggleSidebar:
                return "App"
            }
        }

        var defaultsKey: String { "shortcut.\(rawValue)" }

        var defaultShortcut: StoredShortcut {
            switch self {
            case .newWorkspace:
                return StoredShortcut(key: "n", command: true, shift: false, option: false, control: false)
            case .closeWorkspace:
                return StoredShortcut(key: "w", command: true, shift: true, option: false, control: false)
            case .renameWorkspace:
                return StoredShortcut(key: "r", command: true, shift: true, option: false, control: false)
            case .nextWorkspace:
                return StoredShortcut(key: "]", command: true, shift: false, option: false, control: true)
            case .prevWorkspace:
                return StoredShortcut(key: "[", command: true, shift: false, option: false, control: true)
            case .splitRight:
                return StoredShortcut(key: "d", command: true, shift: false, option: false, control: false)
            case .splitDown:
                return StoredShortcut(key: "d", command: true, shift: true, option: false, control: false)
            case .toggleSplitZoom:
                return StoredShortcut(key: "\r", command: true, shift: true, option: false, control: false)
            case .focusLeft:
                return StoredShortcut(key: "←", command: true, shift: false, option: true, control: false)
            case .focusRight:
                return StoredShortcut(key: "→", command: true, shift: false, option: true, control: false)
            case .focusUp:
                return StoredShortcut(key: "↑", command: true, shift: false, option: true, control: false)
            case .focusDown:
                return StoredShortcut(key: "↓", command: true, shift: false, option: true, control: false)
            case .toggleSidebar:
                return StoredShortcut(key: "b", command: true, shift: false, option: false, control: false)
            }
        }
    }

    // MARK: - CRUD

    static func shortcut(for action: Action) -> StoredShortcut {
        guard let data = UserDefaults.standard.data(forKey: action.defaultsKey),
              let shortcut = try? JSONDecoder().decode(StoredShortcut.self, from: data) else {
            return action.defaultShortcut
        }
        return shortcut
    }

    static func setShortcut(_ shortcut: StoredShortcut, for action: Action) {
        if let data = try? JSONEncoder().encode(shortcut) {
            UserDefaults.standard.set(data, forKey: action.defaultsKey)
        }
    }

    static func resetShortcut(for action: Action) {
        UserDefaults.standard.removeObject(forKey: action.defaultsKey)
    }

    static func resetAll() {
        for action in Action.allCases {
            resetShortcut(for: action)
        }
    }

    // MARK: - Duplicate detection

    /// Returns the action already using this shortcut, excluding `excluding`.
    static func conflictingAction(for shortcut: StoredShortcut, excluding: Action) -> Action? {
        Action.allCases.first { action in
            action != excluding && self.shortcut(for: action) == shortcut
        }
    }
}

// MARK: - StoredShortcut

/// A keyboard shortcut that can be stored in UserDefaults.
struct StoredShortcut: Codable, Equatable {
    var key: String
    var command: Bool
    var shift: Bool
    var option: Bool
    var control: Bool

    var displayString: String {
        var parts: [String] = []
        if control  { parts.append("⌃") }
        if option   { parts.append("⌥") }
        if shift    { parts.append("⇧") }
        if command  { parts.append("⌘") }
        let keyText: String
        switch key {
        case "\t":  keyText = "TAB"
        case "\r":  keyText = "↩"
        default:    keyText = key.uppercased()
        }
        parts.append(keyText)
        return parts.joined()
    }

    var modifierFlags: NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if command { flags.insert(.command) }
        if shift   { flags.insert(.shift) }
        if option  { flags.insert(.option) }
        if control { flags.insert(.control) }
        return flags
    }

    var keyEquivalent: KeyEquivalent? {
        switch key {
        case "←": return .leftArrow
        case "→": return .rightArrow
        case "↑": return .upArrow
        case "↓": return .downArrow
        case "\t": return .tab
        case "\r": return KeyEquivalent(Character("\r"))
        default:
            let lowered = key.lowercased()
            guard lowered.count == 1, let character = lowered.first else { return nil }
            return KeyEquivalent(character)
        }
    }

    var eventModifiers: EventModifiers {
        var modifiers: EventModifiers = []
        if command { modifiers.insert(.command) }
        if shift   { modifiers.insert(.shift) }
        if option  { modifiers.insert(.option) }
        if control { modifiers.insert(.control) }
        return modifiers
    }

    static func from(event: NSEvent) -> StoredShortcut? {
        guard let key = storedKey(from: event) else { return nil }
        let flags = event.modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .subtracting([.numericPad, .function])
        let shortcut = StoredShortcut(
            key: key,
            command: flags.contains(.command),
            shift:   flags.contains(.shift),
            option:  flags.contains(.option),
            control: flags.contains(.control)
        )
        // Require at least one modifier to avoid capturing plain typing.
        if !shortcut.command && !shortcut.shift && !shortcut.option && !shortcut.control {
            return nil
        }
        return shortcut
    }

    private static func storedKey(from event: NSEvent) -> String? {
        switch event.keyCode {
        case 123: return "←"
        case 124: return "→"
        case 125: return "↓"
        case 126: return "↑"
        case 48:  return "\t"
        case 36, 76: return "\r"
        case 33:  return "["
        case 30:  return "]"
        case 27:  return "-"
        case 24:  return "="
        case 43:  return ","
        case 47:  return "."
        case 44:  return "/"
        case 41:  return ";"
        case 39:  return "'"
        case 50:  return "`"
        case 42:  return "\\"
        default:  break
        }
        guard let chars = event.charactersIgnoringModifiers?.lowercased(),
              let char = chars.first,
              char.isLetter || char.isNumber else { return nil }
        return String(char)
    }
}

// MARK: - Settings UI

/// Full settings pane listing all actions with current bindings and click-to-rebind.
struct KeyboardShortcutSettingsView: View {
    @State private var shortcuts: [KeyboardShortcutSettings.Action: StoredShortcut] = {
        var map: [KeyboardShortcutSettings.Action: StoredShortcut] = [:]
        for action in KeyboardShortcutSettings.Action.allCases {
            map[action] = KeyboardShortcutSettings.shortcut(for: action)
        }
        return map
    }()

    @State private var conflict: (action: KeyboardShortcutSettings.Action, existing: KeyboardShortcutSettings.Action)? = nil

    private let categories: [String] = {
        var seen = Set<String>()
        var order: [String] = []
        for action in KeyboardShortcutSettings.Action.allCases {
            if seen.insert(action.category).inserted { order.append(action.category) }
        }
        return order
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let c = conflict {
                conflictBanner(c)
            }

            List {
                ForEach(categories, id: \.self) { category in
                    Section(header: Text(category).font(.headline)) {
                        ForEach(actionsIn(category)) { action in
                            shortcutRow(action)
                        }
                    }
                }
            }
            .listStyle(.inset)

            Divider()

            HStack {
                Spacer()
                Button("Restore Defaults") {
                    KeyboardShortcutSettings.resetAll()
                    reloadAll()
                    conflict = nil
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }
        }
    }

    // MARK: - Row

    @ViewBuilder
    private func shortcutRow(_ action: KeyboardShortcutSettings.Action) -> some View {
        HStack {
            Text(action.label)
                .frame(maxWidth: .infinity, alignment: .leading)

            ShortcutRecorderButton(
                shortcut: Binding(
                    get: { shortcuts[action] ?? action.defaultShortcut },
                    set: { newShortcut in applyShortcut(newShortcut, for: action) }
                )
            )
            .frame(width: 130)
        }
        .padding(.vertical, 2)
    }

    // MARK: - Conflict banner

    @ViewBuilder
    private func conflictBanner(_ c: (action: KeyboardShortcutSettings.Action, existing: KeyboardShortcutSettings.Action)) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.orange)
            Text("\"\(c.action.label)\" conflicts with \"\(c.existing.label)\". Choose a different shortcut.")
                .font(.callout)
                .foregroundColor(.primary)
            Spacer()
            Button("Dismiss") { conflict = nil }
                .buttonStyle(.borderless)
        }
        .padding(10)
        .background(Color.orange.opacity(0.12))
    }

    // MARK: - Helpers

    private func actionsIn(_ category: String) -> [KeyboardShortcutSettings.Action] {
        KeyboardShortcutSettings.Action.allCases.filter { $0.category == category }
    }

    private func applyShortcut(_ shortcut: StoredShortcut, for action: KeyboardShortcutSettings.Action) {
        if let existing = KeyboardShortcutSettings.conflictingAction(for: shortcut, excluding: action) {
            conflict = (action: action, existing: existing)
            return
        }
        conflict = nil
        shortcuts[action] = shortcut
        KeyboardShortcutSettings.setShortcut(shortcut, for: action)
    }

    private func reloadAll() {
        for action in KeyboardShortcutSettings.Action.allCases {
            shortcuts[action] = KeyboardShortcutSettings.shortcut(for: action)
        }
    }
}

// MARK: - Recorder button (NSViewRepresentable)

private struct ShortcutRecorderButton: NSViewRepresentable {
    @Binding var shortcut: StoredShortcut

    func makeNSView(context: Context) -> ShortcutRecorderNSButton {
        let button = ShortcutRecorderNSButton()
        button.shortcut = shortcut
        button.onShortcutRecorded = { newShortcut in
            shortcut = newShortcut
        }
        return button
    }

    func updateNSView(_ nsView: ShortcutRecorderNSButton, context: Context) {
        nsView.shortcut = shortcut
        nsView.updateTitle()
    }
}

private final class ShortcutRecorderNSButton: NSButton {
    var shortcut: StoredShortcut = StoredShortcut(key: "n", command: true, shift: false, option: false, control: false)
    var onShortcutRecorded: ((StoredShortcut) -> Void)?
    private var isRecording = false
    private var eventMonitor: Any?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        bezelStyle = .rounded
        setButtonType(.momentaryPushIn)
        target = self
        action = #selector(buttonClicked)
        updateTitle()
    }

    func updateTitle() {
        title = isRecording ? "Press shortcut…" : shortcut.displayString
    }

    @objc private func buttonClicked() {
        isRecording ? stopRecording() : startRecording()
    }

    private func startRecording() {
        isRecording = true
        updateTitle()

        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            if event.keyCode == 53 { // Escape
                self.stopRecording()
                return nil
            }
            if let newShortcut = StoredShortcut.from(event: event) {
                self.shortcut = newShortcut
                self.onShortcutRecorded?(newShortcut)
                self.stopRecording()
                return nil
            }
            return nil
        }

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowResigned),
            name: NSWindow.didResignKeyNotification,
            object: window
        )
    }

    private func stopRecording() {
        isRecording = false
        updateTitle()
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
        NotificationCenter.default.removeObserver(self, name: NSWindow.didResignKeyNotification, object: window)
    }

    @objc private func windowResigned() { stopRecording() }

    deinit { stopRecording() }
}
