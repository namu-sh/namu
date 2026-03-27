import SwiftUI

// MARK: - SettingsView

struct SettingsView: View {
    @State private var selectedSection: SettingsSection = .ai

    enum SettingsSection: String, CaseIterable, Identifiable {
        case general    = "General"
        case appearance = "Appearance"
        case ai         = "AI Providers"
        case keyboard   = "Keyboard"
        case updates    = "Updates"

        var id: String { rawValue }

        var icon: String {
            switch self {
            case .general:    return "gearshape"
            case .appearance: return "paintbrush"
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
                            Text(section.rawValue)
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
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            sectionHeader("General", subtitle: "Appearance and behavior settings")

            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("Version")
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
            sectionHeader("Updates", subtitle: "Keep Namu up to date")

            GroupBox {
                VStack(alignment: .leading, spacing: 16) {
                    // Current version
                    HStack {
                        Text("Current Version")
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
                            Text("Automatic updates")
                                .font(.system(size: 13))
                            Text("Automatically check for updates in the background")
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
                            Text(viewModel.isChecking ? "Checking..." : "Check for Updates")
                        }
                        .disabled(viewModel.isChecking)

                        Text(viewModel.statusText)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }

                    // Last check date
                    if let lastCheck = UpdateController.shared.lastUpdateCheckDate {
                        Text("Last checked: \(lastCheck, style: .relative) ago")
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
                        Text("Sparkle auto-update integration will be available in the distributed release.")
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
            sectionHeader("AI Providers", subtitle: "Configure API keys for each provider. Enable the ones you want to use.")

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
                            Text(ready ? "Ready" : "Needs key")
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
                        TextField("Base URL", text: Binding(
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
                        Text("Models:")
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
