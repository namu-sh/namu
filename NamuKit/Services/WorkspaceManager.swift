import Foundation
import Combine

/// Manages all workspaces in the application.
/// Single source of truth for workspace CRUD and selection state.
@MainActor
final class WorkspaceManager: ObservableObject {

    // MARK: - Published state

    @Published var workspaces: [Workspace] = []
    @Published var selectedWorkspaceID: UUID?

    // MARK: - Computed

    var selectedWorkspace: Workspace? {
        guard let id = selectedWorkspaceID else { return nil }
        return workspaces.first { $0.id == id }
    }

    // MARK: - Init

    init() {
        let initial = makeWorkspace(title: String(localized: "workspace.default.title", defaultValue: "New Workspace"), order: 0)
        workspaces = [initial]
        selectedWorkspaceID = initial.id
    }

    // MARK: - CRUD

    /// Create a new workspace and append it to the list.
    @discardableResult
    func createWorkspace(
        title: String = String(localized: "workspace.default.title", defaultValue: "New Workspace"),
        paneTree: PaneTree? = nil
    ) -> Workspace {
        let order = workspaces.map(\.order).max().map { $0 + 1 } ?? 0
        let workspace = makeWorkspace(title: title, order: order, paneTree: paneTree)
        workspaces.append(workspace)
        return workspace
    }

    /// Delete the workspace with the given ID.
    /// Automatically selects an adjacent workspace if the deleted one was selected.
    func deleteWorkspace(id: UUID) {
        guard workspaces.count > 1 else { return }  // Keep at least one workspace.
        guard let idx = workspaces.firstIndex(where: { $0.id == id }) else { return }

        workspaces.remove(at: idx)
        reindex()

        if selectedWorkspaceID == id {
            let newIdx = min(idx, workspaces.count - 1)
            selectedWorkspaceID = workspaces[newIdx].id
        }
    }

    /// Select the workspace with the given ID.
    func selectWorkspace(id: UUID) {
        guard workspaces.contains(where: { $0.id == id }) else { return }
        selectedWorkspaceID = id
    }

    /// Move a workspace from one position to another (for drag reordering).
    func reorderWorkspace(from source: IndexSet, to destination: Int) {
        workspaces.move(fromOffsets: source, toOffset: destination)
        reindex()
    }

    /// Rename the workspace with the given ID.
    func renameWorkspace(id: UUID, title: String) {
        guard let idx = workspaces.firstIndex(where: { $0.id == id }) else { return }
        workspaces[idx].setCustomTitle(title)
    }

    /// Toggle the pinned state of the workspace with the given ID.
    func pinWorkspace(id: UUID) {
        guard let idx = workspaces.firstIndex(where: { $0.id == id }) else { return }
        workspaces[idx].isPinned.toggle()
    }

    /// Set or clear the custom accent color for a workspace.
    /// Pass nil to remove the color.
    func setWorkspaceColor(id: UUID, color: String?) {
        guard let idx = workspaces.firstIndex(where: { $0.id == id }) else { return }
        workspaces[idx].customColor = color
    }

    // MARK: - Internal mutations (used by PanelManager)

    /// Update the workspace value in-place.
    func update(_ workspace: Workspace) {
        guard let idx = workspaces.firstIndex(where: { $0.id == workspace.id }) else { return }
        workspaces[idx] = workspace
    }

    // MARK: - Private helpers

    private func makeWorkspace(title: String, order: Int, paneTree: PaneTree? = nil) -> Workspace {
        Workspace(title: title, order: order, paneTree: paneTree)
    }

    /// Reassign `order` values to match array positions after moves/deletions.
    private func reindex() {
        for idx in workspaces.indices {
            workspaces[idx].order = idx
        }
    }
}
