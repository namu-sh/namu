import Foundation

// MARK: - Config File

/// Root structure of a namu.json config file.
struct NamuConfigFile: Codable, Sendable, Equatable {
    var commands: [CommandDefinition] = []
}

// MARK: - Command Definition

/// A user-defined command that appears in the command palette.
/// Either `command` (shell) or `workspace` (layout) must be set, not both.
struct CommandDefinition: Codable, Sendable, Equatable, Identifiable {
    let name: String
    var description: String?
    var keywords: [String]?
    var command: String?
    var workspace: WorkspaceLayoutDefinition?
    var confirm: Bool?
    var restart: RestartBehavior?

    var id: String { name }

    init(
        name: String,
        description: String? = nil,
        keywords: [String]? = nil,
        command: String? = nil,
        workspace: WorkspaceLayoutDefinition? = nil,
        confirm: Bool? = nil,
        restart: RestartBehavior? = nil
    ) {
        self.name = name
        self.description = description
        self.keywords = keywords
        self.command = command
        self.workspace = workspace
        self.confirm = confirm
        self.restart = restart
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        description = try container.decodeIfPresent(String.self, forKey: .description)
        keywords = try container.decodeIfPresent([String].self, forKey: .keywords)
        command = try container.decodeIfPresent(String.self, forKey: .command)
        workspace = try container.decodeIfPresent(WorkspaceLayoutDefinition.self, forKey: .workspace)
        confirm = try container.decodeIfPresent(Bool.self, forKey: .confirm)
        restart = try container.decodeIfPresent(RestartBehavior.self, forKey: .restart)

        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "Command name must not be blank"
            ))
        }
        if let cmd = command, cmd.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "Command '\(name)' has blank 'command'"
            ))
        }
        if workspace != nil && command != nil {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "Command '\(name)' must not define both 'workspace' and 'command'"
            ))
        }
        if workspace == nil && command == nil {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "Command '\(name)' must define either 'workspace' or 'command'"
            ))
        }
    }

    /// Whether this command matches a fuzzy search query.
    func matches(query: String) -> Bool {
        let q = query.lowercased()
        if name.lowercased().contains(q) { return true }
        if description?.lowercased().contains(q) == true { return true }
        if keywords?.contains(where: { $0.lowercased().contains(q) }) == true { return true }
        return false
    }
}

// MARK: - Restart Behavior

enum RestartBehavior: String, Codable, Sendable {
    /// Close the existing workspace and create a new one.
    case recreate
    /// Do nothing if a workspace with this command's name already exists.
    case ignore
    /// Ask the user before restarting.
    case confirm
}

// MARK: - Workspace Layout Definition

/// Defines a workspace layout with optional splits.
struct WorkspaceLayoutDefinition: Codable, Sendable, Equatable {
    var name: String?
    var cwd: String?
    var color: String?
    var layout: LayoutNode?
}

/// Recursive layout node for defining split pane arrangements.
indirect enum LayoutNode: Codable, Sendable, Equatable {
    case terminal(TerminalNodeDefinition)
    case split(SplitNodeDefinition)

    struct TerminalNodeDefinition: Codable, Sendable, Equatable {
        var command: String?
        var cwd: String?
    }

    struct SplitNodeDefinition: Codable, Sendable, Equatable {
        var direction: String // "horizontal" or "vertical"
        var ratio: Double?
        var first: LayoutNode
        var second: LayoutNode
    }

    enum CodingKeys: String, CodingKey {
        case type, terminal, split
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "terminal":
            let def = try container.decodeIfPresent(TerminalNodeDefinition.self, forKey: .terminal) ?? TerminalNodeDefinition()
            self = .terminal(def)
        case "split":
            let def = try container.decode(SplitNodeDefinition.self, forKey: .split)
            self = .split(def)
        default:
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "Unknown layout type '\(type)'"
            ))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .terminal(let def):
            try container.encode("terminal", forKey: .type)
            try container.encode(def, forKey: .terminal)
        case .split(let def):
            try container.encode("split", forKey: .type)
            try container.encode(def, forKey: .split)
        }
    }
}
