import Foundation
import Combine
import AppKit
import UserNotifications

// MARK: - InAppNotification

/// A single in-app notification entry.
struct InAppNotification: Identifiable, Sendable {
    let id: UUID
    let title: String
    let body: String
    let workspaceID: UUID?
    let panelID: UUID?
    let createdAt: Date
    var isRead: Bool

    init(
        id: UUID = UUID(),
        title: String,
        body: String,
        workspaceID: UUID? = nil,
        panelID: UUID? = nil,
        createdAt: Date = Date(),
        isRead: Bool = false
    ) {
        self.id = id
        self.title = title
        self.body = body
        self.workspaceID = workspaceID
        self.panelID = panelID
        self.createdAt = createdAt
        self.isRead = isRead
    }
}

// MARK: - NotificationService

/// In-app notification ring system.
///
/// Ring hierarchy (matching Namu patterns):
///   global   → updates unread count for the whole app (dock badge)
///   workspace → sidebar badge on the relevant workspace tab
///   pane      → ring indicator on the pane that triggered the notification
///
/// The ring has a bounded capacity: oldest notifications are dropped when the ring is full.
// MARK: - NotificationSound

enum NotificationSound: Codable, Equatable {
    case none
    case system
    case glass
    case ping
    case pop
    case purr
    case basso
    case blow
    case bottle
    case frog
    case funk
    case hero
    case morse
    case sosumi
    case submarine
    case tink
    /// A custom sound file at the given absolute path.
    case custom(String)

    // MARK: - CaseIterable-like enumeration of non-custom cases

    static let allBuiltIn: [NotificationSound] = [
        .none, .system, .glass, .ping, .pop, .purr,
        .basso, .blow, .bottle, .frog, .funk, .hero, .morse, .sosumi, .submarine, .tink,
    ]

    // MARK: - Display name

    var displayName: String {
        switch self {
        case .none:      return String(localized: "notification.sound.none", defaultValue: "None")
        case .system:    return String(localized: "notification.sound.system", defaultValue: "System Default")
        case .glass:     return "Glass"
        case .ping:      return "Ping"
        case .pop:       return "Pop"
        case .purr:      return "Purr"
        case .basso:     return "Basso"
        case .blow:      return "Blow"
        case .bottle:    return "Bottle"
        case .frog:      return "Frog"
        case .funk:      return "Funk"
        case .hero:      return "Hero"
        case .morse:     return "Morse"
        case .sosumi:    return "Sosumi"
        case .submarine: return "Submarine"
        case .tink:      return "Tink"
        case .custom(let path): return URL(fileURLWithPath: path).lastPathComponent
        }
    }

    /// NSSound name for macOS system sounds (nil = use NSSound.beep or custom path).
    var soundName: String? {
        switch self {
        case .none:      return nil
        case .system:    return nil  // triggers NSSound.beep()
        case .glass:     return "Glass"
        case .ping:      return "Ping"
        case .pop:       return "Pop"
        case .purr:      return "Purr"
        case .basso:     return "Basso"
        case .blow:      return "Blow"
        case .bottle:    return "Bottle"
        case .frog:      return "Frog"
        case .funk:      return "Funk"
        case .hero:      return "Hero"
        case .morse:     return "Morse"
        case .sosumi:    return "Sosumi"
        case .submarine: return "Submarine"
        case .tink:      return "Tink"
        case .custom:    return nil
        }
    }

    /// For .custom, validates that the file exists and is readable.
    var isCustomFileValid: Bool {
        guard case .custom(let path) = self else { return true }
        return FileManager.default.isReadableFile(atPath: path)
    }

    // MARK: - Codable

    enum CodingKeys: String, CodingKey { case type, path }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let type = try c.decode(String.self, forKey: .type)
        switch type {
        case "none":      self = .none
        case "system":    self = .system
        case "glass":     self = .glass
        case "ping":      self = .ping
        case "pop":       self = .pop
        case "purr":      self = .purr
        case "basso":     self = .basso
        case "blow":      self = .blow
        case "bottle":    self = .bottle
        case "frog":      self = .frog
        case "funk":      self = .funk
        case "hero":      self = .hero
        case "morse":     self = .morse
        case "sosumi":    self = .sosumi
        case "submarine": self = .submarine
        case "tink":      self = .tink
        case "custom":
            let path = try c.decode(String.self, forKey: .path)
            self = .custom(path)
        default:          self = .system
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .none:      try c.encode("none",      forKey: .type)
        case .system:    try c.encode("system",    forKey: .type)
        case .glass:     try c.encode("glass",     forKey: .type)
        case .ping:      try c.encode("ping",      forKey: .type)
        case .pop:       try c.encode("pop",       forKey: .type)
        case .purr:      try c.encode("purr",      forKey: .type)
        case .basso:     try c.encode("basso",     forKey: .type)
        case .blow:      try c.encode("blow",      forKey: .type)
        case .bottle:    try c.encode("bottle",    forKey: .type)
        case .frog:      try c.encode("frog",      forKey: .type)
        case .funk:      try c.encode("funk",      forKey: .type)
        case .hero:      try c.encode("hero",      forKey: .type)
        case .morse:     try c.encode("morse",     forKey: .type)
        case .sosumi:    try c.encode("sosumi",    forKey: .type)
        case .submarine: try c.encode("submarine", forKey: .type)
        case .tink:      try c.encode("tink",      forKey: .type)
        case .custom(let path):
            try c.encode("custom", forKey: .type)
            try c.encode(path,     forKey: .path)
        }
    }
}

// MARK: - NotificationAuthorizationState

/// Tracks the current macOS notification authorization state.
enum NotificationAuthorizationState: Equatable {
    case unknown
    case notDetermined
    case authorized
    case denied
    case provisional
    case ephemeral
}

// MARK: - NotificationBadgeSettings

/// Controls whether the dock badge is shown for unread notifications.
enum NotificationBadgeSettings {
    static let key = "namu.dockBadgeEnabled"

    static func isDockBadgeEnabled(defaults: UserDefaults = .standard) -> Bool {
        if defaults.object(forKey: key) == nil { return true }  // default true
        return defaults.bool(forKey: key)
    }

    static func setDockBadgeEnabled(_ enabled: Bool, defaults: UserDefaults = .standard) {
        defaults.set(enabled, forKey: key)
    }
}

// MARK: - TaggedRunBadgeSettings

/// Reads the NAMU_TAG environment variable (max 10 chars) for dock badge prefix.
enum TaggedRunBadgeSettings {
    /// The tag string from NAMU_TAG, truncated to 10 characters, or nil if not set.
    static var tag: String? {
        guard let raw = ProcessInfo.processInfo.environment["NAMU_TAG"],
              !raw.isEmpty else { return nil }
        let truncated = String(raw.prefix(10))
        return truncated
    }
}

// MARK: - NotificationCustomCommandSettings

/// Stores an optional shell command to run whenever a notification fires.
/// The command receives notification context via environment variables:
///   NAMU_NOTIFICATION_TITLE, NAMU_NOTIFICATION_BODY, NAMU_WORKSPACE_ID
enum NotificationCustomCommandSettings {
    static let key = "namu.notificationCustomCommand"

    static func command(defaults: UserDefaults = .standard) -> String? {
        let raw = defaults.string(forKey: key)
        return (raw?.isEmpty == false) ? raw : nil
    }

    static func setCommand(_ command: String?, defaults: UserDefaults = .standard) {
        defaults.set(command, forKey: key)
    }
}

// MARK: - NotificationService

@MainActor
final class NotificationService: ObservableObject {

    // MARK: - Configuration

    /// Maximum number of notifications retained in the ring.
    static let ringCapacity = 256

    /// Notification category identifier for desktop notifications.
    static let notificationCategoryID = "namu.notification"
    /// Action identifier for the "Show" action on desktop notifications.
    static let showActionID = "namu.notification.show"

    // MARK: - Sound preference

    private var _cachedSound: NotificationSound?

    var notificationSound: NotificationSound {
        get {
            if let cached = _cachedSound { return cached }
            let resolved: NotificationSound
            if let data = UserDefaults.standard.data(forKey: "namu.notificationSound"),
               let decoded = try? JSONDecoder().decode(NotificationSound.self, from: data) {
                resolved = decoded
            } else if let raw = UserDefaults.standard.string(forKey: "namu.notificationSound") {
                // Legacy migration: raw string values from old enum.
                switch raw {
                case "None":           resolved = .none
                case "Glass":          resolved = .glass
                case "Ping":           resolved = .ping
                case "Pop":            resolved = .pop
                case "Purr":           resolved = .purr
                default:               resolved = .system
                }
            } else {
                resolved = .system
            }
            _cachedSound = resolved
            return resolved
        }
        set {
            _cachedSound = newValue
            if let data = try? JSONEncoder().encode(newValue) {
                UserDefaults.standard.set(data, forKey: "namu.notificationSound")
            }
        }
    }

    // MARK: - Published state

    @Published private(set) var allNotifications: [InAppNotification] = []
    @Published private(set) var authorizationState: NotificationAuthorizationState = .unknown

    /// Set of visible panel IDs — used for focus suppression of desktop notifications.
    /// Updated by PanelManager when the visible pane set changes.
    var visiblePanelIDs: Set<UUID> = []

    /// Returns the currently focused panel ID in the key window, or nil if unknown.
    /// Wired by ServiceContainer so postDesktopNotification can perform precise suppression.
    var keyWindowFocusedPanelID: (() -> UUID?)? = nil

    // MARK: - Computed

    var unreadCount: Int {
        allNotifications.filter { !$0.isRead }.count
    }

    func unreadCountForWorkspace(_ workspaceID: UUID) -> Int {
        allNotifications.filter { !$0.isRead && $0.workspaceID == workspaceID }.count
    }

    func unreadCountForPanel(_ panelID: UUID) -> Int {
        allNotifications.filter { !$0.isRead && $0.panelID == panelID }.count
    }

    // MARK: - Create

    /// Suppress window for duplicate notifications (same title+body within this interval).
    static let deduplicationInterval: TimeInterval = 2.0

    /// Add a notification to the ring. Drops the oldest entry if at capacity.
    /// Suppresses exact duplicates (same title+body) within `deduplicationInterval` seconds.
    @discardableResult
    func create(
        title: String,
        body: String,
        workspaceID: UUID? = nil,
        panelID: UUID? = nil
    ) -> InAppNotification {
        // Suppress duplicate notifications within the deduplication window.
        let now = Date()
        if let recent = allNotifications.last(where: { $0.title == title && $0.body == body }),
           now.timeIntervalSince(recent.createdAt) < Self.deduplicationInterval {
            return recent
        }

        let notification = InAppNotification(
            title: title,
            body: body,
            workspaceID: workspaceID,
            panelID: panelID
        )

        if allNotifications.count >= Self.ringCapacity {
            allNotifications.removeFirst()
        }
        allNotifications.append(notification)
        NamuMetrics.notificationCreated()
        NamuMetrics.notificationUnreadCount(unreadCount)
        playSound()
        runCustomCommand(for: notification)
        updateDockBadge()

        // Auto-reorder: move workspace to top if enabled and a workspace was specified.
        if let workspaceID, WorkspaceAutoReorderSettings.isEnabled() {
            NotificationCenter.default.post(
                name: .namuWorkspaceAutoReorderRequested,
                object: nil,
                userInfo: ["workspace_id": workspaceID]
            )
        }

        // Notify the pane to show attention ring.
        NotificationCenter.default.post(
            name: .namuPaneAttentionRequested,
            object: nil,
            userInfo: [
                "workspace_id": workspaceID as Any,
                "panel_id": panelID as Any
            ]
        )

        return notification
    }

    // MARK: - Terminal notifications

    /// Handle a terminal OSC desktop notification. Checks if the workspace has an
    /// active Claude session and suppresses if so (Claude hooks handle those).
    @discardableResult
    func handleTerminalNotification(
        title: String,
        body: String,
        workspaceManager: WorkspaceManager
    ) -> InAppNotification? {
        // Check if the selected workspace has any active agent sessions.
        if let wsID = workspaceManager.selectedWorkspaceID,
           let ws = workspaceManager.workspaces.first(where: { $0.id == wsID }),
           !ws.agentPIDs.isEmpty {
            return nil
        }

        let notification = create(
            title: title.isEmpty ? "Terminal" : title,
            body: body,
            workspaceID: workspaceManager.selectedWorkspaceID
        )
        postDesktopNotification(
            title: title.isEmpty ? "Terminal" : title,
            body: body,
            panelID: notification.panelID
        )
        return notification
    }

    // MARK: - Authorization

    private static let hasRequestedAuthKey = "namu.hasRequestedAutomaticAuthorization"

    /// Whether we have already issued the automatic authorization prompt this install.
    var hasRequestedAutomaticAuthorization: Bool {
        get { UserDefaults.standard.bool(forKey: Self.hasRequestedAuthKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.hasRequestedAuthKey) }
    }

    /// Request macOS notification permission and register notification category with "Show" action.
    ///
    /// If the app is currently running in background activation policy (e.g. launched as agent),
    /// the request is deferred until the app transitions to foreground. This avoids an invisible
    /// system prompt that the user can never interact with.
    ///
    /// Safe to call multiple times — UNUserNotificationCenter only prompts the user once;
    /// subsequent calls return the existing authorization status without re-prompting.
    func requestAuthorization() {
        // Defer if running in background — wait for app to become foreground first.
        if NSApp.activationPolicy() != .regular {
            let observer = NotificationCenter.default.addObserver(
                forName: NSApplication.didBecomeActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.performAuthorization()
            }
            // Store observer so it can be cleaned up; fire once and release.
            _ = observer  // retained by NotificationCenter until fired
            return
        }
        performAuthorization()
    }

    private func performAuthorization() {
        registerNotificationCategory()
        hasRequestedAutomaticAuthorization = true
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { [weak self] granted, error in
            if let error {
                print("[NotificationService] Authorization error: \(error)")
            }
            Task { @MainActor [weak self] in
                self?.refreshAuthorizationState()
            }
        }
    }

    /// Show an NSAlert prompting the user to open System Settings > Notifications
    /// when notification permission has been denied. No-op if not on main thread.
    @MainActor
    func promptToOpenSettings() {
        let alert = NSAlert()
        alert.messageText = String(
            localized: "notification.denied.alert.title",
            defaultValue: "Notifications Disabled"
        )
        alert.informativeText = String(
            localized: "notification.denied.alert.body",
            defaultValue: "Namu needs notification permission to alert you about terminal activity. Open System Settings > Notifications > Namu to enable them."
        )
        alert.addButton(withTitle: String(
            localized: "notification.denied.alert.openSettings",
            defaultValue: "Open Settings"
        ))
        alert.addButton(withTitle: String(
            localized: "notification.denied.alert.cancel",
            defaultValue: "Cancel"
        ))
        alert.alertStyle = .warning
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.notifications") {
                NSWorkspace.shared.open(url)
            }
        }
    }

    /// Post a test notification to verify notification setup is working.
    /// Intended for use from the Settings UI.
    func sendTestNotification() {
        postDesktopNotification(
            title: String(localized: "notification.test.title", defaultValue: "Test Notification"),
            body: String(localized: "notification.test.body", defaultValue: "Namu notifications are working correctly.")
        )
    }

    /// Re-query and publish the current authorization state.
    func refreshAuthorizationState() {
        UNUserNotificationCenter.current().getNotificationSettings { [weak self] settings in
            Task { @MainActor [weak self] in
                guard let self else { return }
                switch settings.authorizationStatus {
                case .notDetermined: self.authorizationState = .notDetermined
                case .denied:        self.authorizationState = .denied
                case .authorized:    self.authorizationState = .authorized
                case .provisional:   self.authorizationState = .provisional
                case .ephemeral:     self.authorizationState = .ephemeral
                @unknown default:    self.authorizationState = .unknown
                }
            }
        }
    }

    /// Register the notification category with a "Show" action (once per launch).
    func registerNotificationCategory() {
        let showAction = UNNotificationAction(
            identifier: Self.showActionID,
            title: String(localized: "notification.action.show", defaultValue: "Show"),
            options: [.foreground]
        )
        let category = UNNotificationCategory(
            identifier: Self.notificationCategoryID,
            actions: [showAction],
            intentIdentifiers: [],
            options: []
        )
        UNUserNotificationCenter.current().setNotificationCategories([category])
    }

    // MARK: - Desktop notification

    /// Post a desktop (UNUserNotification) notification.
    /// Suppresses delivery when the app is active and the notified panel is currently visible.
    func postDesktopNotification(title: String, body: String, panelID: UUID? = nil) {
        // Focus suppression: skip desktop notification only when a namu window is key
        // and the notified panel is both visible and currently focused in that window.
        if NSApp.isActive,
           let panelID,
           visiblePanelIDs.contains(panelID),
           let keyWindow = NSApp.keyWindow,
           keyWindow.identifier?.rawValue.hasPrefix("namu") == true,
           keyWindowFocusedPanelID?() == panelID {
            return
        }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.categoryIdentifier = Self.notificationCategoryID
        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
    }

    // MARK: - Off-main removal helpers

    /// Remove delivered desktop notifications for the given workspace (non-blocking).
    func removeDeliveredNotifications(forWorkspaceID workspaceID: UUID) {
        UNUserNotificationCenter.current().getDeliveredNotifications { notifications in
            let ids = notifications
                .filter { $0.request.content.userInfo["workspace_id"] as? String == workspaceID.uuidString }
                .map { $0.request.identifier }
            guard !ids.isEmpty else { return }
            UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ids)
        }
    }

    /// Remove all delivered desktop notifications (non-blocking).
    func removeAllDeliveredNotifications() {
        UNUserNotificationCenter.current().removeAllDeliveredNotifications()
    }

    // MARK: - Dock badge

    private func updateDockBadge() {
        guard NotificationBadgeSettings.isDockBadgeEnabled() else {
            NSApp.dockTile.badgeLabel = nil
            return
        }
        let count = unreadCount
        guard count > 0 else {
            NSApp.dockTile.badgeLabel = nil
            return
        }
        let countLabel = count > 99 ? "99+" : "\(count)"
        if let tag = TaggedRunBadgeSettings.tag {
            NSApp.dockTile.badgeLabel = "\(tag):\(countLabel)"
        } else {
            NSApp.dockTile.badgeLabel = countLabel
        }
    }

    // MARK: - Audio

    /// Maps source file path to its last-known modification date (for transcoding cache invalidation).
    private var transcodedSourceModDates: [String: Date] = [:]

    /// Returns a playable URL for the given sound file path.
    /// Native formats (aif/aiff/caf/wav) are returned as-is.
    /// Other formats are transcoded to CAF via afconvert and cached in ~/Library/Sounds.
    private func transcodeSoundIfNeeded(path: String) -> URL? {
        let sourceURL = URL(fileURLWithPath: path)
        let ext = sourceURL.pathExtension.lowercased()
        let nativeExtensions = ["aif", "aiff", "caf", "wav"]
        if nativeExtensions.contains(ext) {
            return sourceURL
        }

        // Compute a stable output filename using a hash of the source path.
        let hash = abs(path.hashValue)
        let outputFilename = "namu_custom_\(hash).caf"
        let soundsDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Sounds")
        let outputURL = soundsDir.appendingPathComponent(outputFilename)

        // Check source modification date to skip re-transcoding unchanged files.
        let currentModDate = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
        if let cachedDate = transcodedSourceModDates[path],
           let currentModDate,
           cachedDate == currentModDate,
           FileManager.default.fileExists(atPath: outputURL.path) {
            return outputURL
        }

        // Ensure output directory exists.
        try? FileManager.default.createDirectory(at: soundsDir, withIntermediateDirectories: true)

        // Remove stale output if present.
        try? FileManager.default.removeItem(at: outputURL)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/afconvert")
        process.arguments = ["-f", "caff", "-d", "LEI16", path, outputURL.path]
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }

        guard process.terminationStatus == 0,
              FileManager.default.fileExists(atPath: outputURL.path) else {
            return nil
        }

        // Cache the mod date so we skip this file next time if unchanged.
        transcodedSourceModDates[path] = currentModDate
        return outputURL
    }

    private func playSound() {
        let sound = notificationSound
        switch sound {
        case .none:
            return
        case .system:
            NSSound.beep()
        case .custom(let path):
            guard sound.isCustomFileValid else { return }
            if let url = transcodeSoundIfNeeded(path: path) {
                NSSound(contentsOf: url, byReference: false)?.play()
            }
        default:
            if let name = sound.soundName, let nsSound = NSSound(named: NSSound.Name(name)) {
                nsSound.play()
            }
        }
    }

    // MARK: - Custom command

    /// Run the user-configured custom shell command for a notification, if one is set.
    /// Executes via `/bin/sh -c <command>` in a detached Process with notification
    /// context injected as environment variables. Errors are silently discarded.
    private func runCustomCommand(for notification: InAppNotification) {
        guard let command = NotificationCustomCommandSettings.command() else { return }
        let title = notification.title
        let body = notification.body
        let workspaceID = notification.workspaceID?.uuidString ?? ""
        Task.detached(priority: .utility) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", command]
            var env = ProcessInfo.processInfo.environment
            env["NAMU_NOTIFICATION_TITLE"] = title
            env["NAMU_NOTIFICATION_BODY"] = body
            env["NAMU_WORKSPACE_ID"] = workspaceID
            process.environment = env
            try? process.run()
        }
    }

    // MARK: - Mark read

    func markRead(id: UUID) {
        guard let idx = allNotifications.firstIndex(where: { $0.id == id }) else { return }
        allNotifications[idx].isRead = true
        updateDockBadge()
    }

    func markAllRead() {
        for idx in allNotifications.indices {
            allNotifications[idx].isRead = true
        }
        updateDockBadge()
    }

    func markAllRead(workspaceID: UUID) {
        for idx in allNotifications.indices where allNotifications[idx].workspaceID == workspaceID {
            allNotifications[idx].isRead = true
        }
        updateDockBadge()
    }

    // MARK: - Jump to unread

    /// Returns the workspaceID of the oldest unread notification, or nil if all are read.
    func jumpToOldestUnread() -> UUID? {
        allNotifications.first(where: { !$0.isRead })?.workspaceID
    }

    // MARK: - Remove

    func remove(id: UUID) {
        allNotifications.removeAll { $0.id == id }
    }

    /// Clear notifications. If workspaceID is nil, clears all. Returns the number cleared.
    @discardableResult
    func clearAll(workspaceID: UUID?) -> Int {
        if let wsID = workspaceID {
            let before = allNotifications.count
            allNotifications.removeAll { $0.workspaceID == wsID }
            return before - allNotifications.count
        } else {
            let count = allNotifications.count
            allNotifications.removeAll()
            return count
        }
    }
}
