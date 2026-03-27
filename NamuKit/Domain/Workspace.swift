import Foundation

/// A named unit of work shown as a tab in the sidebar.
/// Pure value type — no UI dependencies.
struct Workspace: Identifiable, Codable, Equatable {
    let id: UUID
    var title: String
    var order: Int
    var isPinned: Bool
    var createdAt: Date
    /// Optional accent color for this workspace, stored as a hex string (e.g. "#FF6B6B").
    var customColor: String?

    /// User-set custom title. When set, overrides processTitle for display.
    var customTitle: String?
    /// Title from the active terminal's running process (e.g. "vim", "zsh", "~/dev/namu").
    /// Not persisted — transient state rebuilt from terminal.
    var processTitle: String = ""

    /// PID of an active Claude Code session in this workspace (transient, not persisted).
    /// Set by the session-start hook, cleared by session-end.
    /// Used to suppress duplicate OSC notifications when Claude hooks handle them.
    var claudeSessionPID: String?

    /// The layout tree for this workspace's panes.
    var paneTree: PaneTree

    /// The panel currently receiving keyboard input.
    var activePanelID: UUID?

    /// Pane IDs that have unread notifications (flash/badge). Multiple panes can have attention.
    /// Cleared when the pane becomes active (user clicks it).
    /// Transient state — not persisted.
    var attentionPanelIDs: Set<UUID> = []

    // MARK: - Codable

    enum CodingKeys: String, CodingKey {
        case id, title, order, isPinned, createdAt, customColor, customTitle, paneTree, activePanelID
    }

    // MARK: - Computed properties

    /// Total number of panels in the workspace.
    var panelCount: Int {
        paneTree.paneCount
    }

    /// Flat list of all panel leaves in the workspace.
    var allPanels: [PaneLeaf] {
        paneTree.allPanels
    }

    // MARK: - Title management

    /// Update the title from the terminal process. Only takes effect if no custom title is set.
    mutating func applyProcessTitle(_ newTitle: String) {
        // Ignore placeholder titles that aren't real process names.
        let dominated = ["Terminal", "terminal", ""]
        guard !dominated.contains(newTitle) else { return }
        processTitle = newTitle
        guard customTitle == nil else { return }
        title = Self.displayTitle(from: newTitle)
    }

    /// Clean up a raw process title for sidebar display.
    /// Full paths become basenames, home dir becomes ~.
    private static func displayTitle(from raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return trimmed }

        let home = FileManager.default.homeDirectoryForCurrentUser.path
        // If it's exactly the home directory, show ~
        if trimmed == home { return "~" }
        // If it's an absolute path, show the last component
        if trimmed.hasPrefix("/") {
            let basename = (trimmed as NSString).lastPathComponent
            return basename.isEmpty ? trimmed : basename
        }
        // If it starts with ~/, show from ~ with basename
        if trimmed.hasPrefix("~/") || trimmed == "~" {
            return (trimmed as NSString).lastPathComponent
        }
        return trimmed
    }

    /// Set a user-chosen custom title. Pass nil to revert to process title.
    mutating func setCustomTitle(_ newTitle: String?) {
        let trimmed = newTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmed.isEmpty {
            customTitle = nil
            title = processTitle.isEmpty ? String(localized: "workspace.default.title", defaultValue: "New Workspace") : processTitle
        } else {
            customTitle = trimmed
            title = trimmed
        }
    }

    // MARK: - Init

    init(
        id: UUID = UUID(),
        title: String = String(localized: "workspace.default.title", defaultValue: "New Workspace"),
        order: Int = 0,
        isPinned: Bool = false,
        createdAt: Date = Date(),
        customColor: String? = nil,
        paneTree: PaneTree? = nil,
        activePanelID: UUID? = nil
    ) {
        self.id = id
        self.title = title
        self.order = order
        self.isPinned = isPinned
        self.createdAt = createdAt
        self.customColor = customColor
        let initialLeaf = PaneLeaf()
        let tree = paneTree ?? .pane(initialLeaf)
        self.paneTree = tree
        self.activePanelID = activePanelID ?? {
            // Default active panel to the first panel in the provided (or new) tree
            if case .pane(let leaf) = tree { return leaf.id }
            return tree.allPanels.first?.id
        }()
    }
}
