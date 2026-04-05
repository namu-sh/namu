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

    /// Increment on accept() error with errno classification.
    static func socketAcceptError(errno: Int32) {
        t.increment("namu.socket.accept_errors", attributes: ["errno": String(errno)])
    }

    // MARK: - Browser

    /// Increment when a browser panel navigates.
    static func browserNavigation(typed: Bool) {
        t.increment("namu.browser.navigations", attributes: ["typed": String(typed)])
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

}
