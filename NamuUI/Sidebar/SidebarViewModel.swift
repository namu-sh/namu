import Combine
import Foundation
import SwiftUI

/// Represents the current sidebar selection — either a workspace or a non-workspace tab like Settings.
enum SidebarSelection: Equatable, Hashable {
    case workspace(UUID)
    case settings
    case notifications
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
    let lastCommand: String?
    let unreadCount: Int
    let notificationSubtitle: String?
    let progressLabel: String?
    let latestLog: String?
    let logLevel: String?
    let isRemoteSSH: Bool
    let remoteConnectionDetail: String?
    let remoteConnectionState: String?
    let remoteForwardedPorts: [PortInfo]?
    let pullRequests: [PullRequestDisplay]
    let panelBranches: [UUID: String]
    let metadataEntries: [(String, String)]
    let statusEntries: [String: SidebarStatusEntry]
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
        lhs.lastCommand == rhs.lastCommand &&
        lhs.unreadCount == rhs.unreadCount &&
        lhs.notificationSubtitle == rhs.notificationSubtitle &&
        lhs.progressLabel == rhs.progressLabel &&
        lhs.latestLog == rhs.latestLog &&
        lhs.logLevel == rhs.logLevel &&
        lhs.isRemoteSSH == rhs.isRemoteSSH &&
        lhs.remoteConnectionDetail == rhs.remoteConnectionDetail &&
        lhs.remoteConnectionState == rhs.remoteConnectionState &&
        lhs.remoteForwardedPorts == rhs.remoteForwardedPorts &&
        lhs.pullRequests == rhs.pullRequests &&
        lhs.panelBranches == rhs.panelBranches &&
        lhs.metadataEntries.count == rhs.metadataEntries.count &&
        zip(lhs.metadataEntries, rhs.metadataEntries).allSatisfy({ $0 == $1 }) &&
        lhs.statusEntries == rhs.statusEntries &&
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

    /// Mirrors NotificationService.unreadCount for the bell badge.
    @Published private(set) var notificationUnreadCount: Int = 0

    /// Remembers the last workspace so settings can toggle back.
    private(set) var lastWorkspaceID: UUID

    private let workspaceManager: WorkspaceManager
    private weak var panelManager: PanelManager?
    private weak var notificationService: NotificationService?
    private var cancellables = Set<AnyCancellable>()
    private var notificationCancellable: AnyCancellable?

    /// Windows available for cross-window workspace moves (populated by ContentView).
    /// Each entry is (windowID, display title).
    var availableWindows: [(id: UUID, title: String)] = []

    /// Called when the user picks "Move to Window" from the context menu.
    /// Set by ContentView to delegate to AppDelegate.
    var onMoveWorkspaceToWindow: ((UUID, UUID) -> Void)? // (workspaceID, targetWindowID)

    /// Remote session service for SSH reconnect/disconnect actions.
    /// Set by the owning view/container after init.
    weak var remoteSessionService: RemoteSessionService?

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

    func toggleNotifications() {
        if selection == .notifications {
            selection = .workspace(lastWorkspaceID)
        } else {
            selection = .notifications
        }
    }

    /// Wire up a NotificationService so the bell badge stays current.
    func setNotificationService(_ service: NotificationService) {
        self.notificationService = service
        notificationUnreadCount = service.unreadCount
        notificationCancellable = service.$allNotifications
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.notificationUnreadCount = service.unreadCount
                self.rebuildItems()
            }
    }

    func renameWorkspace(id: UUID, title: String) {
        workspaceManager.renameWorkspace(id: id, title: title)
    }

    func togglePin(id: UUID) {
        workspaceManager.pinWorkspace(id: id)
    }

    func closeWorkspace(id: UUID) {
        panelManager?.deleteWorkspace(id: id)
    }

    func setColor(_ color: String?, for id: UUID) {
        workspaceManager.setWorkspaceColor(id: id, color: color)
    }

    func createWorkspace() {
        panelManager?.createWorkspace()
    }

    /// Tear down and restart the SSH connection for a remote workspace.
    func reconnectSSH(workspaceID: UUID) {
        remoteSessionService?.reconnectRemoteConnection(workspaceID: workspaceID)
    }

    /// Disconnect (but do not remove) the SSH session for a remote workspace.
    func disconnectSSH(workspaceID: UUID) {
        remoteSessionService?.disconnectRemoteConnection(workspaceID: workspaceID)
    }

    func moveWorkspace(from source: IndexSet, to destination: Int) {
        workspaceManager.reorderWorkspace(from: source, to: destination)
    }

    /// Move a workspace to another window (cross-window).
    func moveWorkspaceToWindow(workspaceID: UUID, targetWindowID: UUID) {
        onMoveWorkspaceToWindow?(workspaceID, targetWindowID)
    }

    /// Move a panel (tab) from one workspace to another within the same window.
    func movePanelToWorkspace(panelID: UUID, sourceWorkspaceID: UUID, targetWorkspaceID: UUID) {
        guard sourceWorkspaceID != targetWorkspaceID,
              let pm = panelManager else { return }

        let sourceEng = pm.engine(for: sourceWorkspaceID)
        let targetEng = pm.engine(for: targetWorkspaceID)

        guard let tabID = sourceEng.tabID(for: panelID) else { return }

        let tabTitle: String
        let kind: String
        if let terminal = pm.panel(for: panelID) {
            tabTitle = terminal.title.isEmpty ? "Terminal" : terminal.title
            kind = "terminal"
        } else if let browser = pm.browserPanel(for: panelID) {
            tabTitle = browser.title
            kind = "browser"
        } else {
            return
        }

        sourceEng.removeMapping(panelID: panelID)
        sourceEng.closeTab(tabID)

        if let newTabID = targetEng.createTab(title: tabTitle, kind: kind, inPane: nil) {
            targetEng.registerMapping(tabID: newTabID, panelID: panelID)
        }

        pm.objectWillChange.send()
    }

    /// Move a panel to a target workspace and split it into a new pane.
    func splitPanelToWorkspace(panelID: UUID, sourceWorkspaceID: UUID, targetWorkspaceID: UUID, direction: SplitDirection) {
        guard sourceWorkspaceID != targetWorkspaceID,
              let pm = panelManager else { return }

        let sourceEng = pm.engine(for: sourceWorkspaceID)

        guard let tabID = sourceEng.tabID(for: panelID) else { return }

        let tabTitle: String
        let kind: String
        if let terminal = pm.panel(for: panelID) {
            tabTitle = terminal.title.isEmpty ? "Terminal" : terminal.title
            kind = "terminal"
        } else if let browser = pm.browserPanel(for: panelID) {
            tabTitle = browser.title
            kind = "browser"
        } else {
            return
        }

        sourceEng.removeMapping(panelID: panelID)
        sourceEng.closeTab(tabID)

        let targetEng = pm.engine(for: targetWorkspaceID)
        let orientation: SplitOrientation = direction == .horizontal ? .horizontal : .vertical
        if let newPaneID = targetEng.splitPane(targetEng.focusedPaneID, orientation: orientation),
           let newTabID = targetEng.createTab(title: tabTitle, kind: kind, inPane: newPaneID) {
            targetEng.registerMapping(tabID: newTabID, panelID: panelID)
            targetEng.focusPane(newPaneID)
        } else if let newTabID = targetEng.createTab(title: tabTitle, kind: kind, inPane: nil) {
            targetEng.registerMapping(tabID: newTabID, panelID: panelID)
        }

        pm.objectWillChange.send()
    }

    // MARK: - Private

    /// Sync WorkspaceManager and rebuild items whenever selection changes.
    private func selectionDidChange(oldValue: SidebarSelection) {
        switch selection {
        case .workspace(let id):
            lastWorkspaceID = id
            workspaceManager.selectWorkspace(id: id)
            // Mark notifications for this workspace as read when selected.
            notificationService?.markAllRead(workspaceID: id)
        case .settings, .notifications:
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

        NotificationCenter.default.publisher(for: .toggleNotificationPanel)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.toggleNotifications()
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
                self.metadataCache[wsID] = meta
                self.rebuildItems()
            }
            .store(in: &cancellables)

        // Terminal OSC notifications — sidebar metadata update only.
        // Suppression + sound + desktop notification handled by NotificationService.
        // Route to the workspace that OWNS the terminal, not the selected workspace.
        NotificationCenter.default.publisher(for: .namuTerminalNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] notification in
                guard let self, let pm = self.panelManager else { return }
                let title = notification.userInfo?["title"] as? String ?? ""
                let body = notification.userInfo?["body"] as? String ?? ""
                let displayText = body.isEmpty ? title : body

                // Resolve the owning workspace from the surface pointer.
                // The surface userdata is the TerminalSession; match its ID to find the workspace.
                let wsID: UUID? = {
                    if let surfacePtr = notification.userInfo?["surface"] as? UnsafeMutableRawPointer,
                       let userdata = ghostty_surface_userdata(surfacePtr) {
                        let session = Unmanaged<TerminalSession>.fromOpaque(userdata).takeUnretainedValue()
                        return pm.workspaceIDForPanel(session.id)
                    }
                    return self.workspaceManager.selectedWorkspaceID
                }()

                guard let wsID else { return }

                // Skip sidebar update for Claude panes (their notifications come via hooks).
                if let ws = self.workspaceManager.workspaces.first(where: { $0.id == wsID }),
                   !ws.agentPIDs.isEmpty {
                    return
                }

                var meta = self.metadataCache[wsID] ?? SidebarMetadata()
                meta.latestNotification = displayText
                self.metadataCache[wsID] = meta
                self.rebuildItems()
            }
            .store(in: &cancellables)
    }

    /// Sync live panel state (shell state, working directory) into the metadata cache.
    /// Called before rebuildItems() so the cache is up-to-date and rebuildItems() stays a pure read.
    private func syncPanelStateToMetadata() {
        guard let pm = panelManager else { return }
        for workspace in workspaceManager.workspaces {
            if metadataCache[workspace.id] == nil { metadataCache[workspace.id] = SidebarMetadata() }

            // Sync unread count from NotificationService (derived, not accumulated)
            metadataCache[workspace.id]?.unreadCount = notificationService?.unreadCountForWorkspace(workspace.id) ?? 0

            guard let panelID = pm.focusedPanelID(in: workspace.id),
                  let panel = pm.panel(for: panelID) else { continue }

            // Sync working directory from panel (updated by IPC report_pwd)
            metadataCache[workspace.id]?.workingDirectory = panel.workingDirectory

            // Sync shell state and derive lastCommand/lastExitCode
            let state = panel.shellState
            metadataCache[workspace.id]?.shellState = state
            switch state {
            case .running(let cmd):
                if !cmd.isEmpty { metadataCache[workspace.id]?.lastCommand = cmd }
                metadataCache[workspace.id]?.lastExitCode = nil
            case .idle(let code):
                metadataCache[workspace.id]?.lastExitCode = code
            case .prompt:
                metadataCache[workspace.id]?.lastExitCode = nil
            default:
                break
            }
        }
    }

    /// Rebuild sidebar items using the current `selection` so workspace
    /// highlight state reflects the generalized selection model.
    func rebuildItems() {
        // Sync selection from WorkspaceManager if it changed externally
        // (e.g. PanelManager.createWorkspace() selected a new workspace).
        if case .workspace(let currentID) = selection,
           let managerID = workspaceManager.selectedWorkspaceID,
           managerID != currentID {
            selection = .workspace(managerID)
        }

        // Sync live panel state into metadata before building items.
        syncPanelStateToMetadata()

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
                panelCount: panelManager?.allPanelIDs(in: workspace.id).count ?? 0,
                gitBranch: meta?.gitBranch,
                gitDirty: meta?.gitDirty ?? false,
                workingDirectory: meta?.workingDirectory,
                listeningPorts: meta?.listeningPorts ?? [],
                shellState: meta?.shellState ?? .unknown,
                lastExitCode: meta?.lastExitCode,
                lastCommand: meta?.lastCommand,
                unreadCount: meta?.unreadCount ?? 0,
                notificationSubtitle: meta?.latestNotification,
                progressLabel: meta?.progressLabel,
                latestLog: meta?.latestLog,
                logLevel: meta?.logLevel,
                isRemoteSSH: meta?.isRemoteSSH ?? false,
                remoteConnectionDetail: meta?.remoteConnectionDetail,
                remoteConnectionState: meta?.remoteConnectionState,
                remoteForwardedPorts: meta?.remoteForwardedPorts,
                pullRequests: meta?.pullRequests ?? [],
                panelBranches: meta?.panelBranches ?? [:],
                metadataEntries: meta?.metadataEntries ?? [],
                statusEntries: meta?.statusEntries ?? [:],
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
