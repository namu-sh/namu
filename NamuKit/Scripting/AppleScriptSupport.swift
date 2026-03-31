import AppKit

// MARK: - Error strings

private enum AppleScriptStrings {
    static let windowUnavailable = String(
        localized: "applescript.error.windowUnavailable",
        defaultValue: "Window is no longer available."
    )
    static let workspaceUnavailable = String(
        localized: "applescript.error.workspaceUnavailable",
        defaultValue: "Workspace is no longer available."
    )
    static let terminalUnavailable = String(
        localized: "applescript.error.terminalUnavailable",
        defaultValue: "Terminal is no longer available."
    )
    static let failedToCreateWindow = String(
        localized: "applescript.error.failedToCreateWindow",
        defaultValue: "Failed to create window."
    )
    static let failedToCreateWorkspace = String(
        localized: "applescript.error.failedToCreateWorkspace",
        defaultValue: "Failed to create workspace."
    )
    static let failedToCreateSplit = String(
        localized: "applescript.error.failedToCreateSplit",
        defaultValue: "Failed to create split."
    )
    static let missingInputText = String(
        localized: "applescript.error.missingInputText",
        defaultValue: "Missing input text."
    )
    static let missingTerminalTarget = String(
        localized: "applescript.error.missingTerminalTarget",
        defaultValue: "Missing terminal target."
    )
    static let missingSplitDirection = String(
        localized: "applescript.error.missingSplitDirection",
        defaultValue: "Missing or unknown split direction."
    )
}

// MARK: - Four-char code helper

private extension String {
    var fourCharCode: UInt32 {
        utf8.reduce(0) { ($0 << 8) + UInt32($1) }
    }
}

// MARK: - NSApplication extensions

@MainActor
extension NSApplication {

    @objc(scriptWindows)
    var scriptWindows: [NamuScriptWindow] {
        guard let delegate = AppDelegate.shared else { return [] }
        return delegate.windowContexts.keys.map { NamuScriptWindow(windowID: $0) }
    }

    @objc(frontWindow)
    var frontWindow: NamuScriptWindow? {
        scriptWindows.first
    }

    @objc(valueInScriptWindowsWithUniqueID:)
    func valueInScriptWindows(uniqueID: String) -> NamuScriptWindow? {
        guard let id = UUID(uuidString: uniqueID),
              AppDelegate.shared?.windowContexts[id] != nil else { return nil }
        return NamuScriptWindow(windowID: id)
    }

    @objc(terminals)
    var terminals: [NamuScriptTerminal] {
        guard let delegate = AppDelegate.shared else { return [] }
        return delegate.windowContexts.values.flatMap { ctx in
            ctx.workspaceManager.workspaces.flatMap { ws in
                ctx.panelManager.allPanelIDs(in: ws.id).map {
                    NamuScriptTerminal(workspaceID: ws.id, terminalID: $0)
                }
            }
        }
    }

    @objc(valueInTerminalsWithUniqueID:)
    func valueInTerminals(uniqueID: String) -> NamuScriptTerminal? {
        guard let terminalID = UUID(uuidString: uniqueID),
              let delegate = AppDelegate.shared else { return nil }
        for ctx in delegate.windowContexts.values {
            for ws in ctx.workspaceManager.workspaces {
                if ctx.panelManager.allPanelIDs(in: ws.id).contains(terminalID) {
                    return NamuScriptTerminal(workspaceID: ws.id, terminalID: terminalID)
                }
            }
        }
        return nil
    }

    @objc(handleNewWindowScriptCommand:)
    func handleNewWindowScriptCommand(_ command: NSScriptCommand) -> NamuScriptWindow? {
        guard let delegate = AppDelegate.shared else {
            command.scriptErrorNumber = errAEEventFailed
            command.scriptErrorString = AppleScriptStrings.failedToCreateWindow
            return nil
        }
        // Snapshot existing window IDs before creating so we can identify the new one.
        let existingIDs = Set(delegate.windowContexts.keys)
        _ = delegate.createMainWindow()
        let newID = delegate.windowContexts.keys.first(where: { !existingIDs.contains($0) })
        guard let windowID = newID else {
            command.scriptErrorNumber = errAEEventFailed
            command.scriptErrorString = AppleScriptStrings.failedToCreateWindow
            return nil
        }
        return NamuScriptWindow(windowID: windowID)
    }

    @objc(handleQuitScriptCommand:)
    func handleQuitScriptCommand(_ command: NSScriptCommand) {
        terminate(nil)
    }

    @objc(handlePerformActionScriptCommand:)
    func handlePerformActionScriptCommand(_ command: NSScriptCommand) -> Any? {
        guard let action = command.directParameter as? String, !action.isEmpty else {
            command.scriptErrorNumber = errAEParamMissed
            command.scriptErrorString = "Missing action string."
            return nil
        }
        guard let delegate = AppDelegate.shared,
              let ctx = delegate.windowContexts.values.first,
              let wsID = ctx.workspaceManager.selectedWorkspaceID,
              let panelID = ctx.panelManager.focusedPanelID(in: wsID),
              let session = ctx.panelManager.panels[panelID]?.session else {
            command.scriptErrorNumber = errAEEventFailed
            command.scriptErrorString = AppleScriptStrings.terminalUnavailable
            return nil
        }
        if !session.sendNamedKey(action) {
            session.sendText(action)
        }
        return nil
    }
}

// MARK: - NamuScriptWindow

@MainActor
@objc(NamuScriptWindow)
final class NamuScriptWindow: NSObject {
    let windowID: UUID

    init(windowID: UUID) {
        self.windowID = windowID
    }

    private var context: WindowContext? {
        AppDelegate.shared?.windowContexts[windowID]
    }

    @objc(id)
    var idValue: String { windowID.uuidString }

    @objc(title)
    var title: String {
        context?.workspaceManager.selectedWorkspace?.title ?? ""
    }

    @objc(workspaces)
    var workspaces: [NamuScriptWorkspace] {
        guard let ctx = context else { return [] }
        return ctx.workspaceManager.workspaces.map {
            NamuScriptWorkspace(windowID: windowID, workspaceID: $0.id)
        }
    }

    @objc(selectedWorkspace)
    var selectedWorkspace: NamuScriptWorkspace? {
        guard let ctx = context,
              let selectedID = ctx.workspaceManager.selectedWorkspaceID else { return nil }
        return NamuScriptWorkspace(windowID: windowID, workspaceID: selectedID)
    }

    @objc(terminals)
    var terminals: [NamuScriptTerminal] {
        guard let ctx = context else { return [] }
        return ctx.workspaceManager.workspaces.flatMap { ws in
            ctx.panelManager.allPanelIDs(in: ws.id).map {
                NamuScriptTerminal(workspaceID: ws.id, terminalID: $0)
            }
        }
    }

    @objc(valueInWorkspacesWithUniqueID:)
    func valueInWorkspaces(uniqueID: String) -> NamuScriptWorkspace? {
        guard let wsID = UUID(uuidString: uniqueID),
              context?.workspaceManager.workspaces.contains(where: { $0.id == wsID }) == true else {
            return nil
        }
        return NamuScriptWorkspace(windowID: windowID, workspaceID: wsID)
    }

    @objc(handleActivateWindowCommand:)
    func handleActivateWindow(_ command: NSScriptCommand) -> Any? {
        guard context != nil else {
            command.scriptErrorNumber = errAEEventFailed
            command.scriptErrorString = AppleScriptStrings.windowUnavailable
            return nil
        }
        let nsWindow = NSApp.windows.first {
            $0.identifier?.rawValue.contains(windowID.uuidString) == true
        }
        nsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        return nil
    }

    @objc(handleCloseWindowCommand:)
    func handleCloseWindow(_ command: NSScriptCommand) -> Any? {
        guard context != nil else {
            command.scriptErrorNumber = errAEEventFailed
            command.scriptErrorString = AppleScriptStrings.windowUnavailable
            return nil
        }
        let nsWindow = NSApp.windows.first {
            $0.identifier?.rawValue.contains(windowID.uuidString) == true
        }
        nsWindow?.performClose(nil)
        return nil
    }

    override var objectSpecifier: NSScriptObjectSpecifier? {
        guard let appClassDescription = NSApplication.shared.classDescription as? NSScriptClassDescription else {
            return nil
        }
        return NSUniqueIDSpecifier(
            containerClassDescription: appClassDescription,
            containerSpecifier: nil,
            key: "scriptWindows",
            uniqueID: windowID.uuidString
        )
    }
}

// MARK: - NamuScriptWorkspace

@MainActor
@objc(NamuScriptWorkspace)
final class NamuScriptWorkspace: NSObject {
    let windowID: UUID
    let workspaceID: UUID

    init(windowID: UUID, workspaceID: UUID) {
        self.windowID = windowID
        self.workspaceID = workspaceID
    }

    private var context: WindowContext? {
        AppDelegate.shared?.windowContexts[windowID]
    }

    private var workspace: Workspace? {
        context?.workspaceManager.workspaces.first(where: { $0.id == workspaceID })
    }

    @objc(id)
    var idValue: String { workspaceID.uuidString }

    @objc(title)
    var title: String { workspace?.title ?? "" }

    @objc(index)
    var index: Int {
        guard let ctx = context,
              let idx = ctx.workspaceManager.workspaces.firstIndex(where: { $0.id == workspaceID }) else {
            return 0
        }
        return idx + 1
    }

    @objc(selected)
    var selected: Bool {
        context?.workspaceManager.selectedWorkspaceID == workspaceID
    }

    @objc(terminals)
    var terminals: [NamuScriptTerminal] {
        guard let ctx = context else { return [] }
        return ctx.panelManager.allPanelIDs(in: workspaceID).map {
            NamuScriptTerminal(workspaceID: workspaceID, terminalID: $0)
        }
    }

    @objc(valueInTerminalsWithUniqueID:)
    func valueInTerminals(uniqueID: String) -> NamuScriptTerminal? {
        guard let terminalID = UUID(uuidString: uniqueID),
              let ctx = context,
              ctx.panelManager.allPanelIDs(in: workspaceID).contains(terminalID) else {
            return nil
        }
        return NamuScriptTerminal(workspaceID: workspaceID, terminalID: terminalID)
    }

    @objc(handleSelectWorkspaceCommand:)
    func handleSelectWorkspace(_ command: NSScriptCommand) -> Any? {
        guard let ctx = context, workspace != nil else {
            command.scriptErrorNumber = errAEEventFailed
            command.scriptErrorString = AppleScriptStrings.workspaceUnavailable
            return nil
        }
        ctx.workspaceManager.selectWorkspace(id: workspaceID)
        return nil
    }

    @objc(handleCloseWorkspaceCommand:)
    func handleCloseWorkspace(_ command: NSScriptCommand) -> Any? {
        guard let ctx = context, workspace != nil else {
            command.scriptErrorNumber = errAEEventFailed
            command.scriptErrorString = AppleScriptStrings.workspaceUnavailable
            return nil
        }
        if ctx.workspaceManager.workspaces.count > 1 {
            ctx.workspaceManager.deleteWorkspace(id: workspaceID)
        } else {
            let nsWindow = NSApp.windows.first {
                $0.identifier?.rawValue.contains(windowID.uuidString) == true
            }
            nsWindow?.performClose(nil)
        }
        return nil
    }

    override var objectSpecifier: NSScriptObjectSpecifier? {
        let scriptWindow = NamuScriptWindow(windowID: windowID)
        guard let windowClassDescription = scriptWindow.classDescription as? NSScriptClassDescription,
              let windowSpecifier = scriptWindow.objectSpecifier else {
            return nil
        }
        return NSUniqueIDSpecifier(
            containerClassDescription: windowClassDescription,
            containerSpecifier: windowSpecifier,
            key: "workspaces",
            uniqueID: workspaceID.uuidString
        )
    }
}

// MARK: - NamuScriptTerminal

@MainActor
@objc(NamuScriptTerminal)
final class NamuScriptTerminal: NSObject {
    let workspaceID: UUID
    let terminalID: UUID

    init(workspaceID: UUID, terminalID: UUID) {
        self.workspaceID = workspaceID
        self.terminalID = terminalID
    }

    private var context: WindowContext? {
        guard let delegate = AppDelegate.shared else { return nil }
        return delegate.windowContexts.values.first {
            $0.workspaceManager.workspaces.contains(where: { $0.id == workspaceID })
        }
    }

    @objc(id)
    var idValue: String { terminalID.uuidString }

    @objc(title)
    var title: String {
        context?.panelManager.panels[terminalID]?.title ?? ""
    }

    @objc(workingDirectory)
    var workingDirectory: String {
        context?.panelManager.panels[terminalID]?.workingDirectory ?? ""
    }

    @objc(handleInputTextCommand:)
    func handleInputText(_ command: NSScriptCommand) -> Any? {
        guard let text = command.directParameter as? String else {
            command.scriptErrorNumber = errAEParamMissed
            command.scriptErrorString = AppleScriptStrings.missingInputText
            return nil
        }
        guard let ctx = context,
              ctx.panelManager.allPanelIDs(in: workspaceID).contains(terminalID) else {
            command.scriptErrorNumber = errAEEventFailed
            command.scriptErrorString = AppleScriptStrings.terminalUnavailable
            return nil
        }
        ctx.panelManager.panels[terminalID]?.session.sendText(text)
        return nil
    }

    @objc(handleSplitCommand:)
    func handleSplit(_ command: NSScriptCommand) -> Any? {
        guard let directionCode = command.evaluatedArguments?["direction"] as? UInt32,
              let direction = NamuScriptSplitDirection(code: directionCode)?.splitDirection else {
            command.scriptErrorNumber = errAEParamMissed
            command.scriptErrorString = AppleScriptStrings.missingSplitDirection
            return nil
        }

        guard let ctx = context,
              ctx.panelManager.allPanelIDs(in: workspaceID).contains(terminalID) else {
            command.scriptErrorNumber = errAEEventFailed
            command.scriptErrorString = AppleScriptStrings.terminalUnavailable
            return nil
        }

        // Snapshot panel IDs before split so we can identify the new one.
        let before = Set(ctx.panelManager.allPanelIDs(in: workspaceID))
        ctx.panelManager.splitPane(in: workspaceID, direction: direction)
        let after = Set(ctx.panelManager.allPanelIDs(in: workspaceID))
        guard let newID = after.subtracting(before).first else {
            command.scriptErrorNumber = errAEEventFailed
            command.scriptErrorString = AppleScriptStrings.failedToCreateSplit
            return nil
        }

        return NamuScriptTerminal(workspaceID: workspaceID, terminalID: newID)
    }

    @objc(handleFocusCommand:)
    func handleFocus(_ command: NSScriptCommand) -> Any? {
        guard let ctx = context,
              ctx.panelManager.allPanelIDs(in: workspaceID).contains(terminalID) else {
            command.scriptErrorNumber = errAEEventFailed
            command.scriptErrorString = AppleScriptStrings.terminalUnavailable
            return nil
        }
        ctx.workspaceManager.selectWorkspace(id: workspaceID)
        ctx.panelManager.activatePanel(id: terminalID)
        return nil
    }

    override var objectSpecifier: NSScriptObjectSpecifier? {
        guard let appClassDescription = NSApplication.shared.classDescription as? NSScriptClassDescription else {
            return nil
        }
        return NSUniqueIDSpecifier(
            containerClassDescription: appClassDescription,
            containerSpecifier: nil,
            key: "terminals",
            uniqueID: terminalID.uuidString
        )
    }
}

// MARK: - NamuScriptInputTextCommand

@MainActor
@objc(NamuScriptInputTextCommand)
final class NamuScriptInputTextCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        guard let text = directParameter as? String else {
            scriptErrorNumber = errAEParamMissed
            scriptErrorString = AppleScriptStrings.missingInputText
            return nil
        }

        guard let terminal = evaluatedArguments?["terminal"] as? NamuScriptTerminal else {
            scriptErrorNumber = errAEParamMissed
            scriptErrorString = AppleScriptStrings.missingTerminalTarget
            return nil
        }

        guard let ctx = AppDelegate.shared?.windowContexts.values.first(where: {
                  $0.workspaceManager.workspaces.contains(where: { $0.id == terminal.workspaceID })
              }),
              ctx.panelManager.allPanelIDs(in: terminal.workspaceID).contains(terminal.terminalID) else {
            scriptErrorNumber = errAEEventFailed
            scriptErrorString = AppleScriptStrings.terminalUnavailable
            return nil
        }

        ctx.panelManager.panels[terminal.terminalID]?.session.sendText(text)
        return nil
    }
}

// MARK: - Split direction

private enum NamuScriptSplitDirection {
    case right, left, down, up

    init?(code: UInt32) {
        switch code {
        case "NMrt".fourCharCode: self = .right
        case "NMlf".fourCharCode: self = .left
        case "NMdn".fourCharCode: self = .down
        case "NMup".fourCharCode: self = .up
        default: return nil
        }
    }

    var splitDirection: SplitDirection {
        switch self {
        case .right: return .horizontal
        case .left:  return .horizontal
        case .down:  return .vertical
        case .up:    return .vertical
        }
    }
}
