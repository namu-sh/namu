import Foundation

/// Snapshot of the full application state for session persistence.
/// Version field enables future schema migrations.
struct SessionSnapshot: Codable {
    static let currentVersion: UInt = 1

    let version: UInt
    let timestamp: Date
    var workspaces: [WorkspaceSnapshot]
    var selectedWorkspaceID: UUID?

    enum CodingKeys: String, CodingKey {
        case version
        case timestamp
        case workspaces
        case selectedWorkspaceID = "selectedWorkspaceId"
    }

    init(
        workspaces: [WorkspaceSnapshot] = [],
        selectedWorkspaceID: UUID? = nil
    ) {
        self.version = Self.currentVersion
        self.timestamp = Date()
        self.workspaces = workspaces
        self.selectedWorkspaceID = selectedWorkspaceID
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(UInt.self, forKey: .version)
        timestamp = try container.decode(Date.self, forKey: .timestamp)
        workspaces = try container.decode([WorkspaceSnapshot].self, forKey: .workspaces)
        selectedWorkspaceID = try container.decodeIfPresent(UUID.self, forKey: .selectedWorkspaceID)
    }

    /// Apply any schema migrations needed to bring an older snapshot up to the current version.
    /// Returns a migrated copy, or nil if the version is unrecognized and cannot be migrated.
    func migrated() -> SessionSnapshot? {
        guard version <= Self.currentVersion else { return nil }
        // v1 is the initial version — nothing to migrate yet.
        return self
    }
}

/// Snapshot of a single workspace and its pane tree layout.
struct WorkspaceSnapshot: Codable, Identifiable {
    let id: UUID
    var title: String
    var order: Int
    var isPinned: Bool
    var layout: WorkspaceLayoutSnapshot
    var focusedPanelID: UUID?

    enum CodingKeys: String, CodingKey {
        case id
        case title
        case order
        case isPinned
        case layout
        case focusedPanelID = "focusedPanelId"
    }
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
struct PaneSnapshot: Codable {
    let id: UUID
    var panelType: PanelType
    var workingDirectory: String?
    /// Path to a temp file containing scrollback content for replay on restore.
    var scrollbackFile: String?

    enum CodingKeys: String, CodingKey {
        case id
        case panelType
        case workingDirectory
        case scrollbackFile
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
