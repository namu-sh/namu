import Foundation
import CryptoKit

// MARK: - Delegate

protocol RemoteSessionControllerDelegate: AnyObject {
    func remoteSession(_ controller: RemoteSessionController, didUpdateConnectionState state: RemoteConnectionState, detail: String?)
    func remoteSession(_ controller: RemoteSessionController, didUpdateDaemonStatus status: RemoteDaemonStatus)
    func remoteSession(_ controller: RemoteSessionController, didUpdateProxyEndpoint endpoint: RemoteProxyEndpoint?)
    func remoteSession(_ controller: RemoteSessionController, didUpdateHeartbeat count: Int, lastSeenAt: Date?)
    func remoteSession(_ controller: RemoteSessionController, didEncounterError message: String)
}

// MARK: - RemoteSessionController

/// Orchestrates the full lifecycle of a remote workspace session:
/// daemon bootstrap, binary provisioning, proxy setup, reverse relay, and reconnection.
final class RemoteSessionController {

    // MARK: - Private structs

    private struct CommandResult {
        let status: Int32
        let stdout: String
        let stderr: String
    }

    private struct RemotePlatform {
        let goOS: String
        let goArch: String
    }

    private struct RemoteBootstrapState {
        let platform: RemotePlatform
        let binaryExists: Bool
    }

    private struct DaemonHello {
        let name: String
        let version: String
        let capabilities: [String]
        let remotePath: String
    }

    // MARK: - Public properties

    let controllerID = UUID()
    let configuration: RemoteConfiguration
    weak var delegate: RemoteSessionControllerDelegate?

    // MARK: - Private properties

    private let queue: DispatchQueue
    private let queueKey = DispatchSpecificKey<Void>()

    // Daemon state
    private var daemonReady = false
    private var daemonRemotePath: String?
    private var daemonBootstrapVersion: String?

    // Proxy
    private var proxyLease: RemoteProxyBroker.Lease?
    private var proxyEndpoint: RemoteProxyEndpoint?

    // Reverse relay
    private var reverseRelayProcess: Process?
    private var reverseRelayStderrPipe: Pipe?
    private var reverseRelayStderrBuffer = ""
    private var reverseRelayRestartWorkItem: DispatchWorkItem?
    private var cliRelayServer: RemoteCLIRelayServer?

    // Reconnection
    private var isStopping = false
    private var reconnectWorkItem: DispatchWorkItem?
    private var connectionAttemptCount = 0
    private var connectionAttemptStartedAt: Date?

    // Heartbeat
    private var heartbeatCount = 0
    private var lastHeartbeatAt: Date?

    // Resize debounce
    private var pendingResizeWorkItem: DispatchWorkItem?
    private var pendingResizeSessionID: String?
    private var pendingResizeCols: Int = 0
    private var pendingResizeRows: Int = 0

    // Startup grace period before checking if the relay process has exited immediately
    private static let reverseRelayStartupGracePeriod: TimeInterval = 0.5

    // MARK: - Probe markers

    private static let remotePlatformProbeOSMarker = "__NAMU_REMOTE_OS__="
    private static let remotePlatformProbeArchMarker = "__NAMU_REMOTE_ARCH__="
    private static let remotePlatformProbeExistsMarker = "__NAMU_REMOTE_EXISTS__="

    // MARK: - Init

    init(configuration: RemoteConfiguration) {
        self.configuration = configuration
        self.queue = DispatchQueue(
            label: "com.namu.remote-ssh.session-controller.\(UUID().uuidString)",
            qos: .utility
        )
        queue.setSpecific(key: queueKey, value: ())
    }

    // MARK: - Lifecycle

    func start() {
        debugLog("remote.session.start \(debugConfigSummary())")
        queue.async { [weak self] in
            guard let self else { return }
            guard !self.isStopping else { return }
            self.beginConnectionAttemptLocked()
        }
    }

    func stop() {
        if DispatchQueue.getSpecific(key: queueKey) != nil {
            stopAllLocked()
            return
        }
        // Intentional strong capture: ensures teardown completes even if the
        // caller releases its reference to the controller before the queue drains.
        queue.async { [self] in
            stopAllLocked()
        }
    }

    // MARK: - PTY resize

    /// Forward a PTY resize to the remote daemon.
    /// Called from the service when a terminal panel resizes in a remote workspace.
    /// Debounced to at most one SSH round-trip per 100 ms to avoid flooding during window drag.
    func notifyResize(sessionID: String, cols: Int, rows: Int) {
        queue.async { [weak self] in
            guard let self, !self.isStopping else { return }
            self.pendingResizeSessionID = sessionID
            self.pendingResizeCols = cols
            self.pendingResizeRows = rows
            self.pendingResizeWorkItem?.cancel()
            let work = DispatchWorkItem { [weak self] in
                self?.flushResizeLocked()
            }
            self.pendingResizeWorkItem = work
            self.queue.asyncAfter(deadline: .now() + 0.1, execute: work)
        }
    }

    private func flushResizeLocked() {
        // NOTE: Each resize creates a short-lived SSH connection. This is debounced to 100ms
        // to limit frequency, but a long-lived RPC connection would be more efficient.
        // Future improvement: reuse the proxy broker's RPC client for resize calls.
        guard !isStopping, let sessionID = pendingResizeSessionID,
              daemonReady, let remotePath = daemonRemotePath else { return }
        pendingResizeSessionID = nil
        let cols = pendingResizeCols
        let rows = pendingResizeRows
        let rpcClient = RemoteDaemonRPCClient(
            configuration: configuration,
            remotePath: remotePath,
            onUnexpectedTermination: { _ in }
        )
        do {
            try rpcClient.start()
            try? rpcClient.sessionResize(sessionID: sessionID, cols: cols, rows: rows)
            rpcClient.stop()
        } catch {
            // Best-effort: resize failures are non-fatal.
        }
    }

    // MARK: - File upload

    /// Upload local files to the remote host via SCP.
    func uploadFiles(
        _ urls: [URL],
        operation: String,
        completion: @escaping (Result<Void, RemoteDropUploadError>) -> Void
    ) {
        queue.async { [weak self] in
            guard let self else {
                DispatchQueue.main.async {
                    completion(.failure(.unavailable))
                }
                return
            }
            do {
                try self.uploadFilesLocked(urls)
                DispatchQueue.main.async {
                    completion(.success(()))
                }
            } catch let error as RemoteDropUploadError {
                DispatchQueue.main.async {
                    completion(.failure(error))
                }
            } catch {
                DispatchQueue.main.async {
                    completion(.failure(.uploadFailed(error.localizedDescription)))
                }
            }
        }
    }

    // MARK: - Stop

    private func stopAllLocked() {
        debugLog("remote.session.stop \(debugConfigSummary())")
        isStopping = true
        reconnectWorkItem?.cancel()
        reconnectWorkItem = nil
        connectionAttemptCount = 0
        reverseRelayRestartWorkItem?.cancel()
        reverseRelayRestartWorkItem = nil
        // M4: Cancel any pending resize debounce work item.
        pendingResizeWorkItem?.cancel()
        pendingResizeWorkItem = nil
        stopReverseRelayLocked()

        proxyLease?.release()
        proxyLease = nil
        proxyEndpoint = nil
        daemonReady = false
        daemonBootstrapVersion = nil
        daemonRemotePath = nil
        publishProxyEndpoint(nil)
    }

    // MARK: - Connection attempt

    private func beginConnectionAttemptLocked() {
        guard !isStopping else { return }

        connectionAttemptStartedAt = Date()
        debugLog("remote.session.connect.begin attempt=\(connectionAttemptCount) \(debugConfigSummary())")
        reconnectWorkItem = nil

        let connectDetail: String
        let bootstrapDetail: String
        if connectionAttemptCount > 0 {
            connectDetail = "Reconnecting to \(configuration.displayTarget) (retry \(connectionAttemptCount))"
            bootstrapDetail = "Bootstrapping remote daemon on \(configuration.displayTarget) (retry \(connectionAttemptCount))"
        } else {
            connectDetail = "Connecting to \(configuration.displayTarget)"
            bootstrapDetail = "Bootstrapping remote daemon on \(configuration.displayTarget)"
        }

        publishState(.connecting, detail: connectDetail)
        publishDaemonStatus(RemoteDaemonStatus(state: .bootstrapping, detail: bootstrapDetail))

        do {
            let hello = try bootstrapDaemonLocked()
            guard hello.capabilities.contains(RemoteDaemonRPCClient.requiredProxyStreamCapability) else {
                throw NSError(domain: "namu.remote.session", code: 43, userInfo: [
                    NSLocalizedDescriptionKey: "remote daemon missing required capability \(RemoteDaemonRPCClient.requiredProxyStreamCapability)",
                ])
            }
            daemonReady = true
            daemonBootstrapVersion = hello.version
            daemonRemotePath = hello.remotePath
            publishDaemonStatus(RemoteDaemonStatus(
                state: .ready,
                detail: "Remote daemon ready",
                version: hello.version,
                name: hello.name,
                capabilities: hello.capabilities,
                remotePath: hello.remotePath
            ))
            recordHeartbeatActivityLocked()
            startReverseRelayLocked(remotePath: hello.remotePath)
            startProxyLocked()
        } catch {
            daemonReady = false
            daemonBootstrapVersion = nil
            daemonRemotePath = nil
            let nextRetry = scheduleReconnectLocked(delay: 4.0)
            let retrySuffix = Self.retrySuffix(retry: nextRetry, delay: 4.0)
            let detail = "Remote daemon bootstrap failed: \(error.localizedDescription)\(retrySuffix)"
            publishDaemonStatus(RemoteDaemonStatus(state: .error, detail: detail))
            publishState(.error, detail: detail)
        }
    }

    // MARK: - Proxy

    private func startProxyLocked() {
        guard !isStopping else { return }
        guard daemonReady else { return }
        guard proxyLease == nil else { return }
        guard let remotePath = daemonRemotePath,
              !remotePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            let nextRetry = scheduleReconnectLocked(delay: 4.0)
            let retrySuffix = Self.retrySuffix(retry: nextRetry, delay: 4.0)
            let detail = "Remote daemon did not provide a valid remote path\(retrySuffix)"
            publishDaemonStatus(RemoteDaemonStatus(state: .error, detail: detail))
            publishState(.error, detail: detail)
            return
        }

        let lease = RemoteProxyBroker.shared.acquire(
            configuration: configuration,
            remotePath: remotePath
        ) { [weak self] update in
            self?.queue.async {
                self?.handleProxyBrokerUpdateLocked(update)
            }
        }
        proxyLease = lease
    }

    private func handleProxyBrokerUpdateLocked(_ update: RemoteProxyBroker.Update) {
        guard !isStopping else { return }
        switch update {
        case .connecting:
            debugLog("remote.proxy.connecting \(debugConfigSummary())")
            if proxyEndpoint == nil {
                publishState(.connecting, detail: "Connecting to \(configuration.displayTarget)")
            }
        case .ready(let endpoint):
            debugLog("remote.proxy.ready host=\(endpoint.host) port=\(endpoint.port) \(debugConfigSummary())")
            reconnectWorkItem?.cancel()
            reconnectWorkItem = nil
            connectionAttemptCount = 0
            guard proxyEndpoint != endpoint else {
                recordHeartbeatActivityLocked()
                return
            }
            proxyEndpoint = endpoint
            publishProxyEndpoint(endpoint)
            publishState(
                .connected,
                detail: "Connected to \(configuration.displayTarget) via shared local proxy \(endpoint.host):\(endpoint.port)"
            )
            recordHeartbeatActivityLocked()
        case .error(let detail):
            debugLog("remote.proxy.error detail=\(detail) \(debugConfigSummary())")
            proxyEndpoint = nil
            publishProxyEndpoint(nil)
            publishState(.error, detail: "Remote proxy to \(configuration.displayTarget) unavailable: \(detail)")
            guard Self.shouldEscalateProxyErrorToBootstrap(detail) else { return }

            proxyLease?.release()
            proxyLease = nil
            daemonReady = false
            daemonBootstrapVersion = nil
            daemonRemotePath = nil

            let nextRetry = scheduleReconnectLocked(delay: 2.0)
            let retrySuffix = Self.retrySuffix(retry: nextRetry, delay: 2.0)
            publishDaemonStatus(RemoteDaemonStatus(
                state: .error,
                detail: "Remote daemon transport needs re-bootstrap after proxy failure\(retrySuffix)"
            ))
        }
    }

    // MARK: - Reverse relay

    private func startReverseRelayLocked(remotePath: String) {
        guard !isStopping else { return }
        guard daemonReady else { return }
        guard let relayPort = configuration.relayPort, relayPort > 0,
              let relayID = configuration.relayID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !relayID.isEmpty,
              let relayToken = configuration.relayToken?.trimmingCharacters(in: .whitespacesAndNewlines),
              !relayToken.isEmpty,
              let localSocketPath = configuration.localSocketPath?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !localSocketPath.isEmpty else {
            return
        }
        guard reverseRelayProcess == nil else { return }

        reverseRelayRestartWorkItem?.cancel()
        reverseRelayRestartWorkItem = nil

        var relayServer: RemoteCLIRelayServer?
        do {
            let server = try ensureCLIRelayServerLocked(
                localSocketPath: localSocketPath,
                relayID: relayID,
                relayToken: relayToken
            )
            relayServer = server
            let localRelayPort = try server.start()
            Self.killOrphanedRelayProcesses(relayPort: relayPort, destination: configuration.destination)

            let process = Process()
            let stderrPipe = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            process.arguments = reverseRelayArguments(relayPort: relayPort, localRelayPort: localRelayPort)
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice
            process.standardError = stderrPipe

            process.terminationHandler = { [weak self] terminated in
                self?.queue.async {
                    self?.handleReverseRelayTerminationLocked(process: terminated)
                }
            }

            try process.run()

            if let startupFailure = Self.reverseRelayStartupFailureDetail(
                process: process,
                stderrPipe: stderrPipe
            ) {
                let retryDelay = 2.0
                let retrySeconds = max(1, Int(retryDelay.rounded()))
                debugLog(
                    "remote.relay.startFailed relayPort=\(relayPort) " +
                    "error=\(startupFailure)"
                )
                relayServer?.stop()
                publishDaemonStatus(RemoteDaemonStatus(
                    state: .error,
                    detail: "Remote SSH relay unavailable: \(startupFailure) (retry in \(retrySeconds)s)"
                ))
                scheduleReverseRelayRestartLocked(remotePath: remotePath, delay: retryDelay)
                return
            }

            installReverseRelayStderrHandlerLocked(stderrPipe)
            reverseRelayProcess = process
            cliRelayServer = relayServer
            reverseRelayStderrPipe = stderrPipe
            reverseRelayStderrBuffer = ""

            do {
                try installRemoteRelayMetadataLocked(
                    remotePath: remotePath,
                    relayPort: relayPort,
                    relayID: server.relayID,
                    relayToken: server.relayToken
                )
            } catch {
                debugLog("remote.relay.metadata.error \(error.localizedDescription)")
                stopReverseRelayLocked()
                scheduleReverseRelayRestartLocked(remotePath: remotePath, delay: 2.0)
                return
            }

            recordHeartbeatActivityLocked()
            debugLog(
                "remote.relay.start relayPort=\(relayPort) localRelayPort=\(localRelayPort) " +
                "target=\(configuration.displayTarget)"
            )
        } catch {
            debugLog(
                "remote.relay.startFailed relayPort=\(configuration.relayPort.map(String.init) ?? "nil") " +
                "error=\(error.localizedDescription)"
            )
            relayServer?.stop()
            cliRelayServer = nil
            scheduleReverseRelayRestartLocked(remotePath: remotePath, delay: 2.0)
        }
    }

    private func ensureCLIRelayServerLocked(
        localSocketPath: String,
        relayID: String,
        relayToken: String
    ) throws -> RemoteCLIRelayServer {
        if let existing = cliRelayServer {
            return existing
        }
        let server = try RemoteCLIRelayServer(
            localSocketPath: localSocketPath,
            relayID: relayID,
            relayTokenHex: relayToken
        )
        cliRelayServer = server
        return server
    }

    private func installReverseRelayStderrHandlerLocked(_ stderrPipe: Pipe) {
        stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            self?.queue.async {
                guard let self else { return }
                if let chunk = String(data: data, encoding: .utf8), !chunk.isEmpty {
                    self.reverseRelayStderrBuffer.append(chunk)
                    if self.reverseRelayStderrBuffer.count > 8192 {
                        self.reverseRelayStderrBuffer.removeFirst(
                            self.reverseRelayStderrBuffer.count - 8192
                        )
                    }
                }
            }
        }
    }

    private func handleReverseRelayTerminationLocked(process: Process) {
        guard reverseRelayProcess === process else { return }
        let stderrDetail = RemoteDaemonRPCClient.bestErrorLine(stderr: reverseRelayStderrBuffer)
        reverseRelayStderrPipe?.fileHandleForReading.readabilityHandler = nil
        reverseRelayProcess = nil
        reverseRelayStderrPipe = nil

        guard !isStopping else { return }
        guard let remotePath = daemonRemotePath,
              !remotePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        let detail = stderrDetail ?? "status=\(process.terminationStatus)"
        debugLog("remote.relay.exit \(detail)")
        scheduleReverseRelayRestartLocked(remotePath: remotePath, delay: 2.0)
    }

    private func scheduleReverseRelayRestartLocked(remotePath: String, delay: TimeInterval) {
        guard !isStopping else { return }
        reverseRelayRestartWorkItem?.cancel()

        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.reverseRelayRestartWorkItem = nil
            guard !self.isStopping else { return }
            guard self.reverseRelayProcess == nil else { return }
            guard self.daemonReady else { return }
            self.startReverseRelayLocked(remotePath: self.daemonRemotePath ?? remotePath)
        }
        reverseRelayRestartWorkItem = workItem
        queue.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func stopReverseRelayLocked() {
        reverseRelayStderrPipe?.fileHandleForReading.readabilityHandler = nil
        if let process = reverseRelayProcess, process.isRunning {
            process.terminate()
        }
        reverseRelayProcess = nil
        reverseRelayStderrPipe = nil
        reverseRelayStderrBuffer = ""
        cliRelayServer?.stop()
        cliRelayServer = nil
        removeRemoteRelayMetadataLocked()
    }

    // MARK: - Relay metadata

    private func installRemoteRelayMetadataLocked(
        remotePath: String,
        relayPort: Int,
        relayID: String,
        relayToken: String
    ) throws {
        guard relayID.range(of: "^[0-9a-f]+$", options: .regularExpression) != nil,
              relayToken.range(of: "^[0-9a-f]+$", options: .regularExpression) != nil else {
            throw NSError(domain: "namu.remote.session", code: 71, userInfo: [
                NSLocalizedDescriptionKey: "relay credentials contain invalid characters",
            ])
        }
        let script = Self.remoteRelayMetadataInstallScript(
            daemonRemotePath: remotePath,
            relayPort: relayPort,
            relayID: relayID,
            relayToken: relayToken
        )
        let command = "sh -c \(RemoteDaemonRPCClient.shellSingleQuoted(script))"
        let result = try sshExec(
            arguments: RemoteDaemonRPCClient.sshCommonArguments(configuration: configuration, batchMode: true)
                + [configuration.destination, command],
            timeout: 8
        )
        guard result.status == 0 else {
            let detail = Self.bestErrorLine(stderr: result.stderr, stdout: result.stdout)
                ?? "ssh exited \(result.status)"
            throw NSError(domain: "namu.remote.session", code: 70, userInfo: [
                NSLocalizedDescriptionKey: "failed to install remote relay metadata: \(detail)",
            ])
        }
    }

    private func removeRemoteRelayMetadataLocked() {
        guard let relayPort = configuration.relayPort, relayPort > 0 else { return }
        let script = Self.remoteRelayMetadataCleanupScript(relayPort: relayPort)
        let command = "sh -c \(RemoteDaemonRPCClient.shellSingleQuoted(script))"
        do {
            _ = try sshExec(
                arguments: RemoteDaemonRPCClient.sshCommonArguments(configuration: configuration, batchMode: true)
                    + [configuration.destination, command],
                timeout: 8
            )
        } catch {
            debugLog("remote.relay.cleanup.error \(error.localizedDescription)")
        }
    }

    // MARK: - Relay metadata scripts

    static func remoteRelayMetadataCleanupScript(relayPort: Int) -> String {
        """
        relay_socket='127.0.0.1:\(relayPort)'
        socket_addr_file="$HOME/.namu/socket_addr"
        if [ -r "$socket_addr_file" ] && [ "$(tr -d '\\r\\n' < "$socket_addr_file")" = "$relay_socket" ]; then
          rm -f "$socket_addr_file"
        fi
        rm -f "$HOME/.namu/relay/\(relayPort).auth" "$HOME/.namu/relay/\(relayPort).daemon_path"
        """
    }

    static func remoteCLIWrapperScript() -> String {
        """
        #!/usr/bin/env bash
        set -euo pipefail

        daemon="$HOME/.namu/bin/namud-remote-current"
        socket_path="${NAMU_SOCKET_PATH:-}"
        if [ -z "$socket_path" ] && [ -r "$HOME/.namu/socket_addr" ]; then
          socket_path="$(tr -d '\\r\\n' < "$HOME/.namu/socket_addr")"
        fi

        if [ -n "$socket_path" ] && [ "${socket_path#/}" = "$socket_path" ] && [ "${socket_path#*:}" != "$socket_path" ]; then
          relay_port="${socket_path##*:}"
          relay_map="$HOME/.namu/relay/${relay_port}.daemon_path"
          if [ -r "$relay_map" ]; then
            mapped_daemon="$(tr -d '\\r\\n' < "$relay_map")"
            if [ -n "$mapped_daemon" ] && [ -x "$mapped_daemon" ]; then
              daemon="$mapped_daemon"
            fi
          fi
        fi

        exec "$daemon" "$@"
        """
    }

    static func remoteCLIWrapperInstallScript(daemonRemotePath: String) -> String {
        let trimmedRemotePath = daemonRemotePath.trimmingCharacters(in: .whitespacesAndNewlines)
        return """
        mkdir -p "$HOME/.namu/bin" "$HOME/.namu/relay"
        ln -sf "$HOME/\(trimmedRemotePath)" "$HOME/.namu/bin/namud-remote-current"
        wrapper_tmp="$HOME/.namu/bin/.namu-wrapper.tmp.$$"
        cat > "$wrapper_tmp" <<'NAMUWRAPPER'
        \(remoteCLIWrapperScript())
        NAMUWRAPPER
        chmod 755 "$wrapper_tmp"
        mv -f "$wrapper_tmp" "$HOME/.namu/bin/namu"
        """
    }

    static func remoteRelayMetadataInstallScript(
        daemonRemotePath: String,
        relayPort: Int,
        relayID: String,
        relayToken: String
    ) -> String {
        let trimmedRemotePath = daemonRemotePath.trimmingCharacters(in: .whitespacesAndNewlines)
        let authPayload = """
        {"relay_id":"\(relayID)","relay_token":"\(relayToken)"}
        """
        return """
        umask 077
        mkdir -p "$HOME/.namu" "$HOME/.namu/relay"
        chmod 700 "$HOME/.namu/relay"
        \(remoteCLIWrapperInstallScript(daemonRemotePath: trimmedRemotePath))
        _daemon_path_tmp="$HOME/.namu/relay/\(relayPort).daemon_path.tmp"
        printf '%s' "$HOME/\(trimmedRemotePath)" > "$_daemon_path_tmp"
        mv -f "$_daemon_path_tmp" "$HOME/.namu/relay/\(relayPort).daemon_path"
        _auth_tmp="$HOME/.namu/relay/\(relayPort).auth.tmp"
        cat > "$_auth_tmp" <<'NAMURELAYAUTH'
        \(authPayload)
        NAMURELAYAUTH
        chmod 600 "$_auth_tmp"
        mv "$_auth_tmp" "$HOME/.namu/relay/\(relayPort).auth"
        _socket_addr_tmp="$HOME/.namu/socket_addr.tmp"
        printf '%s' '127.0.0.1:\(relayPort)' > "$_socket_addr_tmp"
        mv -f "$_socket_addr_tmp" "$HOME/.namu/socket_addr"
        """
    }

    // MARK: - Reconnect scheduling

    @discardableResult
    private func scheduleReconnectLocked(delay: TimeInterval) -> Int {
        guard !isStopping else { return connectionAttemptCount }
        reconnectWorkItem?.cancel()
        connectionAttemptCount += 1
        let attemptNumber = connectionAttemptCount

        // M3: Exponential backoff with ±20% jitter, capped at 60 seconds.
        // Formula: baseDelay * 2^(attempts-1), then add random jitter.
        let exponentialDelay = min(delay * pow(2.0, Double(connectionAttemptCount - 1)), 60.0)
        let jitter = exponentialDelay * Double.random(in: -0.2...0.2)
        let effectiveDelay = max(delay, exponentialDelay + jitter)

        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.reconnectWorkItem = nil
            guard !self.isStopping else { return }
            guard self.proxyLease == nil else { return }
            self.beginConnectionAttemptLocked()
        }
        reconnectWorkItem = workItem
        queue.asyncAfter(deadline: .now() + effectiveDelay, execute: workItem)
        return attemptNumber
    }

    // MARK: - Heartbeat

    private func recordHeartbeatActivityLocked() {
        heartbeatCount += 1
        let count = heartbeatCount
        let now = Date()
        lastHeartbeatAt = now
        publishHeartbeat(count: count, at: now)
    }

    // MARK: - Publish helpers (always dispatch to main thread)

    private func publishState(_ state: RemoteConnectionState, detail: String?) {
        let controller = self
        DispatchQueue.main.async { [weak self] in
            guard let self, self === controller else { return }
            self.delegate?.remoteSession(self, didUpdateConnectionState: state, detail: detail)
        }
    }

    private func publishDaemonStatus(_ status: RemoteDaemonStatus) {
        let controller = self
        DispatchQueue.main.async { [weak self] in
            guard let self, self === controller else { return }
            self.delegate?.remoteSession(self, didUpdateDaemonStatus: status)
        }
    }

    private func publishProxyEndpoint(_ endpoint: RemoteProxyEndpoint?) {
        let controller = self
        DispatchQueue.main.async { [weak self] in
            guard let self, self === controller else { return }
            self.delegate?.remoteSession(self, didUpdateProxyEndpoint: endpoint)
        }
    }

    private func publishHeartbeat(count: Int, at date: Date?) {
        let controller = self
        DispatchQueue.main.async { [weak self] in
            guard let self, self === controller else { return }
            self.delegate?.remoteSession(self, didUpdateHeartbeat: count, lastSeenAt: date)
        }
    }

    private func publishError(_ message: String) {
        let controller = self
        DispatchQueue.main.async { [weak self] in
            guard let self, self === controller else { return }
            self.delegate?.remoteSession(self, didEncounterError: message)
        }
    }

    // MARK: - Bootstrap

    private func bootstrapDaemonLocked() throws -> DaemonHello {
        debugLog("remote.bootstrap.begin \(debugConfigSummary())")
        let version = Self.remoteDaemonVersion()
        let bootstrapState = try probeRemoteBootstrapStateLocked(version: version)
        let platform = bootstrapState.platform
        let remotePath = Self.remoteDaemonPath(version: version, goOS: platform.goOS, goArch: platform.goArch)
        let explicitOverrideBinary = Self.explicitRemoteDaemonBinaryURL()
        let forceExplicitOverrideInstall = explicitOverrideBinary != nil
        debugLog(
            "remote.bootstrap.platform os=\(platform.goOS) arch=\(platform.goArch) " +
            "version=\(version) remotePath=\(remotePath) " +
            "allowLocalBuildFallback=\(Self.allowLocalDaemonBuildFallback() ? 1 : 0) " +
            "explicitOverride=\(forceExplicitOverrideInstall ? 1 : 0)"
        )

        let hadExistingBinary = bootstrapState.binaryExists
        debugLog("remote.bootstrap.binaryExists remotePath=\(remotePath) exists=\(hadExistingBinary ? 1 : 0)")

        if forceExplicitOverrideInstall || !hadExistingBinary {
            let localBinary = try provisionDaemonBinaryLocked(
                goOS: platform.goOS,
                goArch: platform.goArch,
                version: version
            )
            try uploadDaemonBinaryLocked(localBinary: localBinary, remotePath: remotePath)
        }

        var hello: DaemonHello
        do {
            hello = try helloDaemonLocked(remotePath: remotePath)
        } catch {
            guard hadExistingBinary else {
                throw error
            }
            // Existing binary failed hello — re-provision and retry once.
            debugLog(
                "remote.bootstrap.helloRetry remotePath=\(remotePath) " +
                "detail=\(error.localizedDescription)"
            )
            let localBinary = try provisionDaemonBinaryLocked(
                goOS: platform.goOS,
                goArch: platform.goArch,
                version: version
            )
            try uploadDaemonBinaryLocked(localBinary: localBinary, remotePath: remotePath)
            hello = try helloDaemonLocked(remotePath: remotePath)
        }

        // If we found an existing binary but it's missing the required capability, re-provision.
        if hadExistingBinary,
           !hello.capabilities.contains(RemoteDaemonRPCClient.requiredProxyStreamCapability) {
            debugLog(
                "remote.bootstrap.capabilityMissing remotePath=\(remotePath) " +
                "capabilities=\(hello.capabilities.joined(separator: ","))"
            )
            let localBinary = try provisionDaemonBinaryLocked(
                goOS: platform.goOS,
                goArch: platform.goArch,
                version: version
            )
            try uploadDaemonBinaryLocked(localBinary: localBinary, remotePath: remotePath)
            hello = try helloDaemonLocked(remotePath: remotePath)
        }

        debugLog(
            "remote.bootstrap.ready name=\(hello.name) version=\(hello.version) " +
            "capabilities=\(hello.capabilities.joined(separator: ",")) remotePath=\(hello.remotePath)"
        )
        if let startedAt = connectionAttemptStartedAt {
            debugLog(
                "remote.timing.bootstrap.ready elapsedMs=\(Int(Date().timeIntervalSince(startedAt) * 1000)) " +
                "\(debugConfigSummary())"
            )
        }
        return hello
    }

    // MARK: - Remote probe

    private func probeRemoteBootstrapStateLocked(version: String) throws -> RemoteBootstrapState {
        let script = """
        namu_uname_os="$(uname -s)"
        namu_uname_arch="$(uname -m)"
        printf '%s%s\\n' '\(Self.remotePlatformProbeOSMarker)' "$namu_uname_os"
        printf '%s%s\\n' '\(Self.remotePlatformProbeArchMarker)' "$namu_uname_arch"
        case "$(printf '%s' "$namu_uname_os" | tr '[:upper:]' '[:lower:]')" in
          linux|darwin|freebsd) namu_go_os="$(printf '%s' "$namu_uname_os" | tr '[:upper:]' '[:lower:]')" ;;
          *) exit 70 ;;
        esac
        case "$(printf '%s' "$namu_uname_arch" | tr '[:upper:]' '[:lower:]')" in
          x86_64|amd64) namu_go_arch=amd64 ;;
          aarch64|arm64) namu_go_arch=arm64 ;;
          armv7l) namu_go_arch=arm ;;
          *) exit 71 ;;
        esac
        namu_remote_path="$HOME/.namu/bin/namud-remote/\(version)/${namu_go_os}-${namu_go_arch}/namud-remote"
        if [ -x "$namu_remote_path" ]; then
          printf '%syes\\n' '\(Self.remotePlatformProbeExistsMarker)'
        else
          printf '%sno\\n' '\(Self.remotePlatformProbeExistsMarker)'
        fi
        """
        let command = "sh -c \(RemoteDaemonRPCClient.shellSingleQuoted(script))"
        let result = try sshExec(
            arguments: RemoteDaemonRPCClient.sshCommonArguments(configuration: configuration, batchMode: true)
                + [configuration.destination, command],
            timeout: 20
        )

        let lines = result.stdout
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        let unameOS = lines.first { $0.hasPrefix(Self.remotePlatformProbeOSMarker) }
            .map { String($0.dropFirst(Self.remotePlatformProbeOSMarker.count)) }
        let unameArch = lines.first { $0.hasPrefix(Self.remotePlatformProbeArchMarker) }
            .map { String($0.dropFirst(Self.remotePlatformProbeArchMarker.count)) }

        guard let unameOS, let unameArch else {
            let detail = Self.bestErrorLine(stderr: result.stderr, stdout: result.stdout)
                ?? "ssh exited \(result.status)"
            throw NSError(domain: "namu.remote.session", code: 11, userInfo: [
                NSLocalizedDescriptionKey: "failed to query remote platform: \(detail)",
            ])
        }

        guard let goOS = Self.mapUnameOS(unameOS),
              let goArch = Self.mapUnameArch(unameArch) else {
            throw NSError(domain: "namu.remote.session", code: 12, userInfo: [
                NSLocalizedDescriptionKey: "unsupported remote platform \(unameOS)/\(unameArch)",
            ])
        }

        let binaryExists = lines.first { $0.hasPrefix(Self.remotePlatformProbeExistsMarker) }
            .map { String($0.dropFirst(Self.remotePlatformProbeExistsMarker.count)) == "yes" }

        if result.status != 0, binaryExists == nil {
            let detail = Self.bestErrorLine(stderr: result.stderr, stdout: result.stdout)
                ?? "ssh exited \(result.status)"
            throw NSError(domain: "namu.remote.session", code: 13, userInfo: [
                NSLocalizedDescriptionKey: "failed to query remote daemon state: \(detail)",
            ])
        }

        return RemoteBootstrapState(
            platform: RemotePlatform(goOS: goOS, goArch: goArch),
            binaryExists: binaryExists ?? false
        )
    }

    // MARK: - Hello

    private func helloDaemonLocked(remotePath: String) throws -> DaemonHello {
        let request = #"{"id":1,"method":"hello","params":{}}"#
        let script = "printf '%s\\n' \(RemoteDaemonRPCClient.shellSingleQuoted(request)) | \(RemoteDaemonRPCClient.shellSingleQuoted(remotePath)) serve --stdio"
        let command = "sh -c \(RemoteDaemonRPCClient.shellSingleQuoted(script))"
        let result = try sshExec(
            arguments: RemoteDaemonRPCClient.sshCommonArguments(configuration: configuration, batchMode: true)
                + [configuration.destination, command],
            timeout: 12
        )
        guard result.status == 0 else {
            let detail = Self.bestErrorLine(stderr: result.stderr, stdout: result.stdout)
                ?? "ssh exited \(result.status)"
            throw NSError(domain: "namu.remote.session", code: 40, userInfo: [
                NSLocalizedDescriptionKey: "failed to start remote daemon: \(detail)",
            ])
        }

        let responseLine = result.stdout
            .split(separator: "\n")
            .map(String.init)
            .first(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) ?? ""
        guard !responseLine.isEmpty,
              let data = responseLine.data(using: .utf8),
              let payload = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any] else {
            throw NSError(domain: "namu.remote.session", code: 41, userInfo: [
                NSLocalizedDescriptionKey: "remote daemon hello returned invalid JSON",
            ])
        }

        if let ok = payload["ok"] as? Bool, !ok {
            let errorMessage: String = {
                if let errorObject = payload["error"] as? [String: Any],
                   let message = errorObject["message"] as? String,
                   !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return message
                }
                return "hello call failed"
            }()
            throw NSError(domain: "namu.remote.session", code: 42, userInfo: [
                NSLocalizedDescriptionKey: "remote daemon hello failed: \(errorMessage)",
            ])
        }

        let resultObject = payload["result"] as? [String: Any] ?? [:]
        let name = (resultObject["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let version = (resultObject["version"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let capabilities = (resultObject["capabilities"] as? [String]) ?? []
        return DaemonHello(
            name: (name?.isEmpty == false ? name! : "namud-remote"),
            version: (version?.isEmpty == false ? version! : "dev"),
            capabilities: capabilities,
            remotePath: remotePath
        )
    }

    // MARK: - Binary provisioning

    /// Resolve or build a local copy of the daemon binary for the given target platform.
    private func provisionDaemonBinaryLocked(goOS: String, goArch: String, version: String) throws -> URL {
        // 1. Explicit binary override (dev workflow).
        if let explicitBinary = Self.explicitRemoteDaemonBinaryURL(),
           FileManager.default.isExecutableFile(atPath: explicitBinary.path) {
            debugLog("remote.provision.explicit path=\(explicitBinary.path)")
            return explicitBinary
        }

        // 2. Embedded manifest — use cached binary if SHA256 matches, otherwise download.
        if let manifest = Self.remoteDaemonManifest(),
           manifest.appVersion == version,
           let entry = manifest.entry(goOS: goOS, goArch: goArch) {
            let cacheURL = try Self.remoteDaemonCachedBinaryURL(version: manifest.appVersion, goOS: goOS, goArch: goArch)
            let fileManager = FileManager.default
            if fileManager.fileExists(atPath: cacheURL.path) {
                let cachedSHA = try Self.sha256Hex(forFile: cacheURL)
                if cachedSHA == entry.sha256.lowercased(),
                   fileManager.isExecutableFile(atPath: cacheURL.path) {
                    debugLog("remote.provision.cached path=\(cacheURL.path)")
                    return cacheURL
                }
                try? fileManager.removeItem(at: cacheURL)
            }
            let downloadedURL = try downloadDaemonBinaryLocked(entry: entry, version: manifest.appVersion, manifest: manifest)
            debugLog("remote.provision.downloaded path=\(downloadedURL.path)")
            return downloadedURL
        }

        // 3. Dev fallback: build locally via `go build`.
        guard Self.allowLocalDaemonBuildFallback() else {
            throw NSError(domain: "namu.remote.session", code: 20, userInfo: [
                NSLocalizedDescriptionKey: "this build does not include a verified namud-remote manifest for \(goOS)-\(goArch). Use a release/nightly build, or set NAMU_REMOTE_DAEMON_ALLOW_LOCAL_BUILD=1 for a dev-only fallback.",
            ])
        }

        guard let repoRoot = Self.findRepoRoot() else {
            throw NSError(domain: "namu.remote.session", code: 20, userInfo: [
                NSLocalizedDescriptionKey: "cannot locate namu repo root for dev-only namud-remote build fallback",
            ])
        }
        let daemonRoot = repoRoot.appendingPathComponent("daemon/remote", isDirectory: true)
        let goModPath = daemonRoot.appendingPathComponent("go.mod").path
        guard FileManager.default.fileExists(atPath: goModPath) else {
            throw NSError(domain: "namu.remote.session", code: 21, userInfo: [
                NSLocalizedDescriptionKey: "missing daemon module at \(goModPath)",
            ])
        }
        guard let goBinary = Self.which("go") else {
            throw NSError(domain: "namu.remote.session", code: 22, userInfo: [
                NSLocalizedDescriptionKey: "go is required for the dev-only namud-remote build fallback",
            ])
        }

        let output = Self.versionedRemoteDaemonBuildURL(goOS: goOS, goArch: goArch, version: version)
        try FileManager.default.createDirectory(
            at: output.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        var env = ProcessInfo.processInfo.environment
        env["GOOS"] = goOS
        env["GOARCH"] = goArch
        env["CGO_ENABLED"] = "0"
        let ldflags = "-s -w -X main.version=\(version)"
        let result = try runProcess(
            executable: goBinary,
            arguments: ["build", "-trimpath", "-buildvcs=false", "-ldflags", ldflags, "-o", output.path, "./cmd/namud-remote"],
            environment: env,
            currentDirectory: daemonRoot,
            stdin: nil,
            timeout: 90
        )
        guard result.status == 0 else {
            let detail = Self.bestErrorLine(stderr: result.stderr, stdout: result.stdout)
                ?? "go build failed with status \(result.status)"
            throw NSError(domain: "namu.remote.session", code: 23, userInfo: [
                NSLocalizedDescriptionKey: "failed to build namud-remote: \(detail)",
            ])
        }
        guard FileManager.default.isExecutableFile(atPath: output.path) else {
            throw NSError(domain: "namu.remote.session", code: 24, userInfo: [
                NSLocalizedDescriptionKey: "namud-remote build output is not executable",
            ])
        }
        debugLog("remote.provision.built path=\(output.path)")
        return output
    }

    // MARK: - Binary download

    private func downloadDaemonBinaryLocked(
        entry: RemoteDaemonManifest.Entry,
        version: String,
        manifest: RemoteDaemonManifest
    ) throws -> URL {
        guard let url = URL(string: entry.downloadURL) else {
            throw NSError(domain: "namu.remote.session", code: 25, userInfo: [
                NSLocalizedDescriptionKey: "remote daemon manifest has an invalid download URL",
            ])
        }

        let cacheURL = try Self.remoteDaemonCachedBinaryURL(version: version, goOS: entry.goOS, goArch: entry.goArch)
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        let request = NSMutableURLRequest(url: url)
        request.timeoutInterval = 60
        request.setValue("namu/\(version)", forHTTPHeaderField: "User-Agent")
        let session = URLSession(configuration: .ephemeral)

        let semaphore = DispatchSemaphore(value: 0)
        var downloadedURL: URL?
        var downloadError: Error?
        let task = session.downloadTask(with: request as URLRequest) { localURL, response, error in
            defer { semaphore.signal() }
            if let error {
                downloadError = error
                return
            }
            if let httpResponse = response as? HTTPURLResponse,
               !(200...299).contains(httpResponse.statusCode) {
                downloadError = NSError(domain: "namu.remote.session", code: 26, userInfo: [
                    NSLocalizedDescriptionKey: "remote daemon download failed with HTTP \(httpResponse.statusCode)",
                ])
                return
            }
            downloadedURL = localURL
        }
        task.resume()
        // M6: Wait slightly longer than URLSession's own 60-second timeout so that
        // URLSession's built-in error fires first; cancel the task if we time out anyway.
        let waitResult = semaphore.wait(timeout: .now() + 65.0)
        if waitResult == .timedOut {
            task.cancel()
            session.invalidateAndCancel()
            throw NSError(domain: "namu.remote.session", code: 27, userInfo: [
                NSLocalizedDescriptionKey: "remote daemon download timed out",
            ])
        }
        session.finishTasksAndInvalidate()

        if let downloadError {
            throw downloadError
        }
        guard let downloadedURL else {
            throw NSError(domain: "namu.remote.session", code: 27, userInfo: [
                NSLocalizedDescriptionKey: "remote daemon download did not produce a file",
            ])
        }

        let downloadedSHA = try Self.sha256Hex(forFile: downloadedURL)
        if downloadedSHA != entry.sha256.lowercased() {
            // Allow live manifest fallback for nightly/dev builds only when explicitly opted in.
            let allowLiveFallback = ProcessInfo.processInfo.environment["NAMU_REMOTE_DAEMON_ALLOW_LIVE_MANIFEST"] == "1"
            if allowLiveFallback,
               let releaseURL = URL(string: manifest.releaseURL),
               let liveManifest = Self.fetchLiveManifest(releaseURL: releaseURL, version: version),
               let liveEntry = liveManifest.entry(goOS: entry.goOS, goArch: entry.goArch),
               downloadedSHA == liveEntry.sha256.lowercased() {
                // Live manifest checksum matches — accept the binary.
            } else {
                throw NSError(domain: "namu.remote.session", code: 28, userInfo: [
                    NSLocalizedDescriptionKey: "remote daemon checksum mismatch for \(entry.assetName): expected \(entry.sha256), got \(downloadedSHA)",
                ])
            }
        }

        let tempURL = cacheURL.deletingLastPathComponent()
            .appendingPathComponent(".\(cacheURL.lastPathComponent).tmp-\(UUID().uuidString)")
        try? fileManager.removeItem(at: tempURL)
        try fileManager.moveItem(at: downloadedURL, to: tempURL)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tempURL.path)
        try? fileManager.removeItem(at: cacheURL)
        try fileManager.moveItem(at: tempURL, to: cacheURL)
        return cacheURL
    }

    /// Fetch a live manifest from the release URL — used only when
    /// `NAMU_REMOTE_DAEMON_ALLOW_LIVE_MANIFEST=1` to allow nightly/dev build fallback.
    private static func fetchLiveManifest(releaseURL: URL, version: String) -> RemoteDaemonManifest? {
        let manifestURL = releaseURL.appendingPathComponent("namud-remote-manifest.json")
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 15
        let session = URLSession(configuration: config)
        let sema = DispatchSemaphore(value: 0)
        var result: RemoteDaemonManifest?
        let task = session.dataTask(with: manifestURL) { data, response, error in
            defer { sema.signal() }
            guard let data, error == nil,
                  let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else { return }
            result = try? JSONDecoder().decode(RemoteDaemonManifest.self, from: data)
        }
        task.resume()
        _ = sema.wait(timeout: .now() + 15)
        task.cancel()
        session.invalidateAndCancel()
        return result
    }

    // MARK: - Binary upload

    private func uploadDaemonBinaryLocked(localBinary: URL, remotePath: String) throws {
        // Validate each component of the remote path to prevent traversal.
        let pathComponents = remotePath.split(separator: "/").map(String.init)
        for component in pathComponents {
            guard Self.sanitizedPathComponent(component) != nil else {
                throw NSError(domain: "namu.remote.session", code: 73, userInfo: [
                    NSLocalizedDescriptionKey: "remote daemon path contains invalid component: \(component)",
                ])
            }
        }
        let remoteDirectory = (remotePath as NSString).deletingLastPathComponent
        let remoteTempPath = "\(remotePath).tmp-\(UUID().uuidString.prefix(8))"
        debugLog(
            "remote.upload.begin local=\(localBinary.path) remoteTemp=\(remoteTempPath) remote=\(remotePath)"
        )

        let mkdirScript = "mkdir -p \(RemoteDaemonRPCClient.shellSingleQuoted(remoteDirectory))"
        let mkdirCommand = "sh -c \(RemoteDaemonRPCClient.shellSingleQuoted(mkdirScript))"
        let mkdirResult = try sshExec(
            arguments: RemoteDaemonRPCClient.sshCommonArguments(configuration: configuration, batchMode: true)
                + [configuration.destination, mkdirCommand],
            timeout: 12
        )
        guard mkdirResult.status == 0 else {
            let detail = Self.bestErrorLine(stderr: mkdirResult.stderr, stdout: mkdirResult.stdout)
                ?? "ssh exited \(mkdirResult.status)"
            throw NSError(domain: "namu.remote.session", code: 30, userInfo: [
                NSLocalizedDescriptionKey: "failed to create remote daemon directory: \(detail)",
            ])
        }

        var scpArgs: [String] = ["-q"]
        if let port = configuration.port {
            scpArgs += ["-P", String(port)]
        }
        if let identityFile = configuration.identityFile,
           !identityFile.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            scpArgs += ["-i", identityFile]
        }
        scpArgs += ["-o", "ControlMaster=no"]
        scpArgs += ["-o", "StrictHostKeyChecking=accept-new"]
        scpArgs += ["-o", "ConnectTimeout=6"]
        scpArgs += ["-o", "BatchMode=yes"]
        for option in filteredSSHOptionsForSCP() {
            scpArgs += ["-o", option]
        }
        scpArgs += [localBinary.path, "\(configuration.destination):\(remoteTempPath)"]
        let scpResult = try scpExec(arguments: scpArgs, timeout: 45)
        guard scpResult.status == 0 else {
            let detail = Self.bestErrorLine(stderr: scpResult.stderr, stdout: scpResult.stdout)
                ?? "scp exited \(scpResult.status)"
            throw NSError(domain: "namu.remote.session", code: 31, userInfo: [
                NSLocalizedDescriptionKey: "failed to upload namud-remote: \(detail)",
            ])
        }

        let finalizeScript = """
        chmod 755 \(RemoteDaemonRPCClient.shellSingleQuoted(remoteTempPath)) && \
        mv \(RemoteDaemonRPCClient.shellSingleQuoted(remoteTempPath)) \(RemoteDaemonRPCClient.shellSingleQuoted(remotePath))
        """
        let finalizeCommand = "sh -c \(RemoteDaemonRPCClient.shellSingleQuoted(finalizeScript))"
        let finalizeResult = try sshExec(
            arguments: RemoteDaemonRPCClient.sshCommonArguments(configuration: configuration, batchMode: true)
                + [configuration.destination, finalizeCommand],
            timeout: 12
        )
        guard finalizeResult.status == 0 else {
            let detail = Self.bestErrorLine(stderr: finalizeResult.stderr, stdout: finalizeResult.stdout)
                ?? "ssh exited \(finalizeResult.status)"
            // M5: Best-effort cleanup of the orphaned temp file on the remote host.
            let cleanupScript = "rm -f \(RemoteDaemonRPCClient.shellSingleQuoted(remoteTempPath))"
            _ = try? sshExec(
                arguments: RemoteDaemonRPCClient.sshCommonArguments(configuration: configuration, batchMode: true)
                    + [configuration.destination, cleanupScript],
                timeout: 8
            )
            throw NSError(domain: "namu.remote.session", code: 32, userInfo: [
                NSLocalizedDescriptionKey: "failed to install remote daemon binary: \(detail)",
            ])
        }
        debugLog("remote.upload.done remote=\(remotePath)")
    }

    // MARK: - File upload (drag-and-drop)

    private func uploadFilesLocked(_ fileURLs: [URL]) throws {
        guard !fileURLs.isEmpty else { return }

        for localURL in fileURLs {
            let normalizedLocalURL = localURL.standardizedFileURL
            guard normalizedLocalURL.isFileURL else {
                throw RemoteDropUploadError.invalidFileURL
            }

            let remotePath = Self.remoteDropPath(for: normalizedLocalURL)
            var scpArgs: [String] = ["-q", "-o", "ControlMaster=no"]
            if let port = configuration.port {
                scpArgs += ["-P", String(port)]
            }
            if let identityFile = configuration.identityFile,
               !identityFile.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                scpArgs += ["-i", identityFile]
            }
            scpArgs += ["-o", "StrictHostKeyChecking=accept-new"]
            scpArgs += ["-o", "BatchMode=yes"]
            for option in filteredSSHOptionsForSCP() {
                scpArgs += ["-o", option]
            }
            scpArgs += [normalizedLocalURL.path, "\(configuration.destination):\(remotePath)"]

            let result = try scpExec(arguments: scpArgs, timeout: 45)
            guard result.status == 0 else {
                let detail = Self.bestErrorLine(stderr: result.stderr, stdout: result.stdout)
                    ?? "scp exited \(result.status)"
                throw RemoteDropUploadError.uploadFailed(detail)
            }
        }
    }

    static func remoteDropPath(for fileURL: URL, uuid: UUID = UUID()) -> String {
        let extensionSuffix = fileURL.pathExtension.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowercasedSuffix = extensionSuffix.isEmpty ? "" : ".\(extensionSuffix.lowercased())"
        return "/tmp/namu-drop-\(uuid.uuidString.lowercased())\(lowercasedSuffix)"
    }

    // MARK: - Reverse relay arguments

    private func reverseRelayArguments(relayPort: Int, localRelayPort: Int) -> [String] {
        // `-S none` forces a standalone transport — prevents attaching to a ControlMaster.
        var args: [String] = ["-N", "-T", "-S", "none"]
        args += RemoteDaemonRPCClient.sshCommonArguments(configuration: configuration, batchMode: true)
        args += [
            "-o", "ExitOnForwardFailure=yes",
            "-o", "RequestTTY=no",
            "-R", "127.0.0.1:\(relayPort):127.0.0.1:\(localRelayPort)",
            configuration.destination,
        ]
        return args
    }

    // MARK: - SSH/SCP process helpers

    private func sshExec(arguments: [String], stdin: Data? = nil, timeout: TimeInterval = 15) throws -> CommandResult {
        try runProcess(
            executable: "/usr/bin/ssh",
            arguments: arguments,
            stdin: stdin,
            timeout: timeout
        )
    }

    private func scpExec(arguments: [String], timeout: TimeInterval = 30) throws -> CommandResult {
        try runProcess(
            executable: "/usr/bin/scp",
            arguments: arguments,
            stdin: nil,
            timeout: timeout
        )
    }

    private func runProcess(
        executable: String,
        arguments: [String],
        environment: [String: String]? = nil,
        currentDirectory: URL? = nil,
        stdin: Data?,
        timeout: TimeInterval
    ) throws -> CommandResult {
        debugLog(
            "remote.proc.start exec=\(URL(fileURLWithPath: executable).lastPathComponent) " +
            "timeout=\(Int(timeout)) args=\(debugShellCommand(executable: executable, arguments: arguments))"
        )
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let environment {
            process.environment = environment
        }
        if let currentDirectory {
            process.currentDirectoryURL = currentDirectory
        }

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        if stdin != nil {
            process.standardInput = Pipe()
        } else {
            process.standardInput = FileHandle.nullDevice
        }

        let stdoutHandle = stdoutPipe.fileHandleForReading
        let stderrHandle = stderrPipe.fileHandleForReading
        let captureQueue = DispatchQueue(label: "namu.remote.process.capture.\(UUID().uuidString)")
        let exitSemaphore = DispatchSemaphore(value: 0)
        var stdoutData = Data()
        var stderrData = Data()
        let captureGroup = DispatchGroup()

        process.terminationHandler = { _ in
            exitSemaphore.signal()
        }

        captureGroup.enter()
        DispatchQueue.global(qos: .utility).async {
            let data = stdoutHandle.readDataToEndOfFile()
            captureQueue.sync { stdoutData = data }
            captureGroup.leave()
        }
        captureGroup.enter()
        DispatchQueue.global(qos: .utility).async {
            let data = stderrHandle.readDataToEndOfFile()
            captureQueue.sync { stderrData = data }
            captureGroup.leave()
        }

        do {
            try process.run()
        } catch {
            try? stdoutPipe.fileHandleForWriting.close()
            try? stderrPipe.fileHandleForWriting.close()
            debugLog(
                "remote.proc.launchFailed exec=\(URL(fileURLWithPath: executable).lastPathComponent) " +
                "error=\(error.localizedDescription)"
            )
            throw NSError(domain: "namu.remote.session", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Failed to launch \(URL(fileURLWithPath: executable).lastPathComponent): \(error.localizedDescription)",
            ])
        }
        try? stdoutPipe.fileHandleForWriting.close()
        try? stderrPipe.fileHandleForWriting.close()

        if let stdin, let pipe = process.standardInput as? Pipe {
            pipe.fileHandleForWriting.write(stdin)
            try? pipe.fileHandleForWriting.close()
        }

        func terminateProcessAndWait() {
            process.terminate()
            let terminatedGracefully = exitSemaphore.wait(timeout: .now() + 2.0) == .success
            if !terminatedGracefully, process.isRunning {
                _ = Darwin.kill(process.processIdentifier, SIGKILL)
                process.waitUntilExit()
            }
        }

        let didExitBeforeTimeout = exitSemaphore.wait(timeout: .now() + max(0, timeout)) == .success
        if !didExitBeforeTimeout, process.isRunning {
            terminateProcessAndWait()
            debugLog(
                "remote.proc.timeout exec=\(URL(fileURLWithPath: executable).lastPathComponent) " +
                "timeout=\(Int(timeout)) args=\(debugShellCommand(executable: executable, arguments: arguments))"
            )
            throw NSError(domain: "namu.remote.session", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "\(URL(fileURLWithPath: executable).lastPathComponent) timed out after \(Int(timeout))s",
            ])
        }

        _ = captureGroup.wait(timeout: .now() + 2.0)
        try? stdoutHandle.close()
        try? stderrHandle.close()

        let stdout = String(data: stdoutData, encoding: .utf8) ?? ""
        let stderr = String(data: stderrData, encoding: .utf8) ?? ""
        debugLog(
            "remote.proc.end exec=\(URL(fileURLWithPath: executable).lastPathComponent) " +
            "status=\(process.terminationStatus) stdout=\(Self.debugLogSnippet(stdout)) " +
            "stderr=\(Self.debugLogSnippet(stderr))"
        )
        return CommandResult(status: process.terminationStatus, stdout: stdout, stderr: stderr)
    }

    // MARK: - SSH option helpers

    private func normalizedSSHOptions(_ options: [String]) -> [String] {
        options.compactMap { option in
            let trimmed = option.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            return trimmed
        }
    }

    private static let scpFilteredOptionKeys: Set<String> = ["controlmaster", "controlpersist"]

    private func filteredSSHOptionsForSCP() -> [String] {
        configuration.sshOptions.compactMap { option in
            let trimmed = option.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            let key = trimmed.split(whereSeparator: { $0 == "=" || $0.isWhitespace })
                .first.map(String.init)?.lowercased()
            guard let key, !Self.scpFilteredOptionKeys.contains(key) else { return nil }
            return trimmed
        }
    }

    // MARK: - Static helpers

    static let remoteDaemonManifestInfoKey = "NamuRemoteDaemonManifestJSON"

    static func remoteDaemonManifest(from infoDictionary: [String: Any]?) -> RemoteDaemonManifest? {
        guard let rawManifest = infoDictionary?[remoteDaemonManifestInfoKey] as? String else { return nil }
        let trimmed = rawManifest.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard let data = trimmed.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(RemoteDaemonManifest.self, from: data)
    }

    private static func remoteDaemonManifest() -> RemoteDaemonManifest? {
        remoteDaemonManifest(from: Bundle.main.infoDictionary)
    }

    private static func remoteDaemonCacheRoot(fileManager: FileManager = .default) throws -> URL {
        let appSupportRoot = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let cacheRoot = appSupportRoot
            .appendingPathComponent("Namu", isDirectory: true)
            .appendingPathComponent("remote-daemon", isDirectory: true)
        try fileManager.createDirectory(at: cacheRoot, withIntermediateDirectories: true)
        return cacheRoot
    }

    private static func sanitizedPathComponent(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !trimmed.contains("/"),
              !trimmed.contains("\\"),
              !trimmed.contains(".."),
              !trimmed.hasPrefix(".") else {
            return nil
        }
        return trimmed
    }

    static func remoteDaemonCachedBinaryURL(
        version: String,
        goOS: String,
        goArch: String,
        fileManager: FileManager = .default
    ) throws -> URL {
        guard let safeVersion = sanitizedPathComponent(version),
              let safeGoOS = sanitizedPathComponent(goOS),
              let safeGoArch = sanitizedPathComponent(goArch) else {
            throw NSError(domain: "namu.remote.session", code: 72, userInfo: [
                NSLocalizedDescriptionKey: "manifest fields contain invalid path characters: version=\(version) os=\(goOS) arch=\(goArch)",
            ])
        }
        return try remoteDaemonCacheRoot(fileManager: fileManager)
            .appendingPathComponent(safeVersion, isDirectory: true)
            .appendingPathComponent("\(safeGoOS)-\(safeGoArch)", isDirectory: true)
            .appendingPathComponent("namud-remote", isDirectory: false)
    }

    private static func versionedRemoteDaemonBuildURL(goOS: String, goArch: String, version: String) -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("namu-remote-daemon-build", isDirectory: true)
            .appendingPathComponent(version, isDirectory: true)
            .appendingPathComponent("\(goOS)-\(goArch)", isDirectory: true)
            .appendingPathComponent("namud-remote", isDirectory: false)
    }

    private static func remoteDaemonPath(version: String, goOS: String, goArch: String) -> String {
        ".namu/bin/namud-remote/\(version)/\(goOS)-\(goArch)/namud-remote"
    }

    private static func remoteDaemonVersion() -> String {
        let bundleVersion = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let baseVersion = (bundleVersion?.isEmpty == false) ? bundleVersion! : "dev"
        guard allowLocalDaemonBuildFallback(),
              let sourceFingerprint = remoteDaemonSourceFingerprint(),
              !sourceFingerprint.isEmpty else {
            return baseVersion
        }
        return "\(baseVersion)-dev-\(sourceFingerprint)"
    }

    private static let cachedRemoteDaemonSourceFingerprint: String? = computeRemoteDaemonSourceFingerprint()

    private static func remoteDaemonSourceFingerprint() -> String? {
        cachedRemoteDaemonSourceFingerprint
    }

    private static func computeRemoteDaemonSourceFingerprint(fileManager: FileManager = .default) -> String? {
        guard let repoRoot = findRepoRoot() else { return nil }
        let daemonRoot = repoRoot.appendingPathComponent("daemon/remote", isDirectory: true)
        guard let enumerator = fileManager.enumerator(
            at: daemonRoot,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }

        var relativePaths: [String] = []
        for case let fileURL as URL in enumerator {
            guard let resourceValues = try? fileURL.resourceValues(forKeys: [.isRegularFileKey]),
                  resourceValues.isRegularFile == true else {
                continue
            }
            let relativePath = fileURL.path.replacingOccurrences(of: daemonRoot.path + "/", with: "")
            if relativePath == "go.mod" || relativePath == "go.sum" || relativePath.hasSuffix(".go") {
                relativePaths.append(relativePath)
            }
        }

        guard !relativePaths.isEmpty else { return nil }

        let digest = SHA256.hash(data: relativePaths.sorted().reduce(into: Data()) { partialResult, relativePath in
            let fileURL = daemonRoot.appendingPathComponent(relativePath, isDirectory: false)
            guard let fileData = try? Data(contentsOf: fileURL) else { return }
            partialResult.append(Data(relativePath.utf8))
            partialResult.append(0)
            partialResult.append(fileData)
            partialResult.append(0)
        })
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return String(hex.prefix(12))
    }

    private static func sha256Hex(forFile url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func allowLocalDaemonBuildFallback(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        environment["NAMU_REMOTE_DAEMON_ALLOW_LOCAL_BUILD"] == "1"
    }

    private static func explicitRemoteDaemonBinaryURL(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL? {
        guard let path = environment["NAMU_REMOTE_DAEMON_BINARY"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !path.isEmpty else {
            return nil
        }
        return URL(fileURLWithPath: path, isDirectory: false).standardizedFileURL
    }

    private static func findRepoRoot() -> URL? {
        var candidates: [URL] = []
        let compileTimeRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Remote
            .deletingLastPathComponent() // NamuKit
            .deletingLastPathComponent() // repo root candidate
        candidates.append(compileTimeRoot)

        let environment = ProcessInfo.processInfo.environment
        if let envRoot = environment["NAMU_REMOTE_DAEMON_SOURCE_ROOT"],
           !envRoot.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            candidates.append(URL(fileURLWithPath: envRoot, isDirectory: true))
        }
        candidates.append(URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true))
        if let executable = Bundle.main.executableURL?.deletingLastPathComponent() {
            candidates.append(executable)
            candidates.append(executable.deletingLastPathComponent())
            candidates.append(executable.deletingLastPathComponent().deletingLastPathComponent())
        }

        let fm = FileManager.default
        for base in candidates {
            var cursor = base.standardizedFileURL
            for _ in 0..<10 {
                let marker = cursor.appendingPathComponent("daemon/remote/go.mod").path
                if fm.fileExists(atPath: marker) {
                    return cursor
                }
                let parent = cursor.deletingLastPathComponent()
                if parent.path == cursor.path { break }
                cursor = parent
            }
        }
        return nil
    }

    private static func killOrphanedRelayProcesses(relayPort: Int, destination: String) {
        let escapedDest = NSRegularExpression.escapedPattern(for: destination)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        process.arguments = ["-f", "ssh.*-R.*127\\.0\\.0\\.1:\(relayPort):127\\.0\\.0\\.1:[0-9]+.*\(escapedDest)"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            // Best effort cleanup only.
        }
    }

    // M8: Potential race — the process could terminate between `run()` and the handler
    // replacement here. The double `isRunning` check (before and after setting the
    // combined handler) closes the window: if the process exits in that gap, the
    // second `isRunning` check signals the semaphore immediately so we don't miss it.
    // The `process.terminationHandler` set in `startReverseRelayLocked` is preserved
    // by chaining via `originalTerminationHandler`.
    private static func reverseRelayStartupFailureDetail(
        process: Process,
        stderrPipe: Pipe,
        gracePeriod: TimeInterval = reverseRelayStartupGracePeriod
    ) -> String? {
        if process.isRunning {
            let originalTerminationHandler = process.terminationHandler
            let exitSemaphore = DispatchSemaphore(value: 0)
            process.terminationHandler = { terminated in
                originalTerminationHandler?(terminated)
                exitSemaphore.signal()
            }
            if !process.isRunning {
                exitSemaphore.signal()
            }
            guard exitSemaphore.wait(timeout: .now() + max(0, gracePeriod)) == .success else {
                return nil
            }
        }
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        let stderr = String(data: stderrData, encoding: .utf8) ?? ""
        return Self.bestErrorLine(stderr: stderr) ?? "status=\(process.terminationStatus)"
    }

    private static func which(_ executable: String) -> String? {
        let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
        for component in path.split(separator: ":") {
            let candidate = String(component) + "/" + executable
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }

    // MARK: - Platform mapping

    private static func mapUnameOS(_ raw: String) -> String? {
        switch raw.lowercased() {
        case "linux": return "linux"
        case "darwin": return "darwin"
        case "freebsd": return "freebsd"
        default: return nil
        }
    }

    private static func mapUnameArch(_ raw: String) -> String? {
        switch raw.lowercased() {
        case "x86_64", "amd64": return "amd64"
        case "aarch64", "arm64": return "arm64"
        case "armv7l": return "arm"
        default: return nil
        }
    }

    // MARK: - Error analysis

    private static func bestErrorLine(stderr: String, stdout: String = "") -> String? {
        if let stderrLine = meaningfulErrorLine(in: stderr) {
            return stderrLine
        }
        if let stdoutLine = meaningfulErrorLine(in: stdout) {
            return stdoutLine
        }
        return nil
    }

    private static func meaningfulErrorLine(in text: String) -> String? {
        let lines = text
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        for line in lines.reversed() where !isNoiseLine(line) {
            return line
        }
        return lines.last
    }

    private static func isNoiseLine(_ line: String) -> Bool {
        let lowered = line.lowercased()
        if lowered.hasPrefix("warning: permanently added") { return true }
        if lowered.hasPrefix("debug") { return true }
        if lowered.hasPrefix("transferred:") { return true }
        if lowered.hasPrefix("openbsd_") { return true }
        if lowered.contains("pseudo-terminal will not be allocated") { return true }
        return false
    }

    private static func shouldEscalateProxyErrorToBootstrap(_ detail: String) -> Bool {
        let lowered = detail.lowercased()
        return lowered.contains("remote daemon transport failed")
            || lowered.contains("daemon transport closed stdout")
            || lowered.contains("daemon transport exited")
            || lowered.contains("daemon transport is not connected")
            || lowered.contains("daemon transport stopped")
    }

    // MARK: - Retry suffix

    private static func retrySuffix(retry: Int, delay: TimeInterval) -> String {
        let seconds = max(1, Int(delay.rounded()))
        return " (retry \(retry) in \(seconds)s)"
    }

    // MARK: - Debug helpers

    private func debugLog(_ message: @autoclosure () -> String) {
#if DEBUG
        let msg = message()
        NSLog("[RemoteSessionController] %@", msg)
#endif
    }

    private func debugConfigSummary() -> String {
        "target=\(configuration.displayTarget) port=\(configuration.port.map(String.init) ?? "nil") " +
        "relayPort=\(configuration.relayPort.map(String.init) ?? "nil") " +
        "localSocket=\(configuration.localSocketPath ?? "nil")"
    }

    private func debugShellCommand(executable: String, arguments: [String]) -> String {
        ([URL(fileURLWithPath: executable).lastPathComponent] + arguments)
            .map(RemoteDaemonRPCClient.shellSingleQuoted)
            .joined(separator: " ")
    }

    private static func debugLogSnippet(_ text: String, limit: Int = 160) -> String {
        let normalized = text
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return "\"\"" }
        if normalized.count <= limit {
            return normalized
        }
        return String(normalized.prefix(limit)) + "..."
    }
}
