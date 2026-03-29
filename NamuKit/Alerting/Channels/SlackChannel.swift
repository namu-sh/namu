import Foundation

/// Sends alerts to a Slack channel via incoming webhook.
struct SlackChannel: AlertChannel, Sendable {
    let id = "slack"
    let displayName = "Slack"

    private let webhookURL: String

    init(webhookURL: String) {
        self.webhookURL = webhookURL
    }

    func send(_ payload: AlertPayload) async throws {
        guard let url = URL(string: webhookURL) else {
            throw AlertChannelError.notConfigured("Slack webhook URL is invalid")
        }

        // Slack Block Kit format for rich messages
        let body: [String: Any] = [
            "text": payload.plainBody,
            "blocks": [
                [
                    "type": "section",
                    "text": [
                        "type": "mrkdwn",
                        "text": "*\(payload.ruleName)* — \(payload.summary)"
                    ]
                ],
                [
                    "type": "context",
                    "elements": [
                        ["type": "mrkdwn", "text": "Event: `\(payload.event)` | Workspace: \(payload.workspaceTitle)"]
                    ]
                ]
            ]
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (_, response) = try await URLSession.shared.data(for: request)

        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw AlertChannelError.invalidResponse(code)
        }
    }
}
