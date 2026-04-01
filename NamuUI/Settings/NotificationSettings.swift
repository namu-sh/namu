import SwiftUI

// MARK: - NotificationSettingsView

struct NotificationSettingsView: View {
    @AppStorage("namu.alerting.slack.enabled") private var slackEnabled = false
    @AppStorage("namu.alerting.telegram.enabled") private var telegramEnabled = false
    @AppStorage("namu.alerting.discord.enabled") private var discordEnabled = false
    @AppStorage("namu.alerting.webhook.enabled") private var webhookEnabled = false

    @State private var slackWebhookURL = ""
    @State private var telegramBotToken = ""
    @State private var telegramChatID = ""
    @State private var discordWebhookURL = ""
    @State private var webhookURL = ""
    @State private var webhookBearerToken = ""
    @State private var saveMessage: String?

    var body: some View {
        Form {
            // MARK: - Slack
            Section {
                Toggle(isOn: $slackEnabled) {
                    Label("Slack", systemImage: "number.square")
                }

                if slackEnabled {
                    SecureField("Webhook URL", text: $slackWebhookURL)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12, design: .monospaced))

                    saveButton { save("slack", "webhookURL", slackWebhookURL) }
                        .disabled(slackWebhookURL.isEmpty)
                }
            } header: {
                Text("Alert Channels")
            } footer: {
                Text("Route notifications to external services when agents complete tasks or alerts trigger.")
            }

            // MARK: - Telegram
            Section {
                Toggle(isOn: $telegramEnabled) {
                    Label("Telegram", systemImage: "paperplane")
                }

                if telegramEnabled {
                    SecureField("Bot Token", text: $telegramBotToken)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12, design: .monospaced))

                    TextField("Chat ID", text: $telegramChatID)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12, design: .monospaced))

                    saveButton {
                        save("telegram", "botToken", telegramBotToken)
                        save("telegram", "chatID", telegramChatID)
                    }
                    .disabled(telegramBotToken.isEmpty || telegramChatID.isEmpty)
                }
            }

            // MARK: - Discord
            Section {
                Toggle(isOn: $discordEnabled) {
                    Label("Discord", systemImage: "gamecontroller")
                }

                if discordEnabled {
                    SecureField("Webhook URL", text: $discordWebhookURL)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12, design: .monospaced))

                    saveButton { save("discord", "webhookURL", discordWebhookURL) }
                        .disabled(discordWebhookURL.isEmpty)
                }
            }

            // MARK: - Custom Webhook
            Section {
                Toggle(isOn: $webhookEnabled) {
                    Label("Custom Webhook", systemImage: "globe")
                }

                if webhookEnabled {
                    TextField("URL", text: $webhookURL)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12, design: .monospaced))

                    SecureField("Bearer Token (optional)", text: $webhookBearerToken)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12, design: .monospaced))

                    saveButton {
                        save("webhook", "url", webhookURL)
                        if !webhookBearerToken.isEmpty {
                            save("webhook", "bearerToken", webhookBearerToken)
                        }
                    }
                    .disabled(webhookURL.isEmpty)
                }
            }

            // MARK: - Save confirmation
            if let msg = saveMessage {
                Section {
                    Label(msg, systemImage: "checkmark.circle")
                        .foregroundStyle(.green)
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .onAppear { loadCredentials() }
    }

    // MARK: - Save Button

    private func saveButton(_ action: @escaping () -> Void) -> some View {
        HStack {
            Spacer()
            Button("Save", action: action)
        }
    }

    // MARK: - Keychain

    private func save(_ channel: String, _ name: String, _ value: String) {
        let account = "\(channel).\(name)"
        let data = Data(value.utf8)
        let service = "xyz.omlabs.namu.alerting"

        SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ] as CFDictionary)

        SecItemAdd([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked,
        ] as CFDictionary, nil)

        UserDefaults.standard.set(true, forKey: "namu.alerting.\(channel).configured")
        NotificationCenter.default.post(name: Notification.Name("namu.alerting.channelsUpdated"), object: nil)

        saveMessage = "\(channel.capitalized) saved"
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { saveMessage = nil }
    }

    private func loadCredentials() {
        slackWebhookURL = load("slack", "webhookURL")
        telegramBotToken = load("telegram", "botToken")
        telegramChatID = load("telegram", "chatID")
        discordWebhookURL = load("discord", "webhookURL")
        webhookURL = load("webhook", "url")
        webhookBearerToken = load("webhook", "bearerToken")
    }

    private func load(_ channel: String, _ name: String) -> String {
        let account = "\(channel).\(name)"
        var result: AnyObject?
        SecItemCopyMatching([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "xyz.omlabs.namu.alerting",
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ] as CFDictionary, &result)
        guard let data = result as? Data else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }
}
