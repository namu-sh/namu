import Foundation

/// Snapshot of a single window's state — its ordered workspaces.
struct WindowSnapshot: Codable {
    let windowID: UUID
    var workspaces: [WorkspaceSnapshot]
    var selectedWorkspaceID: UUID?
    /// Window frame as [x, y, width, height] in screen coordinates.
    var windowFrame: [Double]?
    /// Whether the sidebar was collapsed when the snapshot was taken.
    var sidebarCollapsed: Bool?
    /// Sidebar width in points when visible.
    var sidebarWidth: Double?

    enum CodingKeys: String, CodingKey {
        case windowID = "windowId"
        case workspaces
        case selectedWorkspaceID = "selectedWorkspaceId"
        case windowFrame
        case sidebarCollapsed
        case sidebarWidth
    }
}

/// Snapshot of the full application state for session persistence.
/// Version field enables future schema migrations.
///
/// v1: single flat workspaces array (single-window era)
/// v2: windows array of WindowSnapshot; v1 snapshots auto-migrated to one-window array
struct SessionSnapshot: Codable {
    static let currentVersion: UInt = 4

    let version: UInt
    let timestamp: Date
    /// Multi-window snapshot (v2+). Populated on encode; decoded on restore.
    var windows: [WindowSnapshot]

    // MARK: - Legacy v1 fields (decode-only for migration)

    enum CodingKeys: String, CodingKey {
        case version
        case timestamp
        case windows
        // v1 legacy keys:
        case workspaces
        case selectedWorkspaceID = "selectedWorkspaceId"
    }

    init(windows: [WindowSnapshot] = []) {
        self.version = Self.currentVersion
        self.timestamp = Date()
        self.windows = windows
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(UInt.self, forKey: .version)
        timestamp = try container.decode(Date.self, forKey: .timestamp)

        if container.contains(.windows) {
            // v2+ path
            windows = try container.decode([WindowSnapshot].self, forKey: .windows)
        } else {
            // v1 migration: wrap single workspace list in one window
            let workspaces = try container.decodeIfPresent([WorkspaceSnapshot].self, forKey: .workspaces) ?? []
            let selectedID = try container.decodeIfPresent(UUID.self, forKey: .selectedWorkspaceID)
            let win = WindowSnapshot(windowID: UUID(), workspaces: workspaces, selectedWorkspaceID: selectedID)
            windows = [win]
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(version, forKey: .version)
        try container.encode(timestamp, forKey: .timestamp)
        try container.encode(windows, forKey: .windows)
    }

    /// Apply any schema migrations needed to bring an older snapshot up to the current version.
    /// Returns a migrated copy, or nil if the version is unrecognized and cannot be migrated.
    func migrated() -> SessionSnapshot? {
        guard version <= Self.currentVersion else { return nil }
        // v1→v2 migration is handled in init(from:) above.
        // v2→v3 migration: panelIds defaults to [id] when nil (handled by PaneSnapshot decode).
        // v3→v4 migration: new optional fields decode as nil automatically; no transform needed.
        return self
    }
}

/// Snapshot of a single workspace and its pane tree layout.
struct WorkspaceSnapshot: Codable, Identifiable {
    let id: UUID
    var title: String
    var order: Int
    var isPinned: Bool
    var customTitle: String?
    var processTitle: String?
    var customColor: String?
    var layout: WorkspaceLayoutSnapshot
    var activePanelID: UUID?
    // v4: deeper workspace state
    var currentDirectory: String?
    var gitBranch: GitBranchSnapshot?
    var statusEntries: [StatusEntrySnapshot]?
    var logEntries: [LogEntrySnapshot]?
    var progress: ProgressSnapshot?

    enum CodingKeys: String, CodingKey {
        case id
        case title
        case order
        case isPinned
        case customTitle
        case processTitle
        case customColor
        case layout
        case activePanelID = "activePanelId"
        case currentDirectory
        case gitBranch
        case statusEntries
        case logEntries
        case progress
    }
}

// MARK: - Sidebar metadata snapshots (v4)

struct GitBranchSnapshot: Codable {
    var branch: String
    var isDirty: Bool
}

struct StatusEntrySnapshot: Codable {
    var key: String
    var value: String
    var icon: String?
    var color: String?
    var timestamp: TimeInterval
}

struct LogEntrySnapshot: Codable {
    var message: String
    var level: String
    var source: String?
    var timestamp: TimeInterval
}

struct ProgressSnapshot: Codable {
    var value: Double
    var label: String?
}

/// Recursive layout snapshot matching PaneTree structure.
/// Uses an explicit type discriminator for stable JSON encoding.
indirect enum WorkspaceLayoutSnapshot: Codable {
    case pane(PaneSnapshot)
    case split(SplitSnapshot)

    private enum CodingKeys: String, CodingKey {
        case type
        case pane
        case split
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "pane":
            self = .pane(try container.decode(PaneSnapshot.self, forKey: .pane))
        case "split":
            self = .split(try container.decode(SplitSnapshot.self, forKey: .split))
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type,
                in: container,
                debugDescription: "Unsupported layout node type: \(type)"
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .pane(let pane):
            try container.encode("pane", forKey: .type)
            try container.encode(pane, forKey: .pane)
        case .split(let split):
            try container.encode("split", forKey: .type)
            try container.encode(split, forKey: .split)
        }
    }
}

/// Snapshot of a leaf pane — holds the panel type and optional restore data.
/// v3 adds panelIds (tab support) and selectedPanelId.
/// v4 adds gitDirty, listeningPorts for immediate sidebar display on restore.
struct PaneSnapshot: Codable {
    let id: UUID
    var panelType: PanelType
    var workingDirectory: String?
    var scrollbackFile: String?
    var gitBranch: String?
    var customTitle: String?
    var browserURL: String?
    var browserZoom: Double?
    var browserDevToolsVisible: Bool?
    var browserBackHistory: [String]?
    var browserForwardHistory: [String]?
    var panelIds: [UUID]?
    var selectedPanelId: UUID?
    var browserProfileID: String?
    var browserShouldRender: Bool?
    var isPinned: Bool?
    // v4: deeper panel state
    var gitDirty: Bool?
    var listeningPorts: [UInt16]?

    enum CodingKeys: String, CodingKey {
        case id
        case panelType
        case workingDirectory
        case scrollbackFile
        case gitBranch
        case customTitle
        case browserURL
        case browserZoom
        case browserDevToolsVisible
        case browserBackHistory
        case browserForwardHistory
        case panelIds
        case selectedPanelId
        case browserProfileID
        case browserShouldRender
        case isPinned
        case gitDirty
        case listeningPorts
    }
}

/// Snapshot of a split node — two children divided along an axis.
struct SplitSnapshot: Codable {
    let id: UUID
    var direction: SplitDirection
    var ratio: Double
    var first: WorkspaceLayoutSnapshot
    var second: WorkspaceLayoutSnapshot

    enum CodingKeys: String, CodingKey {
        case id
        case direction
        case ratio
        case first
        case second
    }
}
