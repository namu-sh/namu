import Foundation

// MARK: - Analytics

/// Opt-in telemetry integration (PostHog + Sentry).
///
/// Analytics are **disabled by default**. The user must explicitly opt in
/// via Settings. No data is sent until consent is granted.
///
/// Supported backends:
/// - PostHog: product analytics (event tracking)
/// - Sentry: error and crash reporting
///
/// Usage:
///   Analytics.shared.track("pane_split", properties: ["direction": "horizontal"])
///   Analytics.shared.captureError(error, context: "PanelManager.split")
final class Analytics {

    static let shared = Analytics()

    // MARK: - UserDefaults keys

    private static let optInKey = "namu.analytics.optIn"
    private static let posthogKeyKey = "namu.analytics.posthogKey"
    private static let sentryDSNKey = "namu.analytics.sentryDSN"
    private static let userIDKey = "namu.analytics.userID"

    // MARK: - State

    private(set) var isOptedIn: Bool {
        get { UserDefaults.standard.bool(forKey: Self.optInKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.optInKey) }
    }

    /// A stable anonymous user ID for this install.
    private lazy var userID: String = {
        if let existing = UserDefaults.standard.string(forKey: Self.userIDKey) {
            return existing
        }
        let new = UUID().uuidString
        UserDefaults.standard.set(new, forKey: Self.userIDKey)
        return new
    }()

    private let appVersion: String = Bundle.main.object(
        forInfoDictionaryKey: "CFBundleShortVersionString"
    ) as? String ?? "0.0.0"

    private let session = URLSession(configuration: .ephemeral)
    private let queue = DispatchQueue(label: "com.namu.analytics", qos: .background)

    private init() {}

    // MARK: - Consent

    /// Opt in to analytics. Sends a single "analytics_opted_in" event.
    func optIn() {
        isOptedIn = true
        track("analytics_opted_in")
    }

    /// Opt out. Clears the user ID so future opt-ins get a fresh ID.
    func optOut() {
        isOptedIn = false
        UserDefaults.standard.removeObject(forKey: Self.userIDKey)
    }

    // MARK: - Event tracking (PostHog)

    /// Track a product event.
    /// - Parameters:
    ///   - event: Event name, e.g. "pane_split".
    ///   - properties: Optional key/value metadata.
    func track(_ event: String, properties: [String: Any] = [:]) {
        guard isOptedIn else { return }
        guard let apiKey = UserDefaults.standard.string(forKey: Self.posthogKeyKey),
              !apiKey.isEmpty else { return }

        queue.async { [weak self] in
            guard let self else { return }
            var props = properties
            props["app_version"] = self.appVersion
            props["platform"] = "macOS"

            let payload: [String: Any] = [
                "api_key": apiKey,
                "event": event,
                "distinct_id": self.userID,
                "timestamp": ISO8601DateFormatter().string(from: Date()),
                "properties": props
            ]
            self.postJSON(
                to: "https://app.posthog.com/capture/",
                body: payload
            )
        }
    }

    // MARK: - Error reporting (Sentry)

    /// Capture an error for Sentry.
    /// - Parameters:
    ///   - error: The error to report.
    ///   - context: A short string describing where the error occurred.
    func captureError(_ error: Error, context: String = "") {
        guard isOptedIn else { return }
        guard let dsn = UserDefaults.standard.string(forKey: Self.sentryDSNKey),
              !dsn.isEmpty,
              let (sentryKey, projectID) = parseDSN(dsn) else { return }

        queue.async { [weak self] in
            guard let self else { return }
            let event: [String: Any] = [
                "event_id": UUID().uuidString.replacingOccurrences(of: "-", with: ""),
                "timestamp": ISO8601DateFormatter().string(from: Date()),
                "platform": "cocoa",
                "release": "namu@\(self.appVersion)",
                "exception": [
                    "values": [[
                        "type": String(describing: type(of: error)),
                        "value": error.localizedDescription,
                        "module": context
                    ]]
                ],
                "user": ["id": self.userID]
            ]
            let url = "https://sentry.io/api/\(projectID)/store/"
            self.postJSON(to: url, body: event, authHeader: "Sentry sentry_key=\(sentryKey),sentry_version=7")
        }
    }

    // MARK: - Configuration helpers

    /// Configure the PostHog API key. Stored in UserDefaults (not Keychain —
    /// this is a project-level key, not a user secret).
    func configure(posthogKey: String) {
        UserDefaults.standard.set(posthogKey, forKey: Self.posthogKeyKey)
    }

    /// Configure the Sentry DSN.
    func configure(sentryDSN: String) {
        UserDefaults.standard.set(sentryDSN, forKey: Self.sentryDSNKey)
    }

    // MARK: - Private helpers

    private func postJSON(to urlString: String, body: [String: Any], authHeader: String? = nil) {
        guard let url = URL(string: urlString),
              let data = try? JSONSerialization.data(withJSONObject: body) else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let auth = authHeader {
            request.setValue(auth, forHTTPHeaderField: "X-Sentry-Auth")
        }
        request.httpBody = data
        let task = session.dataTask(with: request)
        task.resume()
    }

    /// Parse a Sentry DSN into (key, projectID).
    /// DSN format: https://<key>@<host>/<projectID>
    private func parseDSN(_ dsn: String) -> (key: String, projectID: String)? {
        guard let url = URL(string: dsn),
              let key = url.user,
              !key.isEmpty else { return nil }
        let projectID = url.lastPathComponent.trimmingCharacters(in: .init(charactersIn: "/"))
        guard !projectID.isEmpty else { return nil }
        return (key, projectID)
    }
}
