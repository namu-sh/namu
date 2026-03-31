import Foundation

/// Sends alerts to a Discord channel via webhook.
struct DiscordChannel: AlertChannel, Sendable {
    let id = "discord"
    let displayName = "Discord"

    private static let isoFormatter = ISO8601DateFormatter()
    private let webhookURL: String
    private let session: URLSession

    init(webhookURL: String, session: URLSession = .shared) {
        self.webhookURL = webhookURL
        self.session = session
    }

    func send(_ payload: AlertPayload) async throws {
        guard let url = URL(string: webhookURL) else {
            throw AlertChannelError.notConfigured("Discord webhook URL is invalid")
        }

        // Discord embed format
        let body: [String: Any] = [
            "embeds": [
                [
                    "title": payload.ruleName,
                    "description": payload.summary,
                    "color": 15158332, // red
                    "fields": [
                        ["name": "Event", "value": "`\(payload.event)`", "inline": true],
                        ["name": "Workspace", "value": payload.workspaceTitle, "inline": true]
                    ],
                    "timestamp": Self.isoFormatter.string(from: payload.timestamp)
                ]
            ]
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 10

        let (_, response) = try await session.data(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw AlertChannelError.sendFailed("Discord", underlyingError: nil)
        }

        if http.statusCode == 429 {
            throw AlertChannelError.rateLimited
        }

        guard (200..<300).contains(http.statusCode) else {
            throw AlertChannelError.invalidResponse(http.statusCode)
        }
    }
}
