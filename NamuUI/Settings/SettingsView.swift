import SwiftUI

// MARK: - SettingsView

struct SettingsView: View {
    @State private var selectedSection: SettingsSection = .ai

    enum SettingsSection: String, CaseIterable, Identifiable {
        case general    = "General"
        case appearance = "Appearance"
        case colors     = "Workspace Colors"
        case ai         = "AI Providers"
        case keyboard   = "Keyboard"
        case updates    = "Updates"

        var id: String { rawValue }

        var localizedTitle: String {
            switch self {
            case .general:    return String(localized: "settings.section.general", defaultValue: "General")
            case .appearance: return String(localized: "settings.section.appearance", defaultValue: "Appearance")
            case .colors:     return String(localized: "settings.section.colors", defaultValue: "Workspace Colors")
            case .ai:         return String(localized: "settings.section.ai", defaultValue: "AI Providers")
            case .keyboard:   return String(localized: "settings.section.keyboard", defaultValue: "Keyboard")
            case .updates:    return String(localized: "settings.section.updates", defaultValue: "Updates")
            }
        }

        var icon: String {
            switch self {
            case .general:    return "gearshape"
            case .appearance: return "paintbrush"
            case .colors:     return "swatchpalette"
            case .ai:         return "sparkles"
            case .keyboard:   return "keyboard"
            case .updates:    return "arrow.triangle.2.circlepath"
            }
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            // Left navigation
            VStack(alignment: .leading, spacing: 2) {
                ForEach(SettingsSection.allCases) { section in
                    Button(action: { selectedSection = section }) {
                        HStack(spacing: 8) {
                            Image(systemName: section.icon)
                                .font(.system(size: 12))
                                .frame(width: 16)
                            Text(section.localizedTitle)
                                .font(.system(size: 13))
                        }
                        .foregroundStyle(selectedSection == section ? .white : .secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(
                            selectedSection == section
                                ? RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.1))
                                : nil
                        )
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
            }
            .frame(width: 160)
            .padding(.top, 16)
            .padding(.horizontal, 8)

            // Separator
            Rectangle()
                .fill(Color.white.opacity(0.08))
                .frame(width: 1)

            // Content
            Group {
                switch selectedSection {
                case .general:
                    ScrollView { GeneralSettingsContent() }
                case .appearance:
                    ScrollView { AppearanceSettingsView() }
                case .colors:
                    ScrollView { WorkspaceColorsSettingsContent() }
                case .ai:
                    ScrollView { AISettingsContent() }
                case .keyboard:
                    KeyboardSettingsContent()
                case .updates:
                    ScrollView { UpdateSettingsContent() }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color.black.opacity(0.3))
    }
}

// MARK: - General

private struct GeneralSettingsContent: View {
    @State private var autoReorderEnabled: Bool = WorkspaceAutoReorderSettings.isEnabled()

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            sectionHeader(String(localized: "settings.general.title", defaultValue: "General"), subtitle: String(localized: "settings.general.subtitle", defaultValue: "Appearance and behavior settings"))

            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text(String(localized: "settings.general.version.label", defaultValue: "Version"))
                            .font(.system(size: 13))
                        Spacer()
                        Text(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0")
                            .font(.system(size: 13, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(4)
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    Toggle(String(localized: "settings.notifications.autoReorder", defaultValue: "Reorder on Notification"), isOn: $autoReorderEnabled)
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .onChange(of: autoReorderEnabled) { _, newValue in
                            WorkspaceAutoReorderSettings.setEnabled(newValue)
                        }
                    Text(String(localized: "settings.notifications.autoReorder.description", defaultValue: "Move workspaces to the top when they receive a notification. Disable for stable shortcut positions."))
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(4)
            }
        }
        .padding(24)
    }
}

// MARK: - Updates (Sparkle stub)

private struct UpdateSettingsContent: View {
    @State private var automaticUpdates: Bool = UpdateController.shared.automaticallyChecksForUpdates
    @ObservedObject private var viewModel = UpdateController.shared.viewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            sectionHeader(String(localized: "settings.updates.title", defaultValue: "Updates"), subtitle: String(localized: "settings.updates.subtitle", defaultValue: "Keep Namu up to date"))

            GroupBox {
                VStack(alignment: .leading, spacing: 16) {
                    // Current version
                    HStack {
                        Text(String(localized: "settings.updates.currentVersion.label", defaultValue: "Current Version"))
                            .font(.system(size: 13))
                        Spacer()
                        Text(viewModel.currentVersion)
                            .font(.system(size: 13, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }

                    Divider().opacity(0.3)

                    // Automatic updates toggle
                    Toggle(isOn: $automaticUpdates) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(String(localized: "settings.updates.automatic.label", defaultValue: "Automatic updates"))
                                .font(.system(size: 13))
                            Text(String(localized: "settings.updates.automatic.description", defaultValue: "Automatically check for updates in the background"))
                                .font(.system(size: 11))
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .onChange(of: automaticUpdates) { _, newValue in
                        UpdateController.shared.automaticallyChecksForUpdates = newValue
                    }

                    Divider().opacity(0.3)

                    // Check for updates button
                    HStack {
                        Button(action: { UpdateController.shared.checkForUpdates() }) {
                            if viewModel.isChecking {
                                ProgressView()
                                    .scaleEffect(0.6)
                                    .frame(width: 14, height: 14)
                            }
                            Text(viewModel.isChecking ? String(localized: "settings.updates.checkButton.checking", defaultValue: "Checking...") : String(localized: "settings.updates.checkButton", defaultValue: "Check for Updates"))
                        }
                        .disabled(viewModel.isChecking)

                        Text(viewModel.statusText)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }

                    // Last check date
                    if let lastCheck = UpdateController.shared.lastUpdateCheckDate {
                        Text(String(localized: "settings.updates.lastChecked", defaultValue: "Last checked: \(lastCheck.formatted(.relative(presentation: .named))) ago"))
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(4)
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        Image(systemName: "info.circle")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                        Text(String(localized: "settings.updates.sparkleNote", defaultValue: "Sparkle auto-update integration will be available in the distributed release."))
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(4)
            }
        }
        .padding(24)
    }
}

// MARK: - AI Providers

private struct AISettingsContent: View {
    @State private var entries: [AIProviderType: AIProviderEntry] = [:]
    private let config = AIProviderConfig.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            sectionHeader(String(localized: "settings.ai.title", defaultValue: "AI Providers"), subtitle: String(localized: "settings.ai.subtitle", defaultValue: "Configure API keys for each provider. Enable the ones you want to use."))

            ForEach(AIProviderType.allCases) { type in
                providerCard(type)
            }
        }
        .padding(24)
        .onAppear { loadEntries() }
    }

    @ViewBuilder
    private func providerCard(_ type: AIProviderType) -> some View {
        let entry = entries[type] ?? .disabled()

        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Image(systemName: type.icon)
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                        .frame(width: 20)

                    Text(type.rawValue)
                        .font(.system(size: 14, weight: .semibold))

                    Spacer()

                    // Status
                    if entry.enabled {
                        let hasKey = !entry.apiKey.trimmingCharacters(in: .whitespaces).isEmpty
                        let ready = type == .custom || hasKey
                        HStack(spacing: 4) {
                            Circle().fill(ready ? Color.green : Color.orange).frame(width: 6, height: 6)
                            Text(ready ? String(localized: "settings.ai.status.ready", defaultValue: "Ready") : String(localized: "settings.ai.status.needsKey", defaultValue: "Needs key"))
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                    }

                    Toggle("", isOn: Binding(
                        get: { entry.enabled },
                        set: { newValue in
                            var updated = entries[type] ?? .disabled()
                            updated.enabled = newValue
                            entries[type] = updated
                            config.setEntry(for: type, entry: updated)
                        }
                    ))
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .controlSize(.small)
                }

                if entry.enabled {
                    SecureField(type.apiKeyPlaceholder, text: Binding(
                        get: { entry.apiKey },
                        set: { newValue in
                            var updated = entries[type] ?? .disabled()
                            updated.apiKey = newValue
                            entries[type] = updated
                            config.setEntry(for: type, entry: updated)
                        }
                    ))
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))

                    if type == .custom {
                        TextField(String(localized: "settings.ai.customBaseURL.placeholder", defaultValue: "Base URL"), text: Binding(
                            get: { entry.baseURL ?? "http://localhost:11434/v1" },
                            set: { newValue in
                                var updated = entries[type] ?? .disabled()
                                updated.baseURL = newValue
                                entries[type] = updated
                                config.setEntry(for: type, entry: updated)
                            }
                        ))
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12, design: .monospaced))
                    }

                    // Models available
                    HStack(spacing: 4) {
                        Text(String(localized: "settings.ai.modelsLabel", defaultValue: "Models:"))
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                        Text(type.models.joined(separator: ", "))
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            .padding(4)
        }
    }

    private func loadEntries() {
        config.load()
        for type in AIProviderType.allCases {
            entries[type] = config.entry(for: type)
        }
    }
}

// MARK: - Workspace Colors

private struct WorkspaceColorsSettingsContent: View {
    @Environment(\.colorScheme) private var colorScheme
    @State private var overrides: [String: String] = WorkspaceColorPaletteSettings.colorOverrides()
    @State private var customColors: [String] = WorkspaceColorPaletteSettings.customColors()
    @State private var newHexInput: String = ""
    @State private var showHexError: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            sectionHeader(
                String(localized: "settings.colors.title", defaultValue: "Workspace Colors"),
                subtitle: String(localized: "settings.colors.subtitle", defaultValue: "Customize the accent colors available for workspaces.")
            )

            // Named defaults with per-color override fields
            GroupBox {
                VStack(alignment: .leading, spacing: 14) {
                    Text(String(localized: "settings.colors.palette.label", defaultValue: "Color Palette"))
                        .font(.system(size: 13, weight: .semibold))

                    let columns = [GridItem(.adaptive(minimum: 220, maximum: 260), spacing: 8)]
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 6) {
                        ForEach(WorkspaceColorPaletteSettings.namedDefaults, id: \.name) { entry in
                            namedColorRow(name: entry.name, defaultHex: entry.hex)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(4)
            }

            // Custom additional colors
            GroupBox {
                VStack(alignment: .leading, spacing: 14) {
                    Text(String(localized: "settings.colors.custom.label", defaultValue: "Custom Colors"))
                        .font(.system(size: 13, weight: .semibold))

                    let swatchColumns = [GridItem(.adaptive(minimum: 36, maximum: 36), spacing: 8)]
                    if !customColors.isEmpty {
                        LazyVGrid(columns: swatchColumns, alignment: .leading, spacing: 8) {
                            ForEach(customColors, id: \.self) { hex in
                                customColorSwatch(hex: hex)
                            }
                        }
                    }

                    HStack(spacing: 8) {
                        TextField(
                            String(localized: "settings.colors.hexInput.placeholder", defaultValue: "#RRGGBB"),
                            text: $newHexInput
                        )
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12, design: .monospaced))
                        .frame(width: 100)

                        Button(String(localized: "settings.colors.addButton", defaultValue: "Add")) {
                            addCustomColor()
                        }
                        .disabled(newHexInput.trimmingCharacters(in: .whitespaces).isEmpty)

                        if showHexError {
                            Text(String(localized: "settings.colors.hexError", defaultValue: "Invalid hex color"))
                                .font(.system(size: 11))
                                .foregroundStyle(.red)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(4)
            }

            Button(String(localized: "settings.colors.resetButton", defaultValue: "Reset to Defaults")) {
                WorkspaceColorPaletteSettings.resetToDefaults()
                overrides = [:]
                customColors = []
            }
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
        }
        .padding(24)
    }

    // MARK: - Named color row

    @ViewBuilder
    private func namedColorRow(name: String, defaultHex: String) -> some View {
        let effectiveHex = overrides[name] ?? defaultHex
        let isDark = colorScheme == .dark
        let displayHex = WorkspaceColorPaletteSettings.adjustedColor(hex: effectiveHex, isDarkMode: isDark)
        let swatch = Color(hex: displayHex) ?? .gray
        let hasOverride = overrides[name] != nil
        let overrideText = Binding<String>(
            get: { overrides[name] ?? "" },
            set: { newVal in
                let trimmed = newVal.trimmingCharacters(in: .whitespaces)
                if trimmed.isEmpty {
                    overrides.removeValue(forKey: name)
                    WorkspaceColorPaletteSettings.removeOverride(name: name)
                } else {
                    overrides[name] = trimmed
                    WorkspaceColorPaletteSettings.setOverride(name: name, hex: trimmed)
                }
            }
        )

        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 5)
                .fill(swatch)
                .frame(width: 28, height: 28)
                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color.white.opacity(0.15), lineWidth: 1))

            Text(name)
                .font(.system(size: 12))
                .frame(width: 48, alignment: .leading)

            TextField(defaultHex, text: overrideText)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(hasOverride ? .primary : .tertiary)

            if hasOverride {
                Button(action: {
                    overrides.removeValue(forKey: name)
                    WorkspaceColorPaletteSettings.removeOverride(name: name)
                }) {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.system(size: 10))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help(String(localized: "settings.colors.revertOverride.tooltip", defaultValue: "Revert to default"))
            }
        }
    }

    // MARK: - Custom swatch

    @ViewBuilder
    private func customColorSwatch(hex: String) -> some View {
        let color = Color(hex: hex) ?? .gray
        ZStack(alignment: .topTrailing) {
            RoundedRectangle(cornerRadius: 6)
                .fill(color)
                .frame(width: 36, height: 36)

            Button(action: {
                WorkspaceColorPaletteSettings.removeCustomColor(hex)
                customColors = WorkspaceColorPaletteSettings.customColors()
            }) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(.white)
                    .background(Circle().fill(Color.black.opacity(0.4)))
            }
            .buttonStyle(.plain)
            .offset(x: 4, y: -4)
        }
        .frame(width: 44, height: 44)
    }

    // MARK: - Add custom

    private func addCustomColor() {
        var hex = newHexInput.trimmingCharacters(in: .whitespaces)
        if !hex.hasPrefix("#") { hex = "#" + hex }
        guard hex.count == 7, Color(hex: hex) != nil else {
            showHexError = true
            return
        }
        showHexError = false
        WorkspaceColorPaletteSettings.addCustomColor(hex)
        customColors = WorkspaceColorPaletteSettings.customColors()
        newHexInput = ""
    }
}

// MARK: - Keyboard

private struct KeyboardSettingsContent: View {
    var body: some View {
        KeyboardShortcutSettingsView()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.top, 8)
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
