import Foundation
#if DEBUG
import QuartzCore
#endif

enum NamuDebug {
    private static let logFile = "/tmp/namu-trace.log"

    static func log(_ message: String) {
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
        if let data = line.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: logFile) {
                if let handle = FileHandle(forWritingAtPath: logFile) {
                    handle.seekToEndOfFile()
                    handle.write(data)
                    handle.closeFile()
                }
            } else {
                FileManager.default.createFile(atPath: logFile, contents: data)
            }
        }
    }

#if DEBUG
    // MARK: - Frame timing (debug builds only)

    private static var frameTimings: [CFTimeInterval] = []
    private static var lastFrameTime: CFTimeInterval = 0
    private static let timingsLock = NSLock()

    /// Record the start of a frame render. Call at the beginning of each frame.
    static func recordFrameStart() {
        let now = CACurrentMediaTime()
        timingsLock.lock()
        defer { timingsLock.unlock() }
        lastFrameTime = now
    }

    /// Record the end of a frame render. Call at the end of each frame.
    static func recordFrameEnd() {
        let now = CACurrentMediaTime()
        timingsLock.lock()
        defer { timingsLock.unlock() }
        guard lastFrameTime > 0 else { return }
        let duration = now - lastFrameTime
        frameTimings.append(duration)
        if frameTimings.count > 120 { frameTimings.removeFirst() }
        lastFrameTime = 0
    }

    /// Returns average, min, max frame times (seconds) over the last ~120 frames.
    static func frameStats() -> (avg: Double, min: Double, max: Double, count: Int) {
        timingsLock.lock()
        defer { timingsLock.unlock() }
        guard !frameTimings.isEmpty else { return (0, 0, 0, 0) }
        let sum = frameTimings.reduce(0, +)
        let mn = frameTimings.min() ?? 0
        let mx = frameTimings.max() ?? 0
        return (sum / Double(frameTimings.count), mn, mx, frameTimings.count)
    }

    // MARK: - Memory tracking (debug builds only)

    /// Returns current resident memory usage in bytes, or nil if unavailable.
    static func residentMemoryBytes() -> Int? {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return Int(info.resident_size)
    }

    /// Returns memory usage as a human-readable string (e.g. "42.3 MB").
    static func memoryUsageString() -> String {
        guard let bytes = residentMemoryBytes() else { return "unknown" }
        let mb = Double(bytes) / 1_048_576
        return String(format: "%.1f MB", mb)
    }

    /// Logs a snapshot of frame stats and memory to the trace log.
    static func logPerfSnapshot(label: String = "") {
        let stats = frameStats()
        let mem = memoryUsageString()
        let tag = label.isEmpty ? "" : "[\(label)] "
        if stats.count > 0 {
            let avgMs = stats.avg * 1000
            let minMs = stats.min * 1000
            let maxMs = stats.max * 1000
            log("[NamuDebug] \(tag)frames=\(stats.count) avg=\(String(format: "%.2f", avgMs))ms min=\(String(format: "%.2f", minMs))ms max=\(String(format: "%.2f", maxMs))ms mem=\(mem)")
        } else {
            log("[NamuDebug] \(tag)no frame data mem=\(mem)")
        }
    }
#endif
}
