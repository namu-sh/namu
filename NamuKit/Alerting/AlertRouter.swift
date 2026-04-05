import Foundation
import os.log

private let logger = Logger(subsystem: "com.namu.app", category: "AlertRouter")

/// Routes fired alerts to all enabled channels.
/// Actor-isolated for thread safety.
actor AlertRouter {

    private var channels: [any AlertChannel] = []
    private let credentialStore: ChannelCredentialStore

    init(credentialStore: ChannelCredentialStore) {
        self.credentialStore = credentialStore
    }

    /// Rebuild the active channel list from credential store.
    /// Call on startup and whenever channel config changes.
    func reloadChannels() async {
        var active: [any AlertChannel] = []

        if await credentialStore.isEnabled("slack"),
           let url = await credentialStore.credential("slack", "webhookURL") {
            active.append(SlackChannel(webhookURL: url))
        }

        if await credentialStore.isEnabled("telegram"),
           let token = await credentialStore.credential("telegram", "botToken"),
           let chatID = await credentialStore.credential("telegram", "chatID") {
            active.append(TelegramChannel(botToken: token, chatID: chatID))
        }

        if await credentialStore.isEnabled("discord"),
           let url = await credentialStore.credential("discord", "webhookURL") {
            active.append(DiscordChannel(webhookURL: url))
        }

        if await credentialStore.isEnabled("webhook"),
           let url = await credentialStore.credential("webhook", "url") {
            let token = await credentialStore.credential("webhook", "bearerToken")
            active.append(WebhookChannel(url: url, bearerToken: token))
        }

        channels = active
        logger.info("Alert channels reloaded: \(active.map(\.id).joined(separator: ", "))")
    }

    /// Fan-out an alert to all enabled channels. Errors are logged, not thrown.
    func route(_ payload: AlertPayload) async {
        guard !channels.isEmpty else { return }

        await withTaskGroup(of: Void.self) { group in
            for channel in channels {
                group.addTask {
                    do {
                        try await channel.send(payload)
                        logger.info("Alert sent via \(channel.id): \(payload.ruleName)")
                    } catch {
                        logger.error("Alert failed via \(channel.id): \(error.localizedDescription)")
                    }
                }
            }
        }
    }

    /// Send a test alert to a specific channel. Throws on failure.
    func testChannel(_ channelID: String) async throws {
        let testPayload = AlertPayload(
            ruleName: "Test Alert",
            event: "test",
            summary: "This is a test alert from Namu",
            workspaceTitle: "Test",
            timestamp: Date()
        )

        guard let channel = channels.first(where: { $0.id == channelID }) else {
            throw AlertChannelError.notConfigured(channelID)
        }

        try await channel.send(testPayload)
    }

    /// Currently enabled channel IDs.
    var enabledChannelIDs: [String] {
        channels.map(\.id)
    }

    /// Replace the active channel list directly. Intended for testing only.
    func setChannels(_ newChannels: [any AlertChannel]) {
        channels = newChannels
    }
}
