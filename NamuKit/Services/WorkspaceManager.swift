import Foundation
import Combine

/// Manages all workspaces in the application.
/// Single source of truth for workspace CRUD and selection state.
@MainActor
final class WorkspaceManager: ObservableObject {

    // MARK: - Published state

    @Published var workspaces: [Workspace] = []
    @Published var selectedWorkspaceID: UUID?

    /// Incremented after each toggleZoom call to force SwiftUI subtree recreation
    /// via the `.id()` modifier, discarding any stale portal bindings.
    @Published var splitZoomRenderIdentity: Int = 0

    // MARK: - Computed

    var selectedWorkspace: Workspace? {
        guard let id = selectedWorkspaceID else { return nil }
        return workspaces.first { $0.id == id }
    }

    // MARK: - Init

    init() {
        let initial = Workspace(title: String(localized: "workspace.default.title", defaultValue: "New Workspace"), order: 0)
        workspaces = [initial]
        selectedWorkspaceID = initial.id
    }

    // MARK: - CRUD

    /// Create a new workspace and insert it according to the given placement.
    /// If `placement` is nil, the value from `WorkspacePlacementSettings` is used.
    @discardableResult
    func createWorkspace(
        title: String = String(localized: "workspace.default.title", defaultValue: "New Workspace"),
        placement: WorkspacePlacement? = nil
    ) -> Workspace {
        let resolvedPlacement = placement ?? WorkspacePlacementSettings.current()
        let pinnedCount = workspaces.filter(\.isPinned).count
        let selectedIndex = selectedWorkspaceID.flatMap { id in
            workspaces.firstIndex(where: { $0.id == id })
        }
        let selectedIsPinned = selectedWorkspaceID.flatMap { id in
            workspaces.first(where: { $0.id == id })
        }?.isPinned ?? false
        let insertIndex = WorkspacePlacementSettings.insertionIndex(
            placement: resolvedPlacement,
            selectedIndex: selectedIndex,
            pinnedCount: pinnedCount,
            totalCount: workspaces.count,
            selectedIsPinned: selectedIsPinned
        )
        let workspace = Workspace(title: title, order: insertIndex)
        workspaces.insert(workspace, at: insertIndex)
        reindex()
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

        NotificationCenter.default.post(
            name: .namuWorkspaceDidDelete,
            object: nil,
            userInfo: ["workspace_id": id]
        )
    }

    /// Select the workspace with the given ID.
    func selectWorkspace(id: UUID) {
        guard workspaces.contains(where: { $0.id == id }) else { return }
        selectedWorkspaceID = id
        // Reap stale agent PIDs on selection change so dead processes don't block notifications.
        for idx in workspaces.indices {
            workspaces[idx].reapStaleAgentPIDs()
        }
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
        guard let idx = workspaces.firstIndex(where: { $0.id == id }) else {
            print("[WorkspaceManager] setWorkspaceColor: workspace \(id) not found")
            return
        }
        print("[WorkspaceManager] setWorkspaceColor: workspace=\(workspaces[idx].title) color=\(color ?? "nil") idx=\(idx)")
        workspaces[idx].customColor = color
        print("[WorkspaceManager] after set: customColor=\(workspaces[idx].customColor ?? "nil")")
    }

    // MARK: - Auto-reorder

    /// Move the workspace with the given ID to the top of the unpinned section
    /// (i.e. immediately after all pinned workspaces). No-op if the workspace is pinned
    /// or already at the top of the unpinned section.
    func moveWorkspaceToTop(id: UUID) {
        guard let idx = workspaces.firstIndex(where: { $0.id == id }) else { return }
        let workspace = workspaces[idx]
        guard !workspace.isPinned else { return }

        let pinnedCount = workspaces.filter(\.isPinned).count
        // Already at the top of the unpinned section — nothing to do.
        guard idx != pinnedCount else { return }

        workspaces.remove(at: idx)
        workspaces.insert(workspace, at: pinnedCount)
        reindex()
    }

    // MARK: - Internal mutations (used by PanelManager)

    /// Update the workspace value in-place.
    func update(_ workspace: Workspace) {
        guard let idx = workspaces.firstIndex(where: { $0.id == workspace.id }) else { return }
        workspaces[idx] = workspace
    }

    // MARK: - Private helpers

    /// Reassign `order` values to match array positions after moves/deletions.
    private func reindex() {
        for idx in workspaces.indices {
            workspaces[idx].order = idx
        }
    }
}
