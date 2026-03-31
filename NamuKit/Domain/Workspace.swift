import Darwin
import Foundation

// MARK: - WorkspaceAutoReorderSettings

/// Controls whether workspaces with new notifications are moved to the top.
enum WorkspaceAutoReorderSettings {
    static let key = "namu.workspaceAutoReorderOnNotification"

    static func isEnabled(defaults: UserDefaults = .standard) -> Bool {
        if defaults.object(forKey: key) == nil { return true }  // default true
        return defaults.bool(forKey: key)
    }

    static func setEnabled(_ enabled: Bool, defaults: UserDefaults = .standard) {
        defaults.set(enabled, forKey: key)
    }
}

// MARK: - NotificationPaneRingSettings

/// Controls whether the pane attention ring is shown on notification.
enum NotificationPaneRingSettings {
    static let key = "namu.notificationPaneRingEnabled"

    static func isEnabled(defaults: UserDefaults = .standard) -> Bool {
        if defaults.object(forKey: key) == nil { return true }  // default true
        return defaults.bool(forKey: key)
    }

    static func setEnabled(_ enabled: Bool, defaults: UserDefaults = .standard) {
        defaults.set(enabled, forKey: key)
    }
}

// MARK: - NotificationPaneFlashSettings

/// Controls whether a brief opacity flash animation is shown on the pane on notification.
enum NotificationPaneFlashSettings {
    static let key = "namu.notificationPaneFlashEnabled"

    static func isEnabled(defaults: UserDefaults = .standard) -> Bool {
        if defaults.object(forKey: key) == nil { return true }  // default true
        return defaults.bool(forKey: key)
    }

    static func setEnabled(_ enabled: Bool, defaults: UserDefaults = .standard) {
        defaults.set(enabled, forKey: key)
    }
}

// MARK: - Workspace placement

enum WorkspacePlacement: String, CaseIterable, Identifiable, Codable {
    case top, afterCurrent, end
    var id: String { rawValue }
}

enum WorkspacePlacementSettings {
    static let placementKey = "namu.newWorkspacePlacement"
    static let defaultPlacement: WorkspacePlacement = .end

    static func current(defaults: UserDefaults = .standard) -> WorkspacePlacement {
        guard let raw = defaults.string(forKey: placementKey),
              let placement = WorkspacePlacement(rawValue: raw) else {
            return defaultPlacement
        }
        return placement
    }

    /// Returns the index at which a new workspace should be inserted.
    /// - Parameters:
    ///   - placement: The configured placement mode.
    ///   - selectedIndex: The current selected workspace index (nil if none).
    ///   - pinnedCount: Number of pinned workspaces (always grouped at the top).
    ///   - totalCount: Total number of existing workspaces before insertion.
    ///   - selectedIsPinned: Whether the currently selected workspace is pinned.
    ///     When true and placement is .afterCurrent, inserts after all pinned workspaces
    ///     rather than between pinned items.
    static func insertionIndex(
        placement: WorkspacePlacement,
        selectedIndex: Int?,
        pinnedCount: Int,
        totalCount: Int,
        selectedIsPinned: Bool = false
    ) -> Int {
        let clampedTotal = max(0, totalCount)
        let clampedPinned = max(0, min(pinnedCount, clampedTotal))

        switch placement {
        case .top:
            // Insert after all pinned workspaces so pinned items stay grouped.
            return clampedPinned
        case .end:
            return clampedTotal
        case .afterCurrent:
            guard let selectedIndex, clampedTotal > 0 else { return clampedTotal }
            // If the selected workspace is pinned, insert after the pinned block
            // instead of between pinned items.
            if selectedIsPinned {
                return clampedPinned
            }
            let clamped = max(0, min(selectedIndex, clampedTotal - 1))
            return min(clamped + 1, clampedTotal)
        }
    }
}

// MARK: - WorkspaceColorPaletteSettings

/// Manages the color palette available for workspace accent colors.
enum WorkspaceColorPaletteSettings {
    static let key = "namu.workspaceColorPalette"
    static let overridesKey = "namu.workspaceColorOverrides"

    /// 16 named default colors with display names.
    static let namedDefaults: [(name: String, hex: String)] = [
        ("Red",    "#FF6B6B"), ("Coral",  "#FF8E72"), ("Orange", "#E67E22"), ("Amber",  "#FFD93D"),
        ("Yellow", "#F1C40F"), ("Lime",   "#A8E06C"), ("Green",  "#6BCB77"), ("Teal",   "#1ABC9C"),
        ("Cyan",   "#00BCD4"), ("Sky",    "#4D96FF"), ("Blue",   "#3498DB"), ("Indigo", "#5C6BC0"),
        ("Purple", "#9B59B6"), ("Pink",   "#E91E63"), ("Gray",   "#95A5A6"), ("Slate",  "#607D8B")
    ]

    /// Legacy flat array of default hex values — kept for backward compatibility.
    static var defaultColors: [String] { namedDefaults.map(\.hex) }

    // MARK: - Per-color overrides

    /// Returns the persisted name→hex override dictionary.
    static func colorOverrides(defaults: UserDefaults = .standard) -> [String: String] {
        guard let data = defaults.data(forKey: overridesKey),
              let decoded = try? JSONDecoder().decode([String: String].self, from: data) else {
            return [:]
        }
        return decoded
    }

    /// Returns the effective hex for a named default: override if set, else the built-in default.
    static func effectiveColor(for name: String, defaults: UserDefaults = .standard) -> String {
        if let override = colorOverrides(defaults: defaults)[name] { return override }
        return namedDefaults.first(where: { $0.name == name })?.hex ?? "#FFFFFF"
    }

    /// Persist a custom hex override for a named default.
    static func setOverride(name: String, hex: String, defaults: UserDefaults = .standard) {
        var overrides = colorOverrides(defaults: defaults)
        overrides[name] = hex
        if let data = try? JSONEncoder().encode(overrides) {
            defaults.set(data, forKey: overridesKey)
        }
    }

    /// Remove the override for a named default, reverting it to the built-in value.
    static func removeOverride(name: String, defaults: UserDefaults = .standard) {
        var overrides = colorOverrides(defaults: defaults)
        overrides.removeValue(forKey: name)
        if let data = try? JSONEncoder().encode(overrides) {
            defaults.set(data, forKey: overridesKey)
        }
    }

    // MARK: - Dark-mode brightening

    /// Slightly brightens a hex color in dark mode (increases HSB brightness by 10%).
    /// Returns the original hex unchanged for light mode.
    static func adjustedColor(hex: String, isDarkMode: Bool) -> String {
        guard isDarkMode else { return hex }
        guard let (r, g, b) = rgbComponents(hex: hex) else { return hex }

        // Convert RGB → HSB
        let maxC = max(r, g, b)
        let minC = min(r, g, b)
        let delta = maxC - minC

        let brightness = maxC
        let saturation: Double = maxC == 0 ? 0 : delta / maxC
        var hue: Double = 0
        if delta != 0 {
            switch maxC {
            case r: hue = ((g - b) / delta).truncatingRemainder(dividingBy: 6)
            case g: hue = (b - r) / delta + 2
            default: hue = (r - g) / delta + 4
            }
            hue /= 6
            if hue < 0 { hue += 1 }
        }

        // Increase brightness by 10%, clamped to 1.0
        let newBrightness = min(brightness + 0.10, 1.0)

        // Convert HSB → RGB
        let c = newBrightness * saturation
        let x = c * (1 - abs((hue * 6).truncatingRemainder(dividingBy: 2) - 1))
        let m = newBrightness - c

        var rr, gg, bb: Double
        switch Int(hue * 6) % 6 {
        case 0:  rr = c; gg = x; bb = 0
        case 1:  rr = x; gg = c; bb = 0
        case 2:  rr = 0; gg = c; bb = x
        case 3:  rr = 0; gg = x; bb = c
        case 4:  rr = x; gg = 0; bb = c
        default: rr = c; gg = 0; bb = x
        }
        rr += m; gg += m; bb += m

        let ri = Int((rr * 255).rounded())
        let gi = Int((gg * 255).rounded())
        let bi = Int((bb * 255).rounded())
        return String(format: "#%02X%02X%02X", ri, gi, bi)
    }

    private static func rgbComponents(hex: String) -> (Double, Double, Double)? {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s = String(s.dropFirst()) }
        guard s.count == 6, let value = UInt32(s, radix: 16) else { return nil }
        let r = Double((value >> 16) & 0xFF) / 255
        let g = Double((value >> 8)  & 0xFF) / 255
        let b = Double( value        & 0xFF) / 255
        return (r, g, b)
    }

    // MARK: - Palette

    /// Returns the full palette: named defaults (with overrides applied) followed by any custom additions.
    static func allColors(defaults: UserDefaults = .standard) -> [String] {
        let named = namedDefaults.map { effectiveColor(for: $0.name, defaults: defaults) }
        return named + customColors(defaults: defaults)
    }

    static func customColors(defaults: UserDefaults = .standard) -> [String] {
        guard let data = defaults.data(forKey: key),
              let decoded = try? JSONDecoder().decode([String].self, from: data) else {
            return []
        }
        return decoded
    }

    static func addCustomColor(_ hex: String, defaults: UserDefaults = .standard) {
        var current = customColors(defaults: defaults)
        guard !current.contains(hex) else { return }
        current.append(hex)
        if let data = try? JSONEncoder().encode(current) {
            defaults.set(data, forKey: key)
        }
    }

    static func removeCustomColor(_ hex: String, defaults: UserDefaults = .standard) {
        var current = customColors(defaults: defaults)
        current.removeAll { $0 == hex }
        if let data = try? JSONEncoder().encode(current) {
            defaults.set(data, forKey: key)
        }
    }

    static func resetToDefaults(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: key)
        defaults.removeObject(forKey: overridesKey)
    }
}

// MARK: - Workspace

/// A named unit of work shown as a tab in the sidebar.
/// Pure value type — no UI dependencies.
struct Workspace: Identifiable, Codable, Equatable {
    let id: UUID
    var title: String
    var order: Int
    var isPinned: Bool
    var createdAt: Date
    /// Optional accent color for this workspace, stored as a hex string (e.g. "#FF6B6B").
    var customColor: String?

    /// User-set custom title. When set, overrides processTitle for display.
    var customTitle: String?
    /// Title from the active terminal's running process (e.g. "vim", "zsh", "~/dev/namu").
    /// Not persisted — transient state rebuilt from terminal.
    var processTitle: String = ""

    /// Active agent PIDs in this workspace (transient, not persisted).
    /// Key = agent type (e.g. "claude_code", "codex"), value = PID string.
    /// Set by session-start hooks, cleared by session-end or stale reaping.
    /// Used to suppress duplicate OSC notifications when agent hooks handle them.
    var agentPIDs: [String: String] = [:]

    /// Set the PID for a named agent type.
    mutating func setAgentPID(type agentType: String, pid: String) {
        agentPIDs[agentType] = pid
    }

    /// Clear the PID for a named agent type.
    mutating func clearAgentPID(type agentType: String) {
        agentPIDs.removeValue(forKey: agentType)
    }

    /// Remove entries whose PIDs no longer correspond to running processes.
    /// Uses kill(pid, 0): returns 0 if the process exists, -1 with ESRCH if not.
    mutating func reapStaleAgentPIDs() {
        agentPIDs = agentPIDs.filter { _, pidString in
            guard let pid = Int32(pidString) else { return false }
            return kill(pid, 0) == 0
        }
    }

    // MARK: - Codable

    enum CodingKeys: String, CodingKey {
        case id, title, order, isPinned, createdAt, customColor, customTitle
    }

    // MARK: - Title management

    /// Update the title from the terminal process. Only takes effect if no custom title is set.
    mutating func applyProcessTitle(_ newTitle: String) {
        // Ignore placeholder titles that aren't real process names.
        let dominated = ["Terminal", "terminal", ""]
        guard !dominated.contains(newTitle) else { return }
        processTitle = newTitle
        guard customTitle == nil else { return }
        title = Self.displayTitle(from: newTitle)
    }

    /// Clean up a raw process title for sidebar display.
    /// Full paths become basenames, home dir becomes ~.
    private static func displayTitle(from raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return trimmed }

        let home = FileManager.default.homeDirectoryForCurrentUser.path
        // If it's exactly the home directory, show ~
        if trimmed == home { return "~" }
        // If it's an absolute path, show the last component
        if trimmed.hasPrefix("/") {
            let basename = (trimmed as NSString).lastPathComponent
            return basename.isEmpty ? trimmed : basename
        }
        // If it starts with ~/, show from ~ with basename
        if trimmed.hasPrefix("~/") || trimmed == "~" {
            return (trimmed as NSString).lastPathComponent
        }
        return trimmed
    }

    /// Set a user-chosen custom title. Pass nil to revert to process title.
    mutating func setCustomTitle(_ newTitle: String?) {
        let trimmed = newTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmed.isEmpty {
            customTitle = nil
            title = processTitle.isEmpty ? String(localized: "workspace.default.title", defaultValue: "New Workspace") : processTitle
        } else {
            customTitle = trimmed
            title = trimmed
        }
    }

    // MARK: - Init

    init(
        id: UUID = UUID(),
        title: String = String(localized: "workspace.default.title", defaultValue: "New Workspace"),
        order: Int = 0,
        isPinned: Bool = false,
        createdAt: Date = Date(),
        customColor: String? = nil
    ) {
        self.id = id
        self.title = title
        self.order = order
        self.isPinned = isPinned
        self.createdAt = createdAt
        self.customColor = customColor
    }
}
