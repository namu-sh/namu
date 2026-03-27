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
        lhs.markdownBlocks == rhs.markdownBlocks
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
}

/// A TCP/UDP port that a process in the workspace is listening on.
struct PortInfo: Equatable {
    var port: UInt16
    var processName: String?
}

// ShellState is defined in NamuKit/Terminal/ShellIntegration.swift
