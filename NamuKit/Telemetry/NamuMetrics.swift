import Foundation

// MARK: - NamuMetrics

/// Predefined metrics following OTel semantic conventions.
/// Call these from instrumented code paths — they no-op when telemetry is disabled.
enum NamuMetrics {

    private static var t: NamuTelemetry { .shared }

    // MARK: - IPC / Command Dispatch

    /// Increment when a JSON-RPC command is dispatched.
    static func ipcRequestReceived(method: String) {
        t.increment("namu.ipc.requests", attributes: ["method": method])
    }

    /// Record command dispatch latency in milliseconds.
    static func ipcRequestDuration(method: String, ms: Double) {
        t.record("namu.ipc.request.duration", value: ms, unit: "ms", attributes: ["method": method])
    }

    /// Increment on dispatch error.
    static func ipcRequestError(method: String, code: Int) {
        t.increment("namu.ipc.errors", attributes: ["method": method, "code": String(code)])
    }

    // MARK: - Socket Server

    /// Gauge: current number of active client connections.
    static func socketActiveConnections(_ count: Int) {
        t.gauge("namu.socket.active_connections", value: Double(count), unit: "{connections}")
    }

    /// Increment on accept() error with errno classification.
    static func socketAcceptError(errno: Int32) {
        t.increment("namu.socket.accept_errors", attributes: ["errno": String(errno)])
    }

    /// Gauge: socket server health (1 = healthy, 0 = unhealthy).
    static func socketHealthy(_ healthy: Bool) {
        t.gauge("namu.socket.healthy", value: healthy ? 1 : 0)
    }

    // MARK: - Browser

    /// Increment when a browser panel navigates.
    static func browserNavigation(typed: Bool) {
        t.increment("namu.browser.navigations", attributes: ["typed": String(typed)])
    }

    /// Record browser automation command latency.
    static func browserAutomationDuration(command: String, ms: Double) {
        t.record("namu.browser.automation.duration", value: ms, unit: "ms", attributes: ["command": command])
    }

    /// Increment browser automation commands.
    static func browserAutomationRequest(command: String) {
        t.increment("namu.browser.automation.requests", attributes: ["command": command])
    }

    // MARK: - Notifications

    /// Gauge: current unread notification count.
    static func notificationUnreadCount(_ count: Int) {
        t.gauge("namu.notifications.unread", value: Double(count), unit: "{notifications}")
    }

    /// Increment when a notification is created.
    static func notificationCreated(source: String = "system") {
        t.increment("namu.notifications.created", attributes: ["source": source])
    }

    // MARK: - Workspaces

    /// Gauge: total workspace count.
    static func workspaceCount(_ count: Int) {
        t.gauge("namu.workspaces.count", value: Double(count), unit: "{workspaces}")
    }

    /// Increment workspace lifecycle events.
    static func workspaceEvent(_ event: String) {
        t.increment("namu.workspaces.events", attributes: ["event": event])
    }

    // MARK: - Session Persistence

    /// Record session save duration.
    static func sessionSaveDuration(ms: Double) {
        t.record("namu.session.save.duration", value: ms, unit: "ms")
    }

    /// Record session restore duration.
    static func sessionRestoreDuration(ms: Double) {
        t.record("namu.session.restore.duration", value: ms, unit: "ms")
    }

    // MARK: - System

    /// Gauge: resident memory in bytes.
    static func memoryResident(bytes: UInt64) {
        t.gauge("namu.system.memory.resident", value: Double(bytes), unit: "By")
    }

    /// Gauge: app uptime in seconds.
    static func uptime(seconds: Double) {
        t.gauge("namu.system.uptime", value: seconds, unit: "s")
    }

    // MARK: - AI

    /// Increment NamuAI command executions.
    static func aiCommandExecuted(provider: String, safe: Bool) {
        t.increment("namu.ai.commands", attributes: ["provider": provider, "safe": String(safe)])
    }

    /// Record NamuAI response latency.
    static func aiResponseDuration(provider: String, ms: Double) {
        t.record("namu.ai.response.duration", value: ms, unit: "ms", attributes: ["provider": provider])
    }

    // MARK: - Alerts

    /// Increment when an alert fires.
    static func alertFired(trigger: String, channel: String) {
        t.increment("namu.alerts.fired", attributes: ["trigger": trigger, "channel": channel])
    }

    /// Increment alert delivery failures.
    static func alertDeliveryFailed(channel: String) {
        t.increment("namu.alerts.delivery_failures", attributes: ["channel": channel])
    }

    // MARK: - SSH / Remote

    /// Increment SSH session events.
    static func sshEvent(_ event: String) {
        t.increment("namu.ssh.events", attributes: ["event": event])
    }

    /// Record SSH reconnection attempts.
    static func sshReconnectAttempt(host: String) {
        t.increment("namu.ssh.reconnect_attempts", attributes: ["host": host])
    }
}
