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
    let panelCount: Int
    let gitBranch: String?
    let workingDirectory: String?
    let listeningPorts: [PortInfo]
    let shellState: ShellState
    let lastExitCode: Int?
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
    private var cancellables = Set<AnyCancellable>()

    init(workspaceManager: WorkspaceManager) {
        self.workspaceManager = workspaceManager
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
    }

    /// Rebuild sidebar items using the current `selection` so workspace
    /// highlight state reflects the generalized selection model.
    func rebuildItems() {
        let sel = selection
        items = workspaceManager.workspaces.map { workspace in
            let meta = metadataCache[workspace.id]
            let isSelected = sel == .workspace(workspace.id)
            return SidebarItemData(
                id: workspace.id,
                title: workspace.title,
                isSelected: isSelected,
                isPinned: workspace.isPinned,
                panelCount: workspace.panelCount,
                gitBranch: meta?.gitBranch,
                workingDirectory: meta?.workingDirectory,
                listeningPorts: meta?.listeningPorts ?? [],
                shellState: meta?.shellState ?? .unknown,
                lastExitCode: meta?.lastExitCode
            )
        }
    }

    // MARK: - Shell integration metadata

    /// Called by PanelManager or shell integration when a workspace's metadata changes.
    func updateMetadata(_ metadata: SidebarMetadata, for workspaceID: UUID) {
        metadataCache[workspaceID] = metadata
        rebuildItems()
    }

    private var metadataCache: [UUID: SidebarMetadata] = [:]
}
