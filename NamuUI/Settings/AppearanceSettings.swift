import SwiftUI

// MARK: - AppearanceSettingsView

struct AppearanceSettingsView: View {
    @ObservedObject private var appearance = AppearanceManager.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            sectionHeader(String(localized: "settings.appearance.title", defaultValue: "Appearance"), subtitle: String(localized: "settings.appearance.subtitle", defaultValue: "Customize the look and feel of Namu"))

            themeSection
            sidebarSection
            windowSection
            fontSection
        }
        .padding(24)
    }

    // MARK: - Theme

    private var themeSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                Text(String(localized: "settings.appearance.theme.label", defaultValue: "Theme"))
                    .font(.system(size: 13, weight: .semibold))

                Picker("", selection: $appearance.theme) {
                    ForEach(AppearanceTheme.allCases, id: \.self) { theme in
                        Text(theme.displayName).tag(theme)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                if appearance.theme == .auto {
                    autoScheduleRow
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(4)
        }
    }

    private var autoScheduleRow: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(String(localized: "settings.appearance.theme.lightFrom", defaultValue: "Light mode from"))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Stepper(
                    value: $appearance.autoLightHour,
                    in: 0...23
                ) {
                    Text(String(format: "%02d:00", appearance.autoLightHour))
                        .font(.system(size: 12, design: .monospaced))
                        .frame(width: 44, alignment: .leading)
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(String(localized: "settings.appearance.theme.darkFrom", defaultValue: "Dark mode from"))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Stepper(
                    value: $appearance.autoDarkHour,
                    in: 0...23
                ) {
                    Text(String(format: "%02d:00", appearance.autoDarkHour))
                        .font(.system(size: 12, design: .monospaced))
                        .frame(width: 44, alignment: .leading)
                }
            }
        }
    }

    // MARK: - Sidebar

    private var sidebarSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 14) {
                Text(String(localized: "settings.appearance.sidebar.label", defaultValue: "Sidebar"))
                    .font(.system(size: 13, weight: .semibold))

                // Material
                HStack {
                    Text(String(localized: "settings.appearance.sidebar.material", defaultValue: "Material"))
                        .font(.system(size: 12))
                        .frame(width: 80, alignment: .leading)
                    Picker("", selection: $appearance.sidebarMaterial) {
                        ForEach(SidebarMaterial.allCases, id: \.self) { mat in
                            Text(mat.displayName).tag(mat)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(maxWidth: 220)
                }

                // Tint color
                HStack {
                    Text(String(localized: "settings.appearance.sidebar.tintColor", defaultValue: "Tint Color"))
                        .font(.system(size: 12))
                        .frame(width: 80, alignment: .leading)
                    ColorPicker(
                        "",
                        selection: sidebarTintColorBinding,
                        supportsOpacity: false
                    )
                    .labelsHidden()
                    .frame(width: 36)

                    Text(String(localized: "settings.appearance.sidebar.opacity", defaultValue: "Opacity"))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Slider(value: $appearance.sidebarTintOpacity, in: 0...1, step: 0.05)
                        .frame(maxWidth: 120)
                    Text(String(format: "%.0f%%", appearance.sidebarTintOpacity * 100))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(width: 36, alignment: .trailing)
                }

                // Per-appearance tint overrides
                HStack {
                    Text(String(localized: "settings.appearance.sidebar.lightModeTint", defaultValue: "Light Mode Tint"))
                        .font(.system(size: 12))
                        .frame(width: 110, alignment: .leading)
                    ColorPicker("Light Mode Tint", selection: sidebarTintColorLightBinding, supportsOpacity: false)
                        .labelsHidden()
                        .frame(width: 36)
                    if appearance.sidebarTintColorHexLight == nil {
                        Text(String(localized: "settings.appearance.sidebar.usingDefault", defaultValue: "Using default"))
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                    }
                }

                HStack {
                    Text(String(localized: "settings.appearance.sidebar.darkModeTint", defaultValue: "Dark Mode Tint"))
                        .font(.system(size: 12))
                        .frame(width: 110, alignment: .leading)
                    ColorPicker("Dark Mode Tint", selection: sidebarTintColorDarkBinding, supportsOpacity: false)
                        .labelsHidden()
                        .frame(width: 36)
                    if appearance.sidebarTintColorHexDark == nil {
                        Text(String(localized: "settings.appearance.sidebar.usingDefault", defaultValue: "Using default"))
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                    }
                }

                Button(String(localized: "settings.appearance.sidebar.resetTint", defaultValue: "Reset Sidebar Tint")) {
                    appearance.sidebarTintColorHexLight = nil
                    appearance.sidebarTintColorHexDark = nil
                    appearance.sidebarTintOpacity = 0.15
                }
                .font(.system(size: 12))
                .foregroundStyle(.secondary)

                Text(String(localized: "settings.appearance.sidebar.tintNote", defaultValue: "Tint overlays the sidebar background material."))
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(4)
        }
    }

    private var sidebarTintColorBinding: Binding<Color> {
        Binding(
            get: {
                Color(hex: appearance.sidebarTintColorHex) ?? .black
            },
            set: { newColor in
                if let hex = newColor.hexString {
                    appearance.sidebarTintColorHex = hex
                }
            }
        )
    }

    private var sidebarTintColorLightBinding: Binding<Color> {
        Binding(
            get: {
                Color(hex: appearance.sidebarTintColorHexLight ?? appearance.sidebarTintColorHex) ?? .black
            },
            set: { newColor in
                if let hex = newColor.hexString {
                    appearance.sidebarTintColorHexLight = hex
                }
            }
        )
    }

    private var sidebarTintColorDarkBinding: Binding<Color> {
        Binding(
            get: {
                Color(hex: appearance.sidebarTintColorHexDark ?? appearance.sidebarTintColorHex) ?? .black
            },
            set: { newColor in
                if let hex = newColor.hexString {
                    appearance.sidebarTintColorHexDark = hex
                }
            }
        )
    }

    // MARK: - Window

    private var windowSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(String(localized: "settings.appearance.windowOpacity.label", defaultValue: "Window Opacity"))
                        .font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Text("\(Int(appearance.windowOpacity * 100))%")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                Slider(value: $appearance.windowOpacity, in: 0.3...1.0, step: 0.05)
                Text(String(localized: "settings.appearance.windowOpacity.note", defaultValue: "Lower opacity can help when referencing other windows."))
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(4)
        }
    }

    // MARK: - Font

    private var fontSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                Text(String(localized: "settings.appearance.font.label", defaultValue: "Terminal Font"))
                    .font(.system(size: 13, weight: .semibold))
                TerminalFontSettingsView()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(4)
        }
    }
}

// MARK: - TerminalFontSettingsView

struct TerminalFontSettingsView: View {
    @AppStorage("namu.terminal.fontFamily")    private var fontFamily: String  = ""
    @AppStorage("namu.terminal.fontSize")      private var fontSize: Double    = 13.0
    @AppStorage("namu.terminal.lineHeight")    private var lineHeight: Double  = 1.2
    @AppStorage("namu.terminal.letterSpacing") private var letterSpacing: Double = 0.0

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(String(localized: "settings.appearance.font.family", defaultValue: "Family"))
                    .font(.system(size: 12))
                    .frame(width: 90, alignment: .leading)
                TextField(String(localized: "settings.appearance.font.familyPlaceholder", defaultValue: "Default (system mono)"), text: $fontFamily)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
            }
            HStack {
                Text(String(localized: "settings.appearance.font.size", defaultValue: "Size"))
                    .font(.system(size: 12))
                    .frame(width: 90, alignment: .leading)
                Stepper(value: $fontSize, in: 6...36, step: 1) {
                    Text("\(Int(fontSize)) pt")
                        .font(.system(size: 12, design: .monospaced))
                        .frame(width: 50, alignment: .leading)
                }
            }
            HStack {
                Text(String(localized: "settings.appearance.font.lineHeight", defaultValue: "Line Height"))
                    .font(.system(size: 12))
                    .frame(width: 90, alignment: .leading)
                Slider(value: $lineHeight, in: 0.8...2.0, step: 0.05)
                Text(String(format: "%.2f", lineHeight))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(width: 36, alignment: .trailing)
            }
            HStack {
                Text(String(localized: "settings.appearance.font.spacing", defaultValue: "Spacing"))
                    .font(.system(size: 12))
                    .frame(width: 90, alignment: .leading)
                Slider(value: $letterSpacing, in: -2.0...4.0, step: 0.5)
                Text(String(format: "%.1f", letterSpacing))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(width: 36, alignment: .trailing)
            }
            Text(String(localized: "settings.appearance.font.note", defaultValue: "Font changes apply to new terminal sessions."))
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
        }
    }
}

// MARK: - Helpers

private func sectionHeader(_ title: String, subtitle: String) -> some View {
    VStack(alignment: .leading, spacing: 4) {
        Text(title)
            .font(.system(size: 20, weight: .bold))
        Text(subtitle)
            .font(.system(size: 13))
            .foregroundStyle(.secondary)
    }
}

// MARK: - Color+Hex helpers

extension Color {
    init?(hex: String) {
        let hex = hex.trimmingCharacters(in: .whitespacesAndNewlines)
                     .replacingOccurrences(of: "#", with: "")
        guard hex.count == 6, let value = UInt64(hex, radix: 16) else { return nil }
        let r = Double((value >> 16) & 0xFF) / 255
        let g = Double((value >> 8)  & 0xFF) / 255
        let b = Double(value         & 0xFF) / 255
        self.init(red: r, green: g, blue: b)
    }

    var hexString: String? {
        guard let components = NSColor(self).usingColorSpace(.sRGB)?.cgColor.components,
              components.count >= 3 else { return nil }
        let r = Int(components[0] * 255)
        let g = Int(components[1] * 255)
        let b = Int(components[2] * 255)
        return String(format: "#%02X%02X%02X", r, g, b)
    }
}
