import SwiftUI

// MARK: - AppearanceSettingsView

struct AppearanceSettingsView: View {
    @ObservedObject private var appearance = AppearanceManager.shared
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Form {
            // MARK: - Theme
            Section {
                Picker(String(localized: "settings.appearance.theme.label", defaultValue: "Theme"), selection: $appearance.theme) {
                    ForEach(AppearanceTheme.allCases, id: \.self) { theme in
                        Text(theme.displayName).tag(theme)
                    }
                }
                .pickerStyle(.segmented)

                if appearance.theme == .auto {
                    LabeledContent(String(localized: "settings.appearance.theme.lightFrom", defaultValue: "Light mode from")) {
                        Stepper(value: $appearance.autoLightHour, in: 0...23) {
                            Text(String(format: "%02d:00", appearance.autoLightHour))
                                .font(.system(size: 12, design: .monospaced))
                        }
                    }
                    LabeledContent(String(localized: "settings.appearance.theme.darkFrom", defaultValue: "Dark mode from")) {
                        Stepper(value: $appearance.autoDarkHour, in: 0...23) {
                            Text(String(format: "%02d:00", appearance.autoDarkHour))
                                .font(.system(size: 12, design: .monospaced))
                        }
                    }
                }
            } header: {
                Text(String(localized: "settings.appearance.theme.header", defaultValue: "Theme"))
            }

            // MARK: - Window
            Section {
                LabeledContent(String(localized: "settings.appearance.windowOpacity.label", defaultValue: "Window Opacity")) {
                    HStack(spacing: 8) {
                        Slider(value: $appearance.windowOpacity, in: 0.3...1.0, step: 0.01)
                            .frame(maxWidth: 180)
                        Text("\(Int(appearance.windowOpacity * 100))%")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .frame(width: 36, alignment: .trailing)
                    }
                }
            } header: {
                Text(String(localized: "settings.appearance.window.header", defaultValue: "Window"))
            } footer: {
                Text(String(localized: "settings.appearance.windowOpacity.note", defaultValue: "Lower opacity can help when referencing other windows."))
            }

            // MARK: - Sidebar
            Section {
                LabeledContent(String(localized: "settings.appearance.sidebar.material", defaultValue: "Material")) {
                    Picker("", selection: $appearance.sidebarMaterial) {
                        ForEach(SidebarMaterial.allCases, id: \.self) { mat in
                            Text(mat.displayName).tag(mat)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(maxWidth: 200)
                }

                LabeledContent(String(localized: "settings.appearance.sidebar.tintColor", defaultValue: "Tint Color")) {
                    HStack(spacing: 8) {
                        ColorPicker("", selection: sidebarTintColorBinding, supportsOpacity: false)
                            .labelsHidden()
                        Slider(value: $appearance.sidebarTintOpacity, in: 0...1, step: 0.05)
                            .frame(maxWidth: 120)
                        Text(String(format: "%.0f%%", appearance.sidebarTintOpacity * 100))
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .frame(width: 36, alignment: .trailing)
                    }
                }

                DisclosureGroup(String(localized: "settings.appearance.sidebar.perMode", defaultValue: "Per-Mode Tint Overrides")) {
                    LabeledContent(String(localized: "settings.appearance.sidebar.lightModeTint", defaultValue: "Light Mode")) {
                        HStack {
                            ColorPicker("", selection: sidebarTintColorLightBinding, supportsOpacity: false)
                                .labelsHidden()
                            if appearance.sidebarTintColorHexLight == nil {
                                Text(String(localized: "settings.appearance.sidebar.usingDefault", defaultValue: "Default"))
                                    .font(.system(size: 11))
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }
                    LabeledContent(String(localized: "settings.appearance.sidebar.darkModeTint", defaultValue: "Dark Mode")) {
                        HStack {
                            ColorPicker("", selection: sidebarTintColorDarkBinding, supportsOpacity: false)
                                .labelsHidden()
                            if appearance.sidebarTintColorHexDark == nil {
                                Text(String(localized: "settings.appearance.sidebar.usingDefault", defaultValue: "Default"))
                                    .font(.system(size: 11))
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }
                    Button(String(localized: "settings.appearance.sidebar.resetTint", defaultValue: "Reset Tint Overrides")) {
                        appearance.sidebarTintColorHexLight = nil
                        appearance.sidebarTintColorHexDark = nil
                    }
                    .font(.system(size: 12))
                }
            } header: {
                Text(String(localized: "settings.appearance.sidebar.header", defaultValue: "Sidebar"))
            }

            // MARK: - Workspace Colors
            Section {
                workspaceColorsContent
            } header: {
                Text(String(localized: "settings.appearance.colors.header", defaultValue: "Workspace Colors"))
            } footer: {
                Text(String(localized: "settings.appearance.colors.note", defaultValue: "Right-click a workspace in the sidebar to assign a color."))
            }

            // MARK: - Terminal Font
            Section {
                TerminalFontSettingsView()
            } header: {
                Text(String(localized: "settings.appearance.font.header", defaultValue: "Terminal Font"))
            } footer: {
                Text(String(localized: "settings.appearance.font.note", defaultValue: "Font changes apply to new terminal sessions."))
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }

    // MARK: - Workspace Colors Content

    @State private var colorOverrides: [String: String] = WorkspaceColorPaletteSettings.colorOverrides()
    @State private var editingColorName: String?
    @State private var editingColor: Color = .white

    @ViewBuilder
    private var workspaceColorsContent: some View {
        let isDark = colorScheme == .dark
        let colors = WorkspaceColorPaletteSettings.namedDefaults

        LazyVGrid(columns: [GridItem(.adaptive(minimum: 32), spacing: 8)], spacing: 8) {
            ForEach(colors, id: \.name) { entry in
                let effectiveHex = colorOverrides[entry.name] ?? entry.hex
                let displayHex = WorkspaceColorPaletteSettings.adjustedColor(hex: effectiveHex, isDarkMode: isDark)
                Circle()
                    .fill(Color(hex: displayHex) ?? .gray)
                    .frame(width: 28, height: 28)
                    .overlay(
                        Circle()
                            .strokeBorder(
                                editingColorName == entry.name ? Color.primary : Color.primary.opacity(0.15),
                                lineWidth: editingColorName == entry.name ? 2 : 1
                            )
                    )
                    .onTapGesture {
                        editingColorName = entry.name
                        editingColor = Color(hex: effectiveHex) ?? .white
                    }
                    .help(entry.name)
            }
        }

        if let name = editingColorName {
            HStack {
                Text(name)
                    .font(.system(size: 12, weight: .medium))
                ColorPicker("", selection: $editingColor, supportsOpacity: false)
                    .labelsHidden()
                    .onChange(of: editingColor) { _, newColor in
                        if let hex = newColor.hexString {
                            WorkspaceColorPaletteSettings.setOverride(name: name, hex: hex)
                            colorOverrides = WorkspaceColorPaletteSettings.colorOverrides()
                        }
                    }
                Spacer()
                Button("Done") { editingColorName = nil }
                    .font(.system(size: 12))
            }
        }

        Button(String(localized: "settings.appearance.colors.reset", defaultValue: "Reset to Defaults")) {
            WorkspaceColorPaletteSettings.resetToDefaults()
            colorOverrides = WorkspaceColorPaletteSettings.colorOverrides()
            editingColorName = nil
        }
        .font(.system(size: 12))
    }

    // MARK: - Tint Color Bindings

    private var sidebarTintColorBinding: Binding<Color> {
        Binding(
            get: { Color(hex: appearance.sidebarTintColorHex) ?? .black },
            set: { if let hex = $0.hexString { appearance.sidebarTintColorHex = hex } }
        )
    }

    private var sidebarTintColorLightBinding: Binding<Color> {
        Binding(
            get: { Color(hex: appearance.sidebarTintColorHexLight ?? appearance.sidebarTintColorHex) ?? .black },
            set: { if let hex = $0.hexString { appearance.sidebarTintColorHexLight = hex } }
        )
    }

    private var sidebarTintColorDarkBinding: Binding<Color> {
        Binding(
            get: { Color(hex: appearance.sidebarTintColorHexDark ?? appearance.sidebarTintColorHex) ?? .black },
            set: { if let hex = $0.hexString { appearance.sidebarTintColorHexDark = hex } }
        )
    }
}

// MARK: - TerminalFontSettingsView

struct TerminalFontSettingsView: View {
    @AppStorage("namu.terminal.fontFamily")    private var fontFamily: String  = ""
    @AppStorage("namu.terminal.fontSize")      private var fontSize: Double    = 13.0
    @AppStorage("namu.terminal.lineHeight")    private var lineHeight: Double  = 1.2
    @AppStorage("namu.terminal.letterSpacing") private var letterSpacing: Double = 0.0

    var body: some View {
        LabeledContent(String(localized: "settings.appearance.font.family", defaultValue: "Family")) {
            TextField(String(localized: "settings.appearance.font.familyPlaceholder", defaultValue: "Default (system mono)"), text: $fontFamily)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12, design: .monospaced))
                .frame(maxWidth: 200)
        }
        LabeledContent(String(localized: "settings.appearance.font.size", defaultValue: "Size")) {
            Stepper(value: $fontSize, in: 6...36, step: 1) {
                Text("\(Int(fontSize)) pt")
                    .font(.system(size: 12, design: .monospaced))
                    .frame(width: 50, alignment: .leading)
            }
        }
        LabeledContent(String(localized: "settings.appearance.font.lineHeight", defaultValue: "Line Height")) {
            HStack(spacing: 8) {
                Slider(value: $lineHeight, in: 0.8...2.0, step: 0.05)
                    .frame(maxWidth: 140)
                Text(String(format: "%.2f", lineHeight))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(width: 36, alignment: .trailing)
            }
        }
        LabeledContent(String(localized: "settings.appearance.font.spacing", defaultValue: "Letter Spacing")) {
            HStack(spacing: 8) {
                Slider(value: $letterSpacing, in: -2.0...4.0, step: 0.5)
                    .frame(maxWidth: 140)
                Text(String(format: "%.1f", letterSpacing))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(width: 36, alignment: .trailing)
            }
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
