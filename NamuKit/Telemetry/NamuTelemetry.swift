import Foundation

// MARK: - NamuTelemetry

/// Lightweight OpenTelemetry-compatible metrics and logging layer.
///
/// Collects counters, histograms, and gauges using OTel semantic conventions,
/// then periodically exports them via OTLP HTTP JSON to any OTel collector
/// (including Sentry's direct OTLP endpoint).
///
/// **Zero external dependencies** — uses only Foundation.
///
/// Configure via environment or code:
///   NAMU_OTEL_ENDPOINT=http://localhost:4318           (generic OTel collector)
///   NAMU_SENTRY_DSN=https://key@o123.ingest.sentry.io/456  (Sentry OTLP)
///
/// Metrics are exported to `{endpoint}/v1/metrics` every 60 seconds.
/// Logs are exported to `{endpoint}/v1/logs` on flush.
final class NamuTelemetry: @unchecked Sendable {

    static let shared = NamuTelemetry()

    // MARK: - Configuration

    /// One or more OTLP export targets.
    private struct ExportTarget {
        let baseURL: URL
        let headers: [String: String]
    }

    /// Export interval in seconds.
    private let exportInterval: TimeInterval = 60

    /// Resource attributes attached to all exported telemetry.
    private let resource: [String: String] = [
        "service.name": "namu",
        "service.version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev",
        "telemetry.sdk.name": "namu-otel",
        "telemetry.sdk.language": "swift",
    ]

    // MARK: - State

    private let lock = NSLock()
    private var targets: [ExportTarget] = []
    private var counters: [String: CounterState] = [:]
    private var histograms: [String: HistogramState] = [:]
    private var gauges: [String: GaugeState] = [:]
    private var logs: [LogRecord] = []
    private var exportTimer: Timer?
    private var isEnabled = false

    // MARK: - Init

    private init() {
        // Auto-configure from environment
        if let env = ProcessInfo.processInfo.environment["NAMU_OTEL_ENDPOINT"],
           let url = URL(string: env) {
            addTarget(endpoint: url)
        }
        if let env = ProcessInfo.processInfo.environment["NAMU_SENTRY_DSN"] {
            configureSentry(dsn: env)
        }
        // Fall back to UserDefaults
        if targets.isEmpty {
            if let stored = UserDefaults.standard.string(forKey: "namu.otel.endpoint"),
               let url = URL(string: stored) {
                addTarget(endpoint: url)
            }
            if let stored = UserDefaults.standard.string(forKey: "namu.sentry.dsn") {
                configureSentry(dsn: stored)
            }
        }
    }

    // MARK: - Configuration API

    /// Add a generic OTLP endpoint (e.g., http://localhost:4318).
    func addTarget(endpoint: URL, headers: [String: String] = [:]) {
        lock.withLock {
            targets.append(ExportTarget(baseURL: endpoint, headers: headers))
            isEnabled = true
        }
        startExportTimer()
    }

    /// Configure Sentry via DSN. Derives the OTLP endpoint and auth header automatically.
    ///
    /// DSN format: `https://<public_key>@<host>/<project_id>`
    /// Produces endpoint: `https://<host>/api/<project_id>/otlp/`
    /// Auth header: `x-sentry-auth: sentry sentry_key=<public_key>`
    ///
    /// See: https://docs.sentry.io/concepts/otlp/direct/
    @discardableResult
    func configureSentry(dsn: String) -> Bool {
        guard let url = URL(string: dsn),
              let key = url.user, !key.isEmpty,
              let host = url.host, !host.isEmpty else { return false }
        let projectID = url.lastPathComponent.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !projectID.isEmpty else { return false }

        let scheme = url.scheme ?? "https"
        guard let baseURL = URL(string: "\(scheme)://\(host)/api/\(projectID)/otlp/") else { return false }

        lock.withLock {
            targets.append(ExportTarget(
                baseURL: baseURL,
                headers: ["x-sentry-auth": "sentry sentry_key=\(key)"]
            ))
            isEnabled = true
        }
        startExportTimer()
        return true
    }

    /// Disable telemetry and stop exporting.
    func disable() {
        lock.withLock {
            isEnabled = false
            targets.removeAll()
        }
        exportTimer?.invalidate()
        exportTimer = nil
    }

    var enabled: Bool { lock.withLock { isEnabled } }

    // MARK: - Counter

    /// Increment a monotonic counter.
    func increment(_ name: String, by value: Int64 = 1, attributes: [String: String] = [:]) {
        guard enabled else { return }
        let key = metricKey(name, attributes)
        lock.withLock {
            if counters[key] == nil {
                counters[key] = CounterState(name: name, attributes: attributes, value: 0)
            }
            counters[key]!.value += value
        }
    }

    // MARK: - Histogram

    /// Record a value in a histogram (latency, size, etc.).
    func record(_ name: String, value: Double, unit: String = "ms", attributes: [String: String] = [:]) {
        guard enabled else { return }
        let key = metricKey(name, attributes)
        lock.withLock {
            if histograms[key] == nil {
                histograms[key] = HistogramState(name: name, unit: unit, attributes: attributes)
            }
            histograms[key]!.record(value)
        }
    }

    // MARK: - Gauge

    /// Set a gauge to a specific value.
    func gauge(_ name: String, value: Double, unit: String = "", attributes: [String: String] = [:]) {
        guard enabled else { return }
        let key = metricKey(name, attributes)
        lock.withLock {
            if gauges[key] == nil {
                gauges[key] = GaugeState(name: name, unit: unit, attributes: attributes, value: 0)
            }
            gauges[key]!.value = value
        }
    }

    // MARK: - Logging

    /// Emit a structured log record.
    func log(_ body: String, severity: LogSeverity = .info, attributes: [String: String] = [:]) {
        guard enabled else { return }
        let record = LogRecord(
            timeUnixNano: UInt64(Date().timeIntervalSince1970 * 1_000_000_000),
            severityNumber: severity.rawValue,
            severityText: severity.text,
            body: body,
            attributes: attributes
        )
        lock.withLock { logs.append(record) }
    }

    // MARK: - Export

    /// Flush all pending metrics and logs to all configured targets.
    func flush() {
        let currentTargets = lock.withLock { targets }
        guard !currentTargets.isEmpty else { return }

        let snapshot = lock.withLock { () -> (counters: [CounterState], histograms: [HistogramState], gauges: [GaugeState], logs: [LogRecord]) in
            let c = Array(counters.values)
            let h = Array(histograms.values)
            let g = Array(gauges.values)
            let l = logs
            for key in histograms.keys { histograms[key]?.reset() }
            logs.removeAll()
            return (c, h, g, l)
        }

        let hasMetrics = !snapshot.counters.isEmpty || !snapshot.histograms.isEmpty || !snapshot.gauges.isEmpty

        // Build payloads once, send to all targets
        var metricsData: Data?
        var logsData: Data?

        if hasMetrics {
            let payload = buildMetricsPayload(counters: snapshot.counters, histograms: snapshot.histograms, gauges: snapshot.gauges)
            metricsData = try? JSONSerialization.data(withJSONObject: payload)
        }
        if !snapshot.logs.isEmpty {
            let payload = buildLogsPayload(logs: snapshot.logs)
            logsData = try? JSONSerialization.data(withJSONObject: payload)
        }

        for target in currentTargets {
            if let data = metricsData {
                post(to: target.baseURL.appendingPathComponent("v1/metrics"), body: data, headers: target.headers)
            }
            if let data = logsData {
                post(to: target.baseURL.appendingPathComponent("v1/logs"), body: data, headers: target.headers)
            }
        }
    }

    // MARK: - Private: Timer

    private func startExportTimer() {
        DispatchQueue.main.async { [weak self] in
            self?.exportTimer?.invalidate()
            self?.exportTimer = Timer.scheduledTimer(withTimeInterval: self?.exportInterval ?? 60, repeats: true) { [weak self] _ in
                DispatchQueue.global(qos: .utility).async { self?.flush() }
            }
        }
    }

    // MARK: - Private: Key

    private func metricKey(_ name: String, _ attrs: [String: String]) -> String {
        if attrs.isEmpty { return name }
        let sorted = attrs.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ",")
        return "\(name){\(sorted)}"
    }

    // MARK: - Private: OTLP JSON Payload Builders

    private func buildMetricsPayload(counters: [CounterState], histograms: [HistogramState], gauges: [GaugeState]) -> [String: Any] {
        var metrics: [[String: Any]] = []
        let nowNano = String(UInt64(Date().timeIntervalSince1970 * 1_000_000_000))

        for c in counters {
            metrics.append([
                "name": c.name,
                "sum": [
                    "dataPoints": [[
                        "asInt": String(c.value),
                        "attributes": c.attributes.map { ["key": $0.key, "value": ["stringValue": $0.value]] },
                        "timeUnixNano": nowNano,
                    ]],
                    "aggregationTemporality": 2,
                    "isMonotonic": true,
                ] as [String: Any],
            ])
        }

        for h in histograms {
            metrics.append([
                "name": h.name,
                "unit": h.unit,
                "histogram": [
                    "dataPoints": [[
                        "count": String(h.count),
                        "sum": h.sum.finiteOrZero,
                        "min": h.min.finiteOrZero,
                        "max": h.max.finiteOrZero,
                        "attributes": h.attributes.map { ["key": $0.key, "value": ["stringValue": $0.value]] },
                        "timeUnixNano": nowNano,
                    ]],
                    "aggregationTemporality": 2,
                ] as [String: Any],
            ])
        }

        for g in gauges {
            metrics.append([
                "name": g.name,
                "unit": g.unit,
                "gauge": [
                    "dataPoints": [[
                        "asDouble": g.value.finiteOrZero,
                        "attributes": g.attributes.map { ["key": $0.key, "value": ["stringValue": $0.value]] },
                        "timeUnixNano": nowNano,
                    ]],
                ] as [String: Any],
            ])
        }

        return [
            "resourceMetrics": [[
                "resource": ["attributes": resource.map { ["key": $0.key, "value": ["stringValue": $0.value]] }],
                "scopeMetrics": [[
                    "scope": ["name": "namu", "version": resource["service.version"] ?? "dev"],
                    "metrics": metrics,
                ]],
            ]],
        ]
    }

    private func buildLogsPayload(logs: [LogRecord]) -> [String: Any] {
        let logRecords: [[String: Any]] = logs.map { record in
            [
                "timeUnixNano": String(record.timeUnixNano),
                "severityNumber": record.severityNumber,
                "severityText": record.severityText,
                "body": ["stringValue": record.body],
                "attributes": record.attributes.map { ["key": $0.key, "value": ["stringValue": $0.value]] },
            ]
        }

        return [
            "resourceLogs": [[
                "resource": ["attributes": resource.map { ["key": $0.key, "value": ["stringValue": $0.value]] }],
                "scopeLogs": [[
                    "scope": ["name": "namu"],
                    "logRecords": logRecords,
                ]],
            ]],
        ]
    }

    // MARK: - Private: HTTP

    private func post(to url: URL, body: Data, headers: [String: String] = [:]) {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        request.httpBody = body
        request.timeoutInterval = 10
        URLSession.shared.dataTask(with: request) { _, _, _ in }.resume()
    }
}

// MARK: - Internal State Types

private struct CounterState {
    let name: String
    let attributes: [String: String]
    var value: Int64
}

private struct HistogramState {
    let name: String
    let unit: String
    let attributes: [String: String]
    var count: Int64 = 0
    var sum: Double = 0
    var min: Double = .infinity
    var max: Double = -.infinity

    mutating func record(_ value: Double) {
        count += 1
        sum += value
        if value < min { min = value }
        if value > max { max = value }
    }

    mutating func reset() {
        count = 0
        sum = 0
        min = .infinity
        max = -.infinity
    }
}

private struct GaugeState {
    let name: String
    let unit: String
    let attributes: [String: String]
    var value: Double
}

private struct LogRecord {
    let timeUnixNano: UInt64
    let severityNumber: Int
    let severityText: String
    let body: String
    let attributes: [String: String]
}

// MARK: - JSON-safe Double

private extension Double {
    /// Returns 0 for infinite/NaN values to prevent JSON serialization crashes.
    var finiteOrZero: Double { isFinite ? self : 0 }
}

// MARK: - Log Severity

enum LogSeverity: Int {
    case trace = 1
    case debug = 5
    case info = 9
    case warn = 13
    case error = 17
    case fatal = 21

    var text: String {
        switch self {
        case .trace: return "TRACE"
        case .debug: return "DEBUG"
        case .info: return "INFO"
        case .warn: return "WARN"
        case .error: return "ERROR"
        case .fatal: return "FATAL"
        }
    }
}
