import Foundation

/// Batched port scanner that populates SidebarMetadata.listeningPorts.
///
/// Kick → coalesce → burst flow:
/// 1. `kick()` adds panel to `pendingKicks` set
/// 2. If no burst is active, starts a 200 ms coalesce timer
/// 3. Coalesce fires → snapshots pending set → starts burst of 6 scans
/// 4. New kicks during burst merge into the active burst
/// 5. After last scan, if new kicks arrived, start a new coalesce cycle
final class PortScanner: @unchecked Sendable {
    static let shared = PortScanner()

    /// Callback delivers `(workspaceID, panelID, ports)` on the main actor.
    /// Must be set before any kicks — read from `queue` during scan delivery.
    private var _onPortsUpdated: (@MainActor (_ workspaceID: UUID, _ panelID: UUID, _ ports: [PortInfo]) -> Void)?

    /// Thread-safe setter/getter for the callback.
    var onPortsUpdated: (@MainActor (_ workspaceID: UUID, _ panelID: UUID, _ ports: [PortInfo]) -> Void)? {
        get { queue.sync { _onPortsUpdated } }
        set { queue.sync { _onPortsUpdated = newValue } }
    }

    // MARK: - State (all guarded by `queue`)

    private let queue = DispatchQueue(label: "io.namu.port-scanner", qos: .utility)

    /// TTY name per (workspace, panel).
    private var ttyNames: [PanelKey: String] = [:]

    /// Panels that requested a scan since the last coalesce snapshot.
    private var pendingKicks: Set<PanelKey> = []

    /// Whether a burst sequence is currently running.
    private var burstActive = false

    /// Coalesce timer (200 ms after first kick).
    private var coalesceTimer: DispatchSourceTimer?

    /// Burst scan offsets in seconds from the start of the burst.
    private static let burstOffsets: [Double] = [0.5, 1.5, 3, 5, 7.5, 10]

    // MARK: - Key

    struct PanelKey: Hashable {
        let workspaceID: UUID
        let panelID: UUID
    }

    // MARK: - Public API

    func registerTTY(workspaceID: UUID, panelID: UUID, ttyName: String) {
        let key = PanelKey(workspaceID: workspaceID, panelID: panelID)
        queue.async { [self] in
            guard ttyNames[key] != ttyName else { return }
            ttyNames[key] = ttyName
        }
    }

    func kick(workspaceID: UUID, panelID: UUID) {
        let key = PanelKey(workspaceID: workspaceID, panelID: panelID)
        queue.async { [self] in
            guard ttyNames[key] != nil else { return }
            pendingKicks.insert(key)
            if !burstActive {
                startCoalesce()
            }
        }
    }

    func unregisterPanel(workspaceID: UUID, panelID: UUID) {
        let key = PanelKey(workspaceID: workspaceID, panelID: panelID)
        queue.async { [self] in
            ttyNames.removeValue(forKey: key)
            pendingKicks.remove(key)
        }
    }

    // MARK: - Coalesce + Burst

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
            runScan()
            runBurst(index: index + 1, burstStart: start)
        }
    }

    // MARK: - Scan

    private func runScan() {
        // Already on `queue`. Scan all registered panels.
        let snapshot = ttyNames
        guard !snapshot.isEmpty else {
            pendingKicks.removeAll()
            return
        }

        pendingKicks.removeAll()

        let uniqueTTYs = Set(snapshot.values)
        let ttyList = uniqueTTYs.joined(separator: ",")

        let pidToTTY = runPS(ttyList: ttyList)
        guard !pidToTTY.isEmpty else {
            let results = snapshot.map { ($0.key, [PortInfo]()) }
            deliverResults(results)
            return
        }

        let allPids = pidToTTY.keys.sorted().map(String.init).joined(separator: ",")
        let pidToPorts = runLsof(pidsCsv: allPids)

        // Join: PID→TTY + PID→ports → TTY→ports
        var portsByTTY: [String: Set<UInt16>] = [:]
        for (pid, ports) in pidToPorts {
            guard let tty = pidToTTY[pid] else { continue }
            portsByTTY[tty, default: []].formUnion(ports)
        }

        // Map to per-panel PortInfo lists.
        var results: [(PanelKey, [PortInfo])] = []
        for (key, tty) in snapshot {
            let ports = portsByTTY[tty].map { $0.sorted().map { PortInfo(port: $0) } } ?? []
            results.append((key, ports))
        }

        deliverResults(results)
    }

    private func deliverResults(_ results: [(PanelKey, [PortInfo])]) {
        guard let callback = _onPortsUpdated else { return }
        let captured = results
        Task { @MainActor in
            for (key, ports) in captured {
                callback(key.workspaceID, key.panelID, ports)
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

    private func runLsof(pidsCsv: String) -> [Int: Set<UInt16>] {
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

        var result: [Int: Set<UInt16>] = [:]
        var currentPid: Int?
        for line in output.split(separator: "\n") {
            guard let first = line.first else { continue }
            switch first {
            case "p":
                currentPid = Int(line.dropFirst())
            case "n":
                guard let pid = currentPid else { continue }
                var name = String(line.dropFirst())
                if let arrowIdx = name.range(of: "->") {
                    name = String(name[..<arrowIdx.lowerBound])
                }
                if let colonIdx = name.lastIndex(of: ":") {
                    let portStr = name[name.index(after: colonIdx)...]
                    let cleaned = portStr.prefix(while: \.isNumber)
                    if let port = UInt16(cleaned), port > 0 {
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
