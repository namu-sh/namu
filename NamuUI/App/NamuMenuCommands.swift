import SwiftUI

/// App menu bar commands for Namu.
/// Surfaces all features through standard macOS menus so they're discoverable
/// via keyboard shortcuts, VoiceOver, and the Help menu search.
struct NamuMenuCommands: Commands {
    var body: some Commands {
        // Replace default New Window command
        CommandGroup(replacing: .newItem) {
            Button(String(localized: "menu.file.newWorkspace", defaultValue: "New Workspace")) {
                NotificationCenter.default.post(name: .namuMenuNewWorkspace, object: nil)
            }
            .keyboardShortcut("n", modifiers: .command)

            Button(String(localized: "menu.file.newWindow", defaultValue: "New Window")) {
                NotificationCenter.default.post(name: .namuMenuNewWindow, object: nil)
            }
            .keyboardShortcut("n", modifiers: [.command, .shift])

            Divider()

            Button(String(localized: "menu.file.closeTab", defaultValue: "Close Tab")) {
                NotificationCenter.default.post(name: .namuMenuCloseTab, object: nil)
            }
            .keyboardShortcut("w", modifiers: .command)

            Button(String(localized: "menu.file.closeWorkspace", defaultValue: "Close Workspace")) {
                NotificationCenter.default.post(name: .namuMenuCloseWorkspace, object: nil)
            }
            .keyboardShortcut("w", modifiers: [.command, .shift])
        }

        // Add to existing View menu
        CommandGroup(after: .toolbar) {
            Divider()

            Button(String(localized: "menu.view.toggleSidebar", defaultValue: "Toggle Sidebar")) {
                NotificationCenter.default.post(name: .namuMenuToggleSidebar, object: nil)
            }
            .keyboardShortcut("b", modifiers: .command)

            Button(String(localized: "menu.view.notifications", defaultValue: "Notifications")) {
                NotificationCenter.default.post(name: .namuMenuShowNotifications, object: nil)
            }
            .keyboardShortcut("i", modifiers: [.command, .shift])

            Button(String(localized: "menu.view.jumpToUnread", defaultValue: "Jump to Unread")) {
                NotificationCenter.default.post(name: .namuMenuJumpToUnread, object: nil)
            }
            .keyboardShortcut("u", modifiers: [.command, .shift])

            Divider()

            Button(String(localized: "menu.view.commandPalette", defaultValue: "Command Palette")) {
                NotificationCenter.default.post(name: .namuMenuCommandPalette, object: nil)
            }
            .keyboardShortcut("k", modifiers: .command)
        }

        // Terminal menu
        CommandMenu(String(localized: "menu.terminal", defaultValue: "Terminal")) {
            Button(String(localized: "menu.terminal.newTab", defaultValue: "New Tab")) {
                NotificationCenter.default.post(name: .namuMenuNewTab, object: nil)
            }
            .keyboardShortcut("t", modifiers: .command)

            Button(String(localized: "menu.terminal.renameTab", defaultValue: "Rename Tab")) {
                NotificationCenter.default.post(name: .namuMenuRenameTab, object: nil)
            }
            .keyboardShortcut("r", modifiers: [.command, .option])

            Divider()

            Button(String(localized: "menu.terminal.splitRight", defaultValue: "Split Right")) {
                NotificationCenter.default.post(name: .namuMenuSplitRight, object: nil)
            }
            .keyboardShortcut("d", modifiers: .command)

            Button(String(localized: "menu.terminal.splitDown", defaultValue: "Split Down")) {
                NotificationCenter.default.post(name: .namuMenuSplitDown, object: nil)
            }
            .keyboardShortcut("d", modifiers: [.command, .shift])

            Button(String(localized: "menu.terminal.equalizeSplits", defaultValue: "Equalize Splits")) {
                NotificationCenter.default.post(name: .namuMenuEqualizeSplits, object: nil)
            }
            .keyboardShortcut("=", modifiers: [.command, .shift])

            Divider()

            Button(String(localized: "menu.terminal.zoomPane", defaultValue: "Zoom Pane")) {
                NotificationCenter.default.post(name: .namuMenuZoomPane, object: nil)
            }
            .keyboardShortcut(.return, modifiers: [.command, .shift])

            Button(String(localized: "menu.terminal.focusLeft", defaultValue: "Focus Pane Left")) {
                NotificationCenter.default.post(name: .namuMenuFocusPaneLeft, object: nil)
            }
            .keyboardShortcut(.leftArrow, modifiers: [.command, .option])

            Button(String(localized: "menu.terminal.focusRight", defaultValue: "Focus Pane Right")) {
                NotificationCenter.default.post(name: .namuMenuFocusPaneRight, object: nil)
            }
            .keyboardShortcut(.rightArrow, modifiers: [.command, .option])

            Button(String(localized: "menu.terminal.focusUp", defaultValue: "Focus Pane Up")) {
                NotificationCenter.default.post(name: .namuMenuFocusPaneUp, object: nil)
            }
            .keyboardShortcut(.upArrow, modifiers: [.command, .option])

            Button(String(localized: "menu.terminal.focusDown", defaultValue: "Focus Pane Down")) {
                NotificationCenter.default.post(name: .namuMenuFocusPaneDown, object: nil)
            }
            .keyboardShortcut(.downArrow, modifiers: [.command, .option])

            Divider()

            Button(String(localized: "menu.terminal.copyMode", defaultValue: "Copy Mode")) {
                NotificationCenter.default.post(name: .namuMenuCopyMode, object: nil)
            }
            .keyboardShortcut("c", modifiers: [.command, .shift, .option])

            Button(String(localized: "menu.terminal.clearScrollback", defaultValue: "Clear Scrollback")) {
                NotificationCenter.default.post(name: .namuMenuClearScrollback, object: nil)
            }
            .keyboardShortcut("k", modifiers: [.command, .shift])
        }

        // Window menu additions
        CommandGroup(after: .windowArrangement) {
            Divider()

            Button(String(localized: "menu.window.nextWorkspace", defaultValue: "Next Workspace")) {
                NotificationCenter.default.post(name: .namuMenuNextWorkspace, object: nil)
            }
            .keyboardShortcut("]", modifiers: [.command, .control])

            Button(String(localized: "menu.window.previousWorkspace", defaultValue: "Previous Workspace")) {
                NotificationCenter.default.post(name: .namuMenuPreviousWorkspace, object: nil)
            }
            .keyboardShortcut("[", modifiers: [.command, .control])
        }

        // Replace Help menu
        CommandGroup(replacing: .help) {
            Button(String(localized: "menu.help.keyboardShortcuts", defaultValue: "Keyboard Shortcuts")) {
                NotificationCenter.default.post(name: .namuMenuKeyboardShortcuts, object: nil)
            }

            Button(String(localized: "menu.help.sendFeedback", defaultValue: "Send Feedback")) {
                NotificationCenter.default.post(name: .namuMenuSendFeedback, object: nil)
            }
            .keyboardShortcut("/", modifiers: [.command, .shift])
        }

        // Settings handled in NamuApp.swift via CommandGroup(replacing: .appSettings)
    }
}

// MARK: - Menu Notification Names

extension Notification.Name {
    // File
    static let namuMenuNewWorkspace = Notification.Name("namu.menu.newWorkspace")
    static let namuMenuNewWindow = Notification.Name("namu.menu.newWindow")
    static let namuMenuCloseTab = Notification.Name("namu.menu.closeTab")
    static let namuMenuCloseWorkspace = Notification.Name("namu.menu.closeWorkspace")

    // View
    static let namuMenuToggleSidebar = Notification.Name("namu.menu.toggleSidebar")
    static let namuMenuShowNotifications = Notification.Name("namu.menu.showNotifications")
    static let namuMenuJumpToUnread = Notification.Name("namu.menu.jumpToUnread")
    static let namuMenuCommandPalette = Notification.Name("namu.menu.commandPalette")
    static let namuMenuToggleFullscreen = Notification.Name("namu.menu.toggleFullscreen")

    // Terminal
    static let namuMenuNewTab = Notification.Name("namu.menu.newTab")
    static let namuMenuRenameTab = Notification.Name("namu.menu.renameTab")
    static let namuMenuSplitRight = Notification.Name("namu.menu.splitRight")
    static let namuMenuSplitDown = Notification.Name("namu.menu.splitDown")
    static let namuMenuEqualizeSplits = Notification.Name("namu.menu.equalizeSplits")
    static let namuMenuZoomPane = Notification.Name("namu.menu.zoomPane")
    static let namuMenuFocusPaneLeft = Notification.Name("namu.menu.focusPaneLeft")
    static let namuMenuFocusPaneRight = Notification.Name("namu.menu.focusPaneRight")
    static let namuMenuFocusPaneUp = Notification.Name("namu.menu.focusPaneUp")
    static let namuMenuFocusPaneDown = Notification.Name("namu.menu.focusPaneDown")
    static let namuMenuCopyMode = Notification.Name("namu.menu.copyMode")
    static let namuMenuClearScrollback = Notification.Name("namu.menu.clearScrollback")

    // Window
    static let namuMenuNextWorkspace = Notification.Name("namu.menu.nextWorkspace")
    static let namuMenuPreviousWorkspace = Notification.Name("namu.menu.previousWorkspace")

    // Help
    static let namuMenuKeyboardShortcuts = Notification.Name("namu.menu.keyboardShortcuts")
    static let namuMenuSendFeedback = Notification.Name("namu.menu.sendFeedback")

    // Settings
    static let namuMenuOpenSettings = Notification.Name("namu.menu.openSettings")
    static let namuMenuReloadConfig = Notification.Name("namu.menu.reloadConfig")
}
