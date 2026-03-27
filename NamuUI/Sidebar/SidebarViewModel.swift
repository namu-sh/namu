import Combine
import Foundation
import SwiftUI

/// Represents the current sidebar selection — either a workspace or a non-workspace tab like Settings.
enum SidebarSelection: Equatable, Hashable {
    case workspace(UUID)
    case settings
}

/// Precomputed, value-typed snapshot of one workspace row.
/// SidebarItemView reads only these fields — no reactive subscriptions inside the item.
struct SidebarItemData: Equatable, Identifiable {
    let id: UUID
    let title: String
    let isSelected: Bool
    let isPinned: Bool
    let customColor: String?
    let panelCount: Int
    let gitBranch: String?
    let gitDirty: Bool
    let workingDirectory: String?
    let listeningPorts: [PortInfo]
    let shellState: ShellState
    let lastExitCode: Int?
    let notificationSubtitle: String?
    let progressLabel: String?
    let latestLog: String?
    let logLevel: String?
    let isRemoteSSH: Bool
    let pullRequests: [PullRequestDisplay]
    let panelBranches: [UUID: String]
    let metadataEntries: [(String, String)]
    let markdownBlocks: [String]

    static func == (lhs: SidebarItemData, rhs: SidebarItemData) -> Bool {
        lhs.id == rhs.id &&
        lhs.title == rhs.title &&
        lhs.isSelected == rhs.isSelected &&
        lhs.isPinned == rhs.isPinned &&
        lhs.customColor == rhs.customColor &&
        lhs.panelCount == rhs.panelCount &&
        lhs.gitBranch == rhs.gitBranch &&
        lhs.gitDirty == rhs.gitDirty &&
        lhs.workingDirectory == rhs.workingDirectory &&
        lhs.listeningPorts == rhs.listeningPorts &&
        lhs.shellState == rhs.shellState &&
        lhs.lastExitCode == rhs.lastExitCode &&
        lhs.notificationSubtitle == rhs.notificationSubtitle &&
        lhs.progressLabel == rhs.progressLabel &&
        lhs.latestLog == rhs.latestLog &&
        lhs.logLevel == rhs.logLevel &&
        lhs.isRemoteSSH == rhs.isRemoteSSH &&
        lhs.pullRequests == rhs.pullRequests &&
        lhs.panelBranches == rhs.panelBranches &&
        lhs.metadataEntries.count == rhs.metadataEntries.count &&
        zip(lhs.metadataEntries, rhs.metadataEntries).allSatisfy({ $0 == $1 }) &&
        lhs.markdownBlocks == rhs.markdownBlocks
    }
}

/// Bridges WorkspaceManager to the sidebar UI.
/// Coalesces rapid publishes so the sidebar redraws at most once per runloop turn.
///
/// `selection` is the single source of truth for which workspace/tab is active.
/// `WorkspaceManager.selectedWorkspaceID` is kept in sync as a side-effect.
@MainActor
final class SidebarViewModel: ObservableObject {
    @Published private(set) var items: [SidebarItemData] = []

    /// The single source of truth for sidebar selection.
    @Published var selection: SidebarSelection {
        didSet { selectionDidChange(oldValue: oldValue) }
    }

    /// Remembers the last workspace so settings can toggle back.
    private(set) var lastWorkspaceID: UUID

    private let workspaceManager: WorkspaceManager
    private weak var panelManager: PanelManager?
    private var cancellables = Set<AnyCancellable>()

    init(workspaceManager: WorkspaceManager, panelManager: PanelManager? = nil) {
        self.workspaceManager = workspaceManager
        self.panelManager = panelManager
        let initialID = workspaceManager.selectedWorkspaceID ?? workspaceManager.workspaces.first!.id
        self.selection = .workspace(initialID)
        self.lastWorkspaceID = initialID
        observeManager()
        observeNotifications()
        rebuildItems()
        // Force sync on next runloop to ensure initial selection is visible
        DispatchQueue.main.async { [weak self] in
            self?.workspaceManager.selectWorkspace(id: initialID)
            self?.rebuildItems()
        }
    }

    // MARK: - Actions

    func selectWorkspace(id: UUID) {
        selection = .workspace(id)
    }

    func openSettings() {
        if selection == .settings {
            selection = .workspace(lastWorkspaceID)
        } else {
            selection = .settings
        }
    }

    func renameWorkspace(id: UUID, title: String) {
        workspaceManager.renameWorkspace(id: id, title: title)
    }

    func togglePin(id: UUID) {
        workspaceManager.pinWorkspace(id: id)
    }

    func closeWorkspace(id: UUID) {
        workspaceManager.deleteWorkspace(id: id)
    }

    func setColor(_ color: String?, for id: UUID) {
        workspaceManager.setWorkspaceColor(id: id, color: color)
    }

    func createWorkspace() {
        workspaceManager.createWorkspace()
    }

    func moveWorkspace(from source: IndexSet, to destination: Int) {
        workspaceManager.reorderWorkspace(from: source, to: destination)
    }

    // MARK: - Private

    /// Sync WorkspaceManager and rebuild items whenever selection changes.
    private func selectionDidChange(oldValue: SidebarSelection) {
        switch selection {
        case .workspace(let id):
            lastWorkspaceID = id
            workspaceManager.selectWorkspace(id: id)
        case .settings:
            break
        }
        rebuildItems()
    }

    private func observeManager() {
        // Debounce rapid publishes (e.g. multiple @Published properties firing in
        // one keystroke cycle) into a single sidebar redraw per runloop turn.
        workspaceManager.objectWillChange
            .debounce(for: .zero, scheduler: RunLoop.main)
            .sink { [weak self] _ in
                self?.rebuildItems()
            }
            .store(in: &cancellables)

        // Also observe panel manager for terminal title changes.
        panelManager?.objectWillChange
            .debounce(for: .milliseconds(100), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                self?.rebuildItems()
            }
            .store(in: &cancellables)
    }

    private func observeNotifications() {
        NotificationCenter.default.publisher(for: .selectWorkspace)
            .receive(on: RunLoop.main)
            .sink { [weak self] notification in
                if let id = notification.userInfo?["id"] as? UUID {
                    self?.selection = .workspace(id)
                }
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .openSettings)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.openSettings()
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .namuNotificationCreated)
            .receive(on: RunLoop.main)
            .sink { [weak self] notification in
                guard let self else { return }
                let wsID = notification.userInfo?["workspace_id"] as? UUID
                    ?? self.workspaceManager.selectedWorkspaceID
                guard let wsID else { return }
                let body = notification.userInfo?["body"] as? String ?? ""
                var meta = self.metadataCache[wsID] ?? SidebarMetadata()
                meta.latestNotification = body
                meta.unreadCount += 1
                self.metadataCache[wsID] = meta
                self.rebuildItems()
            }
            .store(in: &cancellables)

        // Terminal OSC notifications — sidebar metadata update only.
        // Suppression + sound + desktop notification handled by NotificationService.
        NotificationCenter.default.publisher(for: .namuTerminalNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] notification in
                guard let self else { return }
                let title = notification.userInfo?["title"] as? String ?? ""
                let body = notification.userInfo?["body"] as? String ?? ""
                let displayText = body.isEmpty ? title : body

                // Skip sidebar update for Claude panes (their notifications come via hooks).
                let wsID = self.workspaceManager.selectedWorkspaceID
                if let wsID, let ws = self.workspaceManager.workspaces.first(where: { $0.id == wsID }),
                   ws.claudeSessionPID != nil {
                    return
                }

                guard let wsID else { return }
                var meta = self.metadataCache[wsID] ?? SidebarMetadata()
                meta.latestNotification = displayText
                meta.unreadCount += 1
                self.metadataCache[wsID] = meta
                self.rebuildItems()
            }
            .store(in: &cancellables)
    }

    /// Rebuild sidebar items using the current `selection` so workspace
    /// highlight state reflects the generalized selection model.
    func rebuildItems() {
        let sel = selection
        // Pinned workspaces sort to top, then by order within each group.
        let sorted = workspaceManager.workspaces.sorted {
            if $0.isPinned != $1.isPinned { return $0.isPinned }
            return $0.order < $1.order
        }
        items = sorted.map { workspace in
            let meta = metadataCache[workspace.id]
            let isSelected = sel == .workspace(workspace.id)

            return SidebarItemData(
                id: workspace.id,
                title: workspace.title,
                isSelected: isSelected,
                isPinned: workspace.isPinned,
                customColor: workspace.customColor,
                panelCount: workspace.panelCount,
                gitBranch: meta?.gitBranch,
                gitDirty: meta?.gitDirty ?? false,
                workingDirectory: meta?.workingDirectory,
                listeningPorts: meta?.listeningPorts ?? [],
                shellState: meta?.shellState ?? .unknown,
                lastExitCode: meta?.lastExitCode,
                notificationSubtitle: meta?.latestNotification,
                progressLabel: meta?.progressLabel,
                latestLog: meta?.latestLog,
                logLevel: meta?.logLevel,
                isRemoteSSH: meta?.isRemoteSSH ?? false,
                pullRequests: meta?.pullRequests ?? [],
                panelBranches: meta?.panelBranches ?? [:],
                metadataEntries: meta?.metadataEntries ?? [],
                markdownBlocks: meta?.markdownBlocks ?? []
            )
        }
    }

    // MARK: - Shell integration metadata

    /// Called by PanelManager or shell integration when a workspace's metadata changes.
    func updateMetadata(_ metadata: SidebarMetadata, for workspaceID: UUID) {
        metadataCache[workspaceID] = metadata
        rebuildItems()
    }

    /// Returns the current metadata for a workspace, or a default if none exists.
    func currentMetadata(for workspaceID: UUID) -> SidebarMetadata {
        metadataCache[workspaceID] ?? SidebarMetadata()
    }

    private var metadataCache: [UUID: SidebarMetadata] = [:]
}
