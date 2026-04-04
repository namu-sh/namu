import Foundation
import AppKit
import Combine

// MARK: - AppearanceTheme

enum AppearanceTheme: String, CaseIterable, Codable {
    case system = "System"
    case dark   = "Dark"
    case light  = "Light"
    case auto   = "Auto"  // time-based switching

    var displayName: String {
        switch self {
        case .system: return "System"
        case .dark:   return "Dark"
        case .light:  return "Light"
        case .auto:   return "Auto (time-based)"
        }
    }
}

// MARK: - SidebarMaterial

enum SidebarMaterial: String, CaseIterable, Codable {
    case glass  = "Glass"
    case blur   = "Blur"
    case solid  = "Solid"

    var displayName: String { rawValue }

    var nsVisualEffect: NSVisualEffectView.Material {
        switch self {
        case .glass:  return .hudWindow
        case .blur:   return .sidebar
        case .solid:  return .windowBackground
        }
    }
}

// MARK: - WorkspaceAppearanceOverride

struct WorkspaceAppearanceOverride: Codable {
    var theme: AppearanceTheme?
    var accentColorHex: String?
}

// MARK: - AppearanceManager

/// Manages app-wide appearance: theme, accent color, window opacity, sidebar tint/material.
/// Includes time-based auto-switching and per-workspace appearance overrides.
@MainActor
final class AppearanceManager: ObservableObject {

    static let shared = AppearanceManager()

    // MARK: - Published

    @Published var theme: AppearanceTheme {
        didSet {
            UserDefaults.standard.set(theme.rawValue, forKey: Keys.theme)
            applyTheme()
            rescheduleAutoTimer()
        }
    }

    @Published var accentColorHex: String? {
        didSet {
            UserDefaults.standard.set(accentColorHex, forKey: Keys.accentColor)
        }
    }

    @Published var windowOpacity: Double {
        didSet {
            let clamped = windowOpacity.clamped(to: 0.3...1.0)
            if clamped != windowOpacity { windowOpacity = clamped; return }
            UserDefaults.standard.set(clamped, forKey: Keys.windowOpacity)
            applyWindowOpacity()
        }
    }

    /// Sidebar tint color stored as hex string (fallback / unified).
    @Published var sidebarTintColorHex: String {
        didSet {
            UserDefaults.standard.set(sidebarTintColorHex, forKey: Keys.sidebarTintColor)
        }
    }

    /// Sidebar tint color for light mode. When set, overrides `sidebarTintColorHex` in light appearance.
    @Published var sidebarTintColorHexLight: String? {
        didSet {
            if let hex = sidebarTintColorHexLight {
                UserDefaults.standard.set(hex, forKey: Keys.sidebarTintColorLight)
            } else {
                UserDefaults.standard.removeObject(forKey: Keys.sidebarTintColorLight)
            }
        }
    }

    /// Sidebar tint color for dark mode. When set, overrides `sidebarTintColorHex` in dark appearance.
    @Published var sidebarTintColorHexDark: String? {
        didSet {
            if let hex = sidebarTintColorHexDark {
                UserDefaults.standard.set(hex, forKey: Keys.sidebarTintColorDark)
            } else {
                UserDefaults.standard.removeObject(forKey: Keys.sidebarTintColorDark)
            }
        }
    }

    /// Resolved sidebar tint hex for the current system appearance.
    var resolvedSidebarTintColorHex: String {
        let isDark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        if isDark, let dark = sidebarTintColorHexDark {
            return dark
        } else if !isDark, let light = sidebarTintColorHexLight {
            return light
        }
        return sidebarTintColorHex
    }

    /// Sidebar tint opacity (0.0 – 1.0).
    @Published var sidebarTintOpacity: Double {
        didSet {
            let clamped = sidebarTintOpacity.clamped(to: 0.0...1.0)
            if clamped != sidebarTintOpacity { sidebarTintOpacity = clamped; return }
            UserDefaults.standard.set(clamped, forKey: Keys.sidebarTintOpacity)
        }
    }

    /// Background material used behind the sidebar.
    @Published var sidebarMaterial: SidebarMaterial {
        didSet {
            UserDefaults.standard.set(sidebarMaterial.rawValue, forKey: Keys.sidebarMaterial)
        }
    }

    /// Light-mode start hour for auto theme (0–23).
    @Published var autoLightHour: Int {
        didSet {
            UserDefaults.standard.set(autoLightHour, forKey: Keys.autoLightHour)
            if theme == .auto { applyAutoTheme() }
        }
    }

    /// Dark-mode start hour for auto theme (0–23).
    @Published var autoDarkHour: Int {
        didSet {
            UserDefaults.standard.set(autoDarkHour, forKey: Keys.autoDarkHour)
            if theme == .auto { applyAutoTheme() }
        }
    }

    /// Per-workspace overrides keyed by workspace UUID string.
    @Published var workspaceOverrides: [String: WorkspaceAppearanceOverride] {
        didSet { persistWorkspaceOverrides() }
    }

    // MARK: - Private

    private var autoTimer: Timer?

    // MARK: - Init

    private init() {
        let defaults = UserDefaults.standard

        let rawTheme = defaults.string(forKey: Keys.theme) ?? ""
        theme = AppearanceTheme(rawValue: rawTheme) ?? .system

        accentColorHex = defaults.string(forKey: Keys.accentColor)

        let savedOpacity = defaults.double(forKey: Keys.windowOpacity)
        windowOpacity = savedOpacity > 0 ? savedOpacity : 1.0

        sidebarTintColorHex = defaults.string(forKey: Keys.sidebarTintColor) ?? "#101010"
        sidebarTintColorHexLight = defaults.string(forKey: Keys.sidebarTintColorLight)
        sidebarTintColorHexDark = defaults.string(forKey: Keys.sidebarTintColorDark)
        let savedTintOpacity = defaults.object(forKey: Keys.sidebarTintOpacity) as? Double ?? 0.78
        sidebarTintOpacity = savedTintOpacity

        let rawMaterial = defaults.string(forKey: Keys.sidebarMaterial) ?? ""
        sidebarMaterial = SidebarMaterial(rawValue: rawMaterial) ?? .blur

        autoLightHour = defaults.object(forKey: Keys.autoLightHour) as? Int ?? 7
        autoDarkHour  = defaults.object(forKey: Keys.autoDarkHour)  as? Int ?? 20

        workspaceOverrides = Self.loadWorkspaceOverrides(from: defaults)

        applyTheme()
        applyWindowOpacity()
        rescheduleAutoTimer()
    }

    deinit {
        autoTimer?.invalidate()
    }

    // MARK: - Apply

    func applyTheme() {
        switch theme {
        case .system: NSApp.appearance = nil
        case .dark:   NSApp.appearance = NSAppearance(named: .darkAqua)
        case .light:  NSApp.appearance = NSAppearance(named: .aqua)
        case .auto:   applyAutoTheme()
        }
    }

    func applyWindowOpacity() {
        for window in NSApp.windows {
            window.alphaValue = CGFloat(windowOpacity)
        }
    }

    /// Apply theme for a specific workspace, temporarily overriding global theme.
    func applyWorkspaceOverride(workspaceID: String) {
        guard let override = workspaceOverrides[workspaceID] else {
            applyTheme()
            return
        }
        if let overrideTheme = override.theme {
            switch overrideTheme {
            case .system: NSApp.appearance = nil
            case .dark:   NSApp.appearance = NSAppearance(named: .darkAqua)
            case .light:  NSApp.appearance = NSAppearance(named: .aqua)
            case .auto:   applyAutoTheme()
            }
        }
    }

    func setWorkspaceOverride(_ override: WorkspaceAppearanceOverride?, forID id: String) {
        if let override {
            workspaceOverrides[id] = override
        } else {
            workspaceOverrides.removeValue(forKey: id)
        }
    }

    // MARK: - Auto theme

    private func applyAutoTheme() {
        let hour = Calendar.current.component(.hour, from: Date())
        let isDark: Bool
        if autoLightHour < autoDarkHour {
            isDark = hour < autoLightHour || hour >= autoDarkHour
        } else {
            isDark = hour >= autoDarkHour && hour < autoLightHour
        }
        NSApp.appearance = NSAppearance(named: isDark ? .darkAqua : .aqua)
    }

    private func rescheduleAutoTimer() {
        autoTimer?.invalidate()
        autoTimer = nil
        guard theme == .auto else { return }
        // Fire every minute to catch hour boundaries.
        autoTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in self.applyAutoTheme() }
        }
    }

    // MARK: - Workspace override persistence

    private static func loadWorkspaceOverrides(from defaults: UserDefaults) -> [String: WorkspaceAppearanceOverride] {
        guard let data = defaults.data(forKey: Keys.workspaceOverrides),
              let decoded = try? JSONDecoder().decode([String: WorkspaceAppearanceOverride].self, from: data)
        else { return [:] }
        return decoded
    }

    private func persistWorkspaceOverrides() {
        guard let data = try? JSONEncoder().encode(workspaceOverrides) else { return }
        UserDefaults.standard.set(data, forKey: Keys.workspaceOverrides)
    }

    // MARK: - Keys

    private enum Keys {
        static let theme             = "namu.appearance.theme"
        static let accentColor       = "namu.appearance.accentColor"
        static let windowOpacity     = "namu.appearance.windowOpacity"
        static let sidebarTintColor      = "namu.appearance.sidebarTintColor"
        static let sidebarTintColorLight = "namu.appearance.sidebarTintColorLight"
        static let sidebarTintColorDark  = "namu.appearance.sidebarTintColorDark"
        static let sidebarTintOpacity    = "namu.appearance.sidebarTintOpacity"
        static let sidebarMaterial   = "namu.appearance.sidebarMaterial"
        static let autoLightHour     = "namu.appearance.autoLightHour"
        static let autoDarkHour      = "namu.appearance.autoDarkHour"
        static let workspaceOverrides = "namu.appearance.workspaceOverrides"
    }
}

// MARK: - Double+Clamped

private extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        min(range.upperBound, max(range.lowerBound, self))
    }
}

// MARK: - NamuColors

import SwiftUI

/// Centralized semantic color definitions for the Namu UI.
/// Uses Apple's system semantic colors so dark/light mode and fullscreen are consistent.
/// All UI components should reference these instead of hardcoding colors.
enum NamuColors {

    // MARK: - Backgrounds

    /// Primary content area background — reads from Ghostty's terminal background
    /// so the content area matches the terminal seamlessly (no border artifacts between splits).
    static var contentBackground: Color {
        if let config = GhosttyApp.shared?.config {
            var color = ghostty_config_color_s()
            let key = "background"
            if ghostty_config_get(config, &color, key, UInt(key.utf8.count)) {
                return Color(
                    red: Double(color.r) / 255,
                    green: Double(color.g) / 255,
                    blue: Double(color.b) / 255
                )
            }
        }
        return Color(nsColor: .controlBackgroundColor)
    }

    /// Sidebar background — warm off-white in light, dark gray in dark.
    /// Uses an adaptive NSColor so SwiftUI re-evaluates on appearance change.
    static var sidebarBackground: Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            if isDark {
                return NSColor.underPageBackgroundColor
            }
            return NSColor(red: 0.96, green: 0.94, blue: 0.92, alpha: 1.0)
        })
    }

    /// Content header / toolbar background.
    static var headerBackground: Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return isDark ? NSColor.windowBackgroundColor : .white
        })
    }

    // MARK: - Surfaces

    /// Selected item background (sidebar rows, list selections).
    static var selectedBackground: Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return isDark
                ? NSColor.white.withAlphaComponent(0.1)
                : NSColor.black.withAlphaComponent(0.06)
        })
    }

    /// Hovered item background.
    static var hoverBackground: Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return isDark
                ? NSColor.white.withAlphaComponent(0.06)
                : NSColor.black.withAlphaComponent(0.04)
        })
    }

    // MARK: - Separators

    /// Standard separator line.
    static var separator: Color {
        Color(nsColor: .separatorColor)
    }
}
