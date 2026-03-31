import Foundation

/// Sends alerts to any URL as a JSON POST. Supports optional bearer token auth.
struct WebhookChannel: AlertChannel, Sendable {
    let id = "webhook"
    let displayName = "Webhook"

    private let url: String
    private let bearerToken: String?
    private let session: URLSession

    init(url: String, bearerToken: String? = nil, session: URLSession = .shared) {
        self.url = url
        self.bearerToken = bearerToken
        self.session = session
    }

    func send(_ payload: AlertPayload) async throws {
        guard let endpoint = URL(string: url) else {
            throw AlertChannelError.notConfigured("Webhook URL is invalid")
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        if let token = bearerToken, !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        request.httpBody = try JSONEncoder().encode(payload)
        request.timeoutInterval = 10

        let (_, response) = try await session.data(for: request)

        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw AlertChannelError.invalidResponse(code)
        }
    }
}
