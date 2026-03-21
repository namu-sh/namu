import Foundation
import Combine

/// Batched port scanner using lsof-based detection.
///
/// Each terminal panel registers its TTY and calls `kick()` when a port scan
/// is warranted (e.g. after a command finishes). PortScanner coalesces kicks
/// across all panels with a 200ms window, then runs a burst of 6 scans at
/// increasing intervals to catch servers that start slowly.
///
/// Kick → coalesce → burst flow:
/// 1. `kick()` adds the panel to `pendingKicks`
/// 2. If no burst is active, starts a 200ms coalesce timer
/// 3. Coalesce fires → starts burst of 6 scans
/// 4. New kicks during burst merge into the active burst
/// 5. After the last scan, if new kicks arrived, start a new coalesce cycle
public final class PortScanner: ObservableObject {

    public static let shared = PortScanner()

    // MARK: - Published state

    /// Most recent port lists keyed by panel ID. Updated on the main thread.
    @Published public private(set) var portsByPanel: [UUID: [Int]] = [:]

    // MARK: - Callback

    /// Alternative callback for consumers that prefer delegation over Combine.
    /// Delivered on the main thread: (panelId, ports).
    public var onPortsUpdated: ((_ panelId: UUID, _ ports: [Int]) -> Void)?

    // MARK: - Private state (all guarded by `queue`)

    private let queue = DispatchQueue(label: "com.mosaic.port-scanner", qos: .utility)

    /// TTY name per panel ID.
    private var ttyNames: [UUID: String] = [:]

    /// Panels that have requested a scan since the last coalesce snapshot.
    private var pendingKicks: Set<UUID> = []

    /// Whether a burst sequence is currently running.
    private var burstActive = false

    /// Coalesce timer (200ms after first kick).
    private var coalesceTimer: DispatchSourceTimer?

    /// Burst scan offsets in seconds from the start of the burst.
    private static let burstOffsets: [Double] = [0.5, 1.5, 3.0, 5.0, 7.5, 10.0]

    // MARK: - Init

    public init() {}

    // MARK: - Public API

    /// Register a terminal panel's TTY so the scanner can correlate processes to panels.
    public func registerTTY(panelId: UUID, ttyName: String) {
        queue.async { [weak self] in
            guard let self else { return }
            guard ttyNames[panelId] != ttyName else { return }
            ttyNames[panelId] = ttyName
        }
    }

    /// Remove a panel from tracking. Clears its port list.
    public func unregisterPanel(panelId: UUID) {
        queue.async { [weak self] in
            guard let self else { return }
            ttyNames.removeValue(forKey: panelId)
            pendingKicks.remove(panelId)
        }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            portsByPanel.removeValue(forKey: panelId)
        }
    }

    /// Trigger a port scan for the given panel.
    /// Safe to call from any thread.
    public func kick(panelId: UUID) {
        queue.async { [weak self] in
            guard let self else { return }
            guard ttyNames[panelId] != nil else { return }
            pendingKicks.insert(panelId)
            if !burstActive {
                startCoalesce()
            }
            // If a burst is active the next scan iteration picks up the new kick.
        }
    }

    // MARK: - Coalesce + burst

    private func startCoalesce() {
        // Already on `queue`.
        coalesceTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 0.2)
        timer.setEventHandler { [weak self] in
            self?.coalesceTimerFired()
        }
        coalesceTimer = timer
        timer.resume()
    }

    private func coalesceTimerFired() {
        // Already on `queue`.
        coalesceTimer?.cancel()
        coalesceTimer = nil
        guard !pendingKicks.isEmpty else { return }
        burstActive = true
        runBurst(index: 0)
    }

    private func runBurst(index: Int, burstStart: DispatchTime? = nil) {
        // Already on `queue`.
        guard index < Self.burstOffsets.count else {
            burstActive = false
            if !pendingKicks.isEmpty {
                startCoalesce()
            }
            return
        }

        let start = burstStart ?? .now()
        let deadline = start + Self.burstOffsets[index]
        queue.asyncAfter(deadline: deadline) { [weak self] in
            guard let self else { return }
            self.runScan()
            self.runBurst(index: index + 1, burstStart: start)
        }
    }

    // MARK: - Scan

    private func runScan() {
        // Already on `queue`. Scan all registered panels (ports can change on any panel).
        let snapshot = ttyNames
        guard !snapshot.isEmpty else {
            pendingKicks.removeAll()
            return
        }
        pendingKicks.removeAll()

        let uniqueTTYs = Set(snapshot.values)
        let ttyList = uniqueTTYs.joined(separator: ",")

        // Step 1: find PIDs on the tracked TTYs.
        let pidToTTY = runPS(ttyList: ttyList)
        guard !pidToTTY.isEmpty else {
            let results = snapshot.map { ($0.key, [Int]()) }
            deliverResults(results)
            return
        }

        // Step 2: find LISTEN ports for those PIDs.
        let allPids = pidToTTY.keys.sorted().map(String.init).joined(separator: ",")
        let pidToPorts = runLsof(pidsCsv: allPids)

        // Step 3: join PID→TTY + PID→ports → TTY→ports.
        var portsByTTY: [String: Set<Int>] = [:]
        for (pid, ports) in pidToPorts {
            guard let tty = pidToTTY[pid] else { continue }
            portsByTTY[tty, default: []].formUnion(ports)
        }

        // Step 4: map to per-panel lists.
        var results: [(UUID, [Int])] = []
        for (panelId, tty) in snapshot {
            let ports = portsByTTY[tty].map { Array($0).sorted() } ?? []
            results.append((panelId, ports))
        }

        deliverResults(results)
    }

    private func deliverResults(_ results: [(UUID, [Int])]) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            for (panelId, ports) in results {
                portsByPanel[panelId] = ports
                onPortsUpdated?(panelId, ports)
            }
        }
    }

    // MARK: - Process helpers

    private func runPS(ttyList: String) -> [Int: String] {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-t", ttyList, "-o", "pid=,tty="]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do { try process.run() } catch { return [:] }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard let output = String(data: data, encoding: .utf8) else { return [:] }

        var mapping: [Int: String] = [:]
        for line in output.split(separator: "\n") {
            let parts = line.split(whereSeparator: \.isWhitespace)
            guard parts.count >= 2, let pid = Int(parts[0]) else { continue }
            mapping[pid] = String(parts[1])
        }
        return mapping
    }

    private func runLsof(pidsCsv: String) -> [Int: Set<Int>] {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        process.arguments = ["-nP", "-a", "-p", pidsCsv, "-iTCP", "-sTCP:LISTEN", "-Fpn"]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do { try process.run() } catch { return [:] }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard let output = String(data: data, encoding: .utf8) else { return [:] }

        var result: [Int: Set<Int>] = [:]
        var currentPid: Int?
        for line in output.split(separator: "\n") {
            guard let first = line.first else { continue }
            switch first {
            case "p":
                currentPid = Int(line.dropFirst())
            case "n":
                guard let pid = currentPid else { continue }
                var name = String(line.dropFirst())
                if let arrowRange = name.range(of: "->") {
                    name = String(name[..<arrowRange.lowerBound])
                }
                if let colonIdx = name.lastIndex(of: ":") {
                    let portStr = name[name.index(after: colonIdx)...]
                    let cleaned = portStr.prefix(while: \.isNumber)
                    if let port = Int(cleaned), port > 0, port <= 65535 {
                        result[pid, default: []].insert(port)
                    }
                }
            default:
                break
            }
        }
        return result
    }
}
