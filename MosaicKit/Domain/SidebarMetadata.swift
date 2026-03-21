import Foundation

/// Metadata displayed in the sidebar for a workspace.
/// Pure value type — updated by shell integration and port scanner.
struct SidebarMetadata: Equatable {
    var workingDirectory: String?
    var gitBranch: String?
    var listeningPorts: [PortInfo] = []
    var shellState: ShellState = .unknown
    var lastCommand: String?
    var lastExitCode: Int?
}

/// A TCP/UDP port that a process in the workspace is listening on.
struct PortInfo: Equatable {
    var port: UInt16
    var processName: String?
}

// ShellState is defined in MosaicKit/Terminal/ShellIntegration.swift
