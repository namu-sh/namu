import Foundation
import Combine

// MARK: - RemoteSessionService

/// Owns per-workspace remote session controllers and publishes state updates for UI consumption.
///
/// Workspace is a lightweight struct, so this service is the single source of truth for all
/// per-workspace remote session state.
@MainActor
final class RemoteSessionService: ObservableObject {

    // MARK: - Per-workspace controller storage

    private var controllers: [UUID: RemoteSessionController] = [:]
    private var configurations: [UUID: RemoteConfiguration] = [:]

    /// Maps controller.controllerID → workspaceID so delegate callbacks can resolve the workspace
    /// without requiring RemoteSessionController to carry a workspaceID property.
    private var controllerWorkspaceMap: [UUID: UUID] = [:]

    // MARK: - Published state

    @Published var connectionStates: [UUID: RemoteConnectionState] = [:]
    @Published var daemonStatuses: [UUID: RemoteDaemonStatus] = [:]
    @Published var proxyEndpoints: [UUID: RemoteProxyEndpoint] = [:]
    @Published var heartbeats: [UUID: (count: Int, lastSeenAt: Date?)] = [:]

    // MARK: - Public API

    /// Configure (or reconfigure) the remote connection for a workspace.
    ///
    /// - Parameters:
    ///   - workspaceID: The workspace whose remote session to configure.
    ///   - configuration: SSH/proxy parameters for the connection.
    ///   - autoConnect: When true, `start()` is called immediately after creating the controller.
    func configureRemoteConnection(
        workspaceID: UUID,
        configuration: RemoteConfiguration,
        autoConnect: Bool = true
    ) {
        // Tear down any existing controller for this workspace first.
        teardownController(for: workspaceID)

        configurations[workspaceID] = configuration

        let controller = RemoteSessionController(configuration: configuration)
        controller.delegate = self
        controllers[workspaceID] = controller
        controllerWorkspaceMap[controller.controllerID] = workspaceID

        // Seed published state so observers see a "connecting" state immediately.
        connectionStates[workspaceID] = .connecting

        if autoConnect {
            controller.start()
        }
    }

    /// Tear down the current controller and create a fresh one, then start it.
    func reconnectRemoteConnection(workspaceID: UUID) {
        guard let configuration = configurations[workspaceID] else { return }
        configureRemoteConnection(workspaceID: workspaceID, configuration: configuration, autoConnect: true)
    }

    /// Stop and remove the remote controller for a workspace.
    ///
    /// - Parameters:
    ///   - workspaceID: The workspace to disconnect.
    ///   - clearConfiguration: When true, also removes the stored `RemoteConfiguration`.
    func disconnectRemoteConnection(workspaceID: UUID, clearConfiguration: Bool = false) {
        teardownController(for: workspaceID)
        clearPublishedState(for: workspaceID)
        if clearConfiguration {
            configurations.removeValue(forKey: workspaceID)
        }
    }

    /// Returns true when the given workspace has an active remote session controller.
    func isRemoteWorkspace(_ workspaceID: UUID) -> Bool {
        controllers[workspaceID] != nil
    }

    /// Returns an IPC-friendly dictionary of the current remote state for the given workspace.
    /// Returns nil when no remote session is configured for the workspace.
    func remoteStatusPayload(workspaceID: UUID) -> [String: Any]? {
        guard isRemoteWorkspace(workspaceID) else { return nil }

        var payload: [String: Any] = [:]

        if let state = connectionStates[workspaceID] {
            payload["connection_state"] = state.rawValue
        }

        if let daemonStatus = daemonStatuses[workspaceID] {
            payload["daemon_status"] = daemonStatus.payload()
        }

        if let endpoint = proxyEndpoints[workspaceID] {
            payload["proxy_endpoint"] = ["host": endpoint.host, "port": endpoint.port]
        }

        if let heartbeat = heartbeats[workspaceID] {
            var hb: [String: Any] = ["count": heartbeat.count]
            if let lastSeenAt = heartbeat.lastSeenAt {
                hb["last_seen_at"] = lastSeenAt.timeIntervalSince1970
            }
            payload["heartbeat"] = hb
        }

        return payload
    }

    /// Upload dropped files to the remote host via the active controller.
    func uploadDroppedFiles(
        workspaceID: UUID,
        fileURLs: [URL],
        operation: String,
        completion: @escaping (Result<Void, RemoteDropUploadError>) -> Void
    ) {
        guard let controller = controllers[workspaceID] else {
            completion(.failure(.unavailable))
            return
        }
        controller.uploadFiles(fileURLs, operation: operation, completion: completion)
    }

    /// Forward a terminal resize to the remote daemon for PTY coordination.
    /// Called by PanelManager or TerminalSession when a remote workspace panel resizes.
    func notifyResize(workspaceID: UUID, sessionID: String, cols: Int, rows: Int) {
        guard let controller = controllers[workspaceID] else { return }
        controller.notifyResize(sessionID: sessionID, cols: cols, rows: rows)
    }

    /// Called when a workspace is deleted — cleans up all remote resources for that workspace.
    func workspaceDidDelete(_ workspaceID: UUID) {
        disconnectRemoteConnection(workspaceID: workspaceID, clearConfiguration: true)
    }

    // MARK: - Private helpers

    private func teardownController(for workspaceID: UUID) {
        guard let controller = controllers[workspaceID] else { return }
        controller.delegate = nil
        controller.stop()
        controllerWorkspaceMap.removeValue(forKey: controller.controllerID)
        controllers.removeValue(forKey: workspaceID)
    }

    private func clearPublishedState(for workspaceID: UUID) {
        connectionStates.removeValue(forKey: workspaceID)
        daemonStatuses.removeValue(forKey: workspaceID)
        proxyEndpoints.removeValue(forKey: workspaceID)
        heartbeats.removeValue(forKey: workspaceID)
    }
}

// MARK: - RemoteSessionControllerDelegate conformance

extension RemoteSessionService: RemoteSessionControllerDelegate {

    /// Called from controller threads — dispatches to @MainActor for published-state mutation.
    nonisolated func remoteSession(
        _ controller: RemoteSessionController,
        didUpdateConnectionState state: RemoteConnectionState,
        detail: String?
    ) {
        let controllerID = controller.controllerID
        Task { @MainActor [weak self] in
            guard let self, let workspaceID = controllerWorkspaceMap[controllerID] else { return }
            connectionStates[workspaceID] = state
        }
    }

    nonisolated func remoteSession(
        _ controller: RemoteSessionController,
        didUpdateDaemonStatus status: RemoteDaemonStatus
    ) {
        let controllerID = controller.controllerID
        Task { @MainActor [weak self] in
            guard let self, let workspaceID = controllerWorkspaceMap[controllerID] else { return }
            daemonStatuses[workspaceID] = status
        }
    }

    nonisolated func remoteSession(
        _ controller: RemoteSessionController,
        didUpdateProxyEndpoint endpoint: RemoteProxyEndpoint?
    ) {
        let controllerID = controller.controllerID
        Task { @MainActor [weak self] in
            guard let self, let workspaceID = controllerWorkspaceMap[controllerID] else { return }
            if let endpoint {
                proxyEndpoints[workspaceID] = endpoint
            } else {
                proxyEndpoints.removeValue(forKey: workspaceID)
            }
        }
    }

    nonisolated func remoteSession(
        _ controller: RemoteSessionController,
        didUpdateHeartbeat count: Int,
        lastSeenAt: Date?
    ) {
        let controllerID = controller.controllerID
        Task { @MainActor [weak self] in
            guard let self, let workspaceID = controllerWorkspaceMap[controllerID] else { return }
            heartbeats[workspaceID] = (count: count, lastSeenAt: lastSeenAt)
        }
    }

    nonisolated func remoteSession(
        _ controller: RemoteSessionController,
        didEncounterError message: String
    ) {
        let controllerID = controller.controllerID
        Task { @MainActor [weak self] in
            guard let self, let workspaceID = controllerWorkspaceMap[controllerID] else { return }
            connectionStates[workspaceID] = .error
        }
    }
}
