import Foundation

// MARK: - Alert Rule

/// A single rule that the AlertEngine evaluates against EventBus events.
struct AlertRule: Identifiable, Codable, Sendable {
    let id: UUID
    var name: String
    var isEnabled: Bool
    var trigger: AlertTrigger
    var workspaceID: UUID?      // nil = applies to all workspaces

    init(
        id: UUID = UUID(),
        name: String,
        isEnabled: Bool = true,
        trigger: AlertTrigger,
        workspaceID: UUID? = nil
    ) {
        self.id = id
        self.name = name
        self.isEnabled = isEnabled
        self.trigger = trigger
        self.workspaceID = workspaceID
    }
}

// MARK: - Alert Trigger

enum AlertTrigger: Codable, Sendable {
    /// Fires when a process exits with a matching exit code (nil = any code).
    case processExit(exitCode: Int?)
    /// Fires when terminal output contains `pattern` (substring match).
    case outputMatch(pattern: String, caseSensitive: Bool)
    /// Fires when a port in the given set opens or closes.
    case portChange(ports: [Int])
    /// Fires when the shell has been idle for at least `seconds`.
    case shellIdle(seconds: Double)

    // MARK: Codable

    private enum CodingKeys: String, CodingKey {
        case type, exitCode, pattern, caseSensitive, ports, seconds
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let type = try c.decode(String.self, forKey: .type)
        switch type {
        case "processExit":
            self = .processExit(exitCode: try c.decodeIfPresent(Int.self, forKey: .exitCode))
        case "outputMatch":
            let pattern = try c.decode(String.self, forKey: .pattern)
            let cs = try c.decodeIfPresent(Bool.self, forKey: .caseSensitive) ?? true
            self = .outputMatch(pattern: pattern, caseSensitive: cs)
        case "portChange":
            self = .portChange(ports: try c.decode([Int].self, forKey: .ports))
        case "shellIdle":
            self = .shellIdle(seconds: try c.decode(Double.self, forKey: .seconds))
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type,
                in: c,
                debugDescription: "Unknown trigger type: \(type)"
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .processExit(let code):
            try c.encode("processExit", forKey: .type)
            try c.encodeIfPresent(code, forKey: .exitCode)
        case .outputMatch(let pattern, let cs):
            try c.encode("outputMatch", forKey: .type)
            try c.encode(pattern, forKey: .pattern)
            try c.encode(cs, forKey: .caseSensitive)
        case .portChange(let ports):
            try c.encode("portChange", forKey: .type)
            try c.encode(ports, forKey: .ports)
        case .shellIdle(let seconds):
            try c.encode("shellIdle", forKey: .type)
            try c.encode(seconds, forKey: .seconds)
        }
    }
}

// MARK: - Alert Fired

/// Emitted when a rule matches an incoming event.
struct FiredAlert: Sendable {
    let rule: AlertRule
    let event: NamuEvent
    let params: [String: JSONRPCValue]
    let firedAt: Date

    /// Human-readable summary for alert channels.
    var summary: String {
        switch rule.trigger {
        case .processExit(let watchCode):
            let code = params["exit_code"].flatMap { if case .int(let i) = $0 { return i } else { return nil } }
            let watching = watchCode.map { "watching: \($0)" } ?? "any exit"
            return "Process exited with code \(code ?? 0) (\(watching))"
        case .outputMatch(let pattern, _):
            return "Output matched pattern: \(pattern)"
        case .portChange(let ports):
            return "Port change detected (watching: \(ports.map { "\($0)" }.joined(separator: ",")))"
        case .shellIdle(let seconds):
            return "Shell idle for \(Int(seconds))s"
        }
    }

    /// Workspace title from params, if available.
    var workspaceTitle: String? {
        if case .string(let title) = params["workspace_title"] { return title }
        return nil
    }
}

// MARK: - AlertEngineDelegate

protocol AlertEngineDelegate: AnyObject, Sendable {
    func alertEngine(_ engine: AlertEngine, didFire alert: FiredAlert)
}

// MARK: - AlertEngine

/// Rule-based detection layer that subscribes to EventBus events and evaluates
/// configured AlertRules. No LLM involvement — pure pattern matching.
///
/// Rules are evaluated synchronously on whatever thread EventBus fires on.
/// Delegate callbacks are dispatched to the main actor.
final class AlertEngine: @unchecked Sendable {

    // MARK: - Properties

    private let eventBus: EventBus
    private let lock = NSLock()
    private var _rules: [AlertRule] = []
    private var subscriptionID: UUID?
    weak var delegate: (any AlertEngineDelegate)?

    /// Optional alert router. When set, fired alerts are forwarded to
    /// configured channels (Slack, Telegram, Discord, etc.).
    /// Access is lock-protected for thread safety.
    private var _alertRouter: AlertRouter?

    func setAlertRouter(_ router: AlertRouter?) {
        lock.withLock { _alertRouter = router }
    }

    // MARK: - Init / Deinit

    init(eventBus: EventBus) {
        self.eventBus = eventBus
    }

    deinit {
        stop()
    }

    // MARK: - Lifecycle

    /// Start listening to all relevant EventBus events.
    func start() {
        let id = eventBus.subscribe(
            events: [.processExit, .outputMatch, .portChange, .shellIdle] as Set<NamuEvent>
        ) { [weak self] data in
            self?.handleRawEvent(data)
        }
        lock.withLock { subscriptionID = id }
    }

    /// Stop listening. Safe to call multiple times.
    func stop() {
        let id = lock.withLock { () -> UUID? in
            defer { subscriptionID = nil }
            return subscriptionID
        }
        if let id { eventBus.unsubscribe(id) }
    }

    // MARK: - Rule Management

    var rules: [AlertRule] {
        lock.withLock { _rules }
    }

    func setRules(_ rules: [AlertRule]) {
        lock.withLock { _rules = rules }
    }

    func addRule(_ rule: AlertRule) {
        lock.withLock { _rules.append(rule) }
    }

    func removeRule(id: UUID) {
        lock.withLock { _rules.removeAll { $0.id == id } }
    }

    func updateRule(_ updated: AlertRule) {
        lock.withLock {
            if let idx = _rules.firstIndex(where: { $0.id == updated.id }) {
                _rules[idx] = updated
            }
        }
    }

    // MARK: - Event Handling

    private func handleRawEvent(_ data: Data) {
        guard let notification = try? JSONDecoder().decode(JSONRPCNotification.self, from: data),
              let event = NamuEvent(rawValue: notification.method) else { return }

        let params = notification.params?.object ?? [:]
        let currentRules = lock.withLock { _rules }

        for rule in currentRules where rule.isEnabled {
            if matches(rule: rule, event: event, params: params) {
                let fired = FiredAlert(rule: rule, event: event, params: params, firedAt: Date())
                notifyDelegate(fired)
            }
        }
    }

    private func matches(rule: AlertRule, event: NamuEvent, params: [String: JSONRPCValue]) -> Bool {
        switch rule.trigger {
        case .processExit(let expectedCode):
            guard event == .processExit else { return false }
            if let expected = expectedCode {
                if case .int(let actual) = params["exit_code"] {
                    return actual == expected
                }
                return false
            }
            return true

        case .outputMatch(let pattern, let caseSensitive):
            guard event == .outputMatch else { return false }
            guard case .string(let output) = params["text"] else { return false }
            if caseSensitive {
                return output.contains(pattern)
            } else {
                return output.lowercased().contains(pattern.lowercased())
            }

        case .portChange(let watchedPorts):
            guard event == .portChange else { return false }
            guard case .int(let port) = params["port"] else { return false }
            return watchedPorts.contains(port)

        case .shellIdle(let threshold):
            guard event == .shellIdle else { return false }
            guard case .double(let idleSeconds) = params["idle_seconds"] else { return false }
            return idleSeconds >= threshold
        }
    }

    private func notifyDelegate(_ alert: FiredAlert) {
        let router = lock.withLock { _alertRouter }
        Task { @MainActor in
            self.delegate?.alertEngine(self, didFire: alert)
        }
        if let router {
            Task {
                let payload = AlertPayload(
                    ruleName: alert.rule.name,
                    event: alert.event.rawValue,
                    summary: alert.summary,
                    workspaceTitle: alert.workspaceTitle ?? "",
                    timestamp: alert.firedAt
                )
                await router.route(payload)
            }
        }
    }
}

// MARK: - Persistence

extension AlertEngine {
    private static let userDefaultsKey = "namu.alertRules"

    func loadRules() {
        guard let data = UserDefaults.standard.data(forKey: Self.userDefaultsKey),
              let decoded = try? JSONDecoder().decode([AlertRule].self, from: data) else { return }
        setRules(decoded)
    }

    func saveRules() {
        let current = rules
        if let data = try? JSONEncoder().encode(current) {
            UserDefaults.standard.set(data, forKey: Self.userDefaultsKey)
        }
    }
}

// MARK: - Default Rules

extension AlertEngine {
    /// A sensible starter set of rules.
    static var defaultRules: [AlertRule] {
        [
            AlertRule(
                name: "Non-zero exit",
                trigger: .processExit(exitCode: nil)
            ),
            AlertRule(
                name: "Error in output",
                trigger: .outputMatch(pattern: "error", caseSensitive: false)
            ),
            AlertRule(
                name: "Port 3000 change",
                trigger: .portChange(ports: [3000, 8080])
            ),
            AlertRule(
                name: "Shell idle 5 min",
                trigger: .shellIdle(seconds: 300)
            )
        ]
    }
}