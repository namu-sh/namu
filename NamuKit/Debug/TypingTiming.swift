import AppKit
import QuartzCore
import OSLog

/// Keystroke latency profiling — always compiled but gated on env var.
///
/// Enable by setting NAMU_TYPING_TIMING_LOGS=1 in the environment.
/// All methods are no-ops when the env var is absent or zero.
///
/// Threshold filtering: event delays < 5ms and phase durations < 2ms are
/// suppressed to avoid log spam during normal operation.
///
/// Usage:
///   TypingTiming.start(event: event)
///   TypingTiming.logEventDelay(event: event)
///   TypingTiming.logDuration(label: "ghostty_send", startTime: t0)
///   TypingTiming.logBreakdown(phases: [("queue", d0), ("send", d1)])
enum TypingTiming {

    private static let logger = Logger(subsystem: "com.namu.app", category: "TypingTiming")

    /// Minimum event queue delay (seconds) to log. Delays below this are suppressed.
    private static let delayThreshold: Double = 0.005   // 5ms

    /// Minimum phase duration (seconds) to log. Durations below this are suppressed.
    private static let durationThreshold: Double = 0.002 // 2ms

    /// Returns true when NAMU_TYPING_TIMING_LOGS=1 is set in the environment,
    /// OR when the UserDefaults key `namuTypingTimingLogs` is true.
    @inline(__always)
    static var isEnabled: Bool {
        ProcessInfo.processInfo.environment["NAMU_TYPING_TIMING_LOGS"] == "1"
            || UserDefaults.standard.bool(forKey: "namuTypingTimingLogs")
    }

    /// Returns true when NAMU_KEY_LATENCY_PROBE=1 is set.
    /// Probe mode logs every keystroke regardless of threshold.
    @inline(__always)
    static var isProbeMode: Bool {
        ProcessInfo.processInfo.environment["NAMU_KEY_LATENCY_PROBE"] == "1"
    }

    // MARK: - Per-event start timestamp

    /// Record the wall-clock arrival time of an event (call at the top of
    /// performKeyEquivalent / keyDown before any other work).
    /// Stores `event.timestamp` as a reference; no per-call allocation.
    /// In probe mode, logs every keystroke regardless of threshold.
    @inline(__always)
    static func start(event: NSEvent) {
        guard isEnabled || isProbeMode else { return }
        logger.debug("[TypingTiming] event_start keyCode=\(event.keyCode) ts=\(event.timestamp, format: .fixed(precision: 6))")
    }

    /// Log the elapsed time from event generation to now (event queue latency).
    /// Call immediately after receiving the event to measure queue delay.
    /// Only logs when delay exceeds the 5ms threshold, unless probe mode is active.
    @inline(__always)
    static func logEventDelay(event: NSEvent) {
        guard isEnabled || isProbeMode else { return }
        let now = CACurrentMediaTime()
        let delay = now - event.timestamp
        guard isProbeMode || delay > delayThreshold else { return }
        logger.debug("[TypingTiming] event_delay keyCode=\(event.keyCode) delay=\(String(format: "%.3f", delay * 1000.0))ms")
    }

    /// Log the duration of a named phase.
    /// Only logs when duration exceeds the 2ms threshold, unless probe mode is active.
    ///
    /// - Parameters:
    ///   - label: Human-readable phase name (e.g. "ghostty_send", "ime_flush").
    ///   - startTime: `CACurrentMediaTime()` captured at the start of the phase.
    @inline(__always)
    static func logDuration(label: String, startTime: CFTimeInterval) {
        guard isEnabled || isProbeMode else { return }
        let duration = CACurrentMediaTime() - startTime
        guard isProbeMode || duration > durationThreshold else { return }
        logger.debug("[TypingTiming] phase=\(label) duration=\(String(format: "%.3f", duration * 1000.0))ms")
    }

    /// Log a breakdown of multiple named sub-timings in a single log line.
    /// Always logs when enabled or in probe mode (caller is responsible for deciding relevance).
    ///
    /// - Parameter phases: Array of (name, duration-in-seconds) tuples.
    @inline(__always)
    static func logBreakdown(phases: [(String, Double)]) {
        guard isEnabled || isProbeMode else { return }
        let parts = phases.map { name, seconds in
            "\(name)=\(String(format: "%.3f", seconds * 1000.0))ms"
        }.joined(separator: " ")
        logger.debug("[TypingTiming] breakdown \(parts)")
    }

    /// Mark entry into a named section (e.g. "modifier_translation", "preedit").
    /// Returns CACurrentMediaTime() for use as startTime in the matching logExit call.
    /// Logs in probe mode regardless of threshold.
    @inline(__always)
    @discardableResult
    static func logEntry(label: String) -> CFTimeInterval {
        let t = CACurrentMediaTime()
        guard isEnabled || isProbeMode else { return t }
        logger.debug("[TypingTiming] enter \(label)")
        return t
    }

    /// Mark exit from a named section and log the duration if above threshold.
    /// In probe mode, logs every exit regardless of duration.
    @inline(__always)
    static func logExit(label: String, startTime: CFTimeInterval) {
        guard isEnabled || isProbeMode else { return }
        let duration = CACurrentMediaTime() - startTime
        guard isProbeMode || duration > durationThreshold else { return }
        logger.debug("[TypingTiming] exit \(label) duration=\(String(format: "%.3f", duration * 1000.0))ms")
    }

    /// Log a mouse event handler entry with event type.
    /// Logs in probe mode regardless of threshold.
    @inline(__always)
    static func logMouseEntry(handler: String) {
        guard isEnabled || isProbeMode else { return }
        logger.debug("[TypingTiming] mouse_enter handler=\(handler)")
    }

    /// Log a mouse event handler exit with duration.
    /// In probe mode, logs every exit regardless of duration.
    @inline(__always)
    static func logMouseExit(handler: String, startTime: CFTimeInterval) {
        guard isEnabled || isProbeMode else { return }
        let duration = CACurrentMediaTime() - startTime
        guard isProbeMode || duration > durationThreshold else { return }
        logger.debug("[TypingTiming] mouse_exit handler=\(handler) duration=\(String(format: "%.3f", duration * 1000.0))ms")
    }
}
