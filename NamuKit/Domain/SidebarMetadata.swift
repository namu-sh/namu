import Foundation

/// Metadata displayed in the sidebar for a workspace.
/// Pure value type — updated by shell integration and port scanner.
struct SidebarMetadata: Equatable {
    static func == (lhs: SidebarMetadata, rhs: SidebarMetadata) -> Bool {
        lhs.workingDirectory == rhs.workingDirectory &&
        lhs.gitBranch == rhs.gitBranch &&
        lhs.listeningPorts == rhs.listeningPorts &&
        lhs.shellState == rhs.shellState &&
        lhs.lastCommand == rhs.lastCommand &&
        lhs.lastExitCode == rhs.lastExitCode &&
        lhs.hasActivity == rhs.hasActivity &&
        lhs.progress == rhs.progress &&
        lhs.unreadCount == rhs.unreadCount &&
        lhs.progressLabel == rhs.progressLabel &&
        lhs.latestNotification == rhs.latestNotification &&
        lhs.latestLog == rhs.latestLog &&
        lhs.logLevel == rhs.logLevel &&
        lhs.isRemoteSSH == rhs.isRemoteSSH &&
        lhs.gitDirty == rhs.gitDirty &&
        lhs.pullRequests == rhs.pullRequests &&
        lhs.panelBranches == rhs.panelBranches &&
        lhs.metadataEntries.count == rhs.metadataEntries.count &&
        zip(lhs.metadataEntries, rhs.metadataEntries).allSatisfy { $0.0 == $1.0 && $0.1 == $1.1 } &&
        lhs.markdownBlocks == rhs.markdownBlocks &&
        lhs.remoteConnectionState == rhs.remoteConnectionState &&
        lhs.remoteDaemonStatus == rhs.remoteDaemonStatus &&
        lhs.remoteForwardedPorts == rhs.remoteForwardedPorts &&
        lhs.remoteProxyEndpoint == rhs.remoteProxyEndpoint &&
        lhs.remoteHeartbeatCount == rhs.remoteHeartbeatCount &&
        lhs.remoteLastHeartbeatAt == rhs.remoteLastHeartbeatAt &&
        lhs.remoteConnectionDetail == rhs.remoteConnectionDetail &&
        lhs.remoteDetectedPorts == rhs.remoteDetectedPorts &&
        lhs.remotePortConflicts == rhs.remotePortConflicts &&
        lhs.remoteConfiguration == rhs.remoteConfiguration &&
        lhs.activeRemoteTerminalSessionCount == rhs.activeRemoteTerminalSessionCount
    }
    var workingDirectory: String?
    var gitBranch: String?
    var listeningPorts: [PortInfo] = []
    var shellState: ShellState = .unknown
    var lastCommand: String?
    var lastExitCode: Int?

    // MARK: - Activity / progress

    /// Whether any pane in the workspace has a long-running command active.
    var hasActivity: Bool = false

    /// Optional fractional progress [0.0, 1.0] for the workspace's primary task.
    /// nil means indeterminate or no progress to show.
    var progress: Double? = nil

    /// Number of unread notifications for this workspace.
    var unreadCount: Int = 0

    /// Text label shown on the progress bar.
    var progressLabel: String?

    /// Latest notification subtitle text for display in sidebar.
    var latestNotification: String?

    /// Latest log entry from the terminal.
    var latestLog: String?

    /// Log level of the latest log entry (info, warn, error).
    var logLevel: String?

    /// Whether this workspace has an active SSH remote session.
    var isRemoteSSH: Bool = false

    // MARK: - Git enhanced state

    /// Whether the working tree has uncommitted changes.
    var gitDirty: Bool = false

    /// Pull requests associated with the current branch.
    var pullRequests: [PullRequestDisplay] = []

    /// Per-panel git branches (for split-pane workspaces with different repos).
    var panelBranches: [UUID: String] = [:]

    // MARK: - Custom metadata

    /// Arbitrary key-value pairs reported by shell integration.
    var metadataEntries: [(String, String)] = []

    /// Markdown blocks reported by shell integration for rich sidebar display.
    var markdownBlocks: [String] = []

    // MARK: - Remote SSH session state

    /// Human-readable connection state for the active SSH session (e.g. "connected", "reconnecting").
    /// Populated by shell integration when isRemoteSSH is true.
    var remoteConnectionState: String? = nil

    /// Status of the remote daemon (e.g. "running", "starting", "stopped").
    var remoteDaemonStatus: String? = nil

    /// Ports forwarded through the SSH tunnel for this session.
    var remoteForwardedPorts: [PortInfo]? = nil

    /// Proxy endpoint address used by the remote session (e.g. "127.0.0.1:2222").
    var remoteProxyEndpoint: String? = nil

    /// Cumulative heartbeat count received from the remote daemon since session start.
    var remoteHeartbeatCount: Int = 0

    /// Timestamp of the most recently received heartbeat from the remote daemon.
    var remoteLastHeartbeatAt: Date? = nil

    // MARK: - Remote SSH extended state (fields 7–9)

    /// Human-readable connection detail string, e.g. "user@host:port".
    var remoteConnectionDetail: String? = nil

    /// Ports detected as open/listening on the remote host.
    var remoteDetectedPorts: [PortInfo]? = nil

    /// Port conflict descriptions, e.g. ["Port 8080 already in use by nginx"].
    var remotePortConflicts: [String]? = nil

    // MARK: - Remote SSH extended state (fields 10–11)

    /// Typed configuration string describing the remote connection (e.g. "user@host:port via jump-host").
    var remoteConfiguration: String? = nil

    /// Number of active remote terminal sessions in this workspace.
    var activeRemoteTerminalSessionCount: Int = 0
}

/// A TCP/UDP port that a process in the workspace is listening on.
struct PortInfo: Equatable {
    var port: UInt16
    var processName: String?
}

// ShellState is defined in NamuKit/Terminal/ShellIntegration.swift

// MARK: - RemoteSessionService integration

extension SidebarMetadata {
    /// Populates remote fields from the current state held by RemoteSessionService.
    ///
    /// Existing field types (String?) are preserved for backward IPC/serialization compatibility.
    @MainActor
    mutating func updateRemoteState(from service: RemoteSessionService, workspaceID: UUID) {
        if let state = service.connectionStates[workspaceID] {
            remoteConnectionState = state.rawValue
            isRemoteSSH = (state == .connected || state == .connecting)
        }
        if let status = service.daemonStatuses[workspaceID] {
            remoteDaemonStatus = status.state.rawValue
        }
        if let endpoint = service.proxyEndpoints[workspaceID] {
            remoteProxyEndpoint = "\(endpoint.host):\(endpoint.port)"
        }
        if let heartbeat = service.heartbeats[workspaceID] {
            remoteHeartbeatCount = heartbeat.count
            remoteLastHeartbeatAt = heartbeat.lastSeenAt
        }
    }
}
