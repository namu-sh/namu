import Foundation
import Combine

/// Manages panel lifecycle within the selected workspace.
/// Delegates workspace state mutations to WorkspaceManager.
@MainActor
final class PanelManager: ObservableObject {

    // MARK: - Dependencies

    private let workspaceManager: WorkspaceManager
    private var cancellables = Set<AnyCancellable>()

    // MARK: - In-memory panel registry
    // Panels are reference types and are not stored in the value-type Workspace.
    // PaneLeaf IDs serve as the join key between the tree and this registry.

    private var panels: [UUID: TerminalPanel] = [:]

    // MARK: - Init

    init(workspaceManager: WorkspaceManager) {
        self.workspaceManager = workspaceManager
        // Auto-register TerminalPanels for all existing workspace leaves
        // so PaneLeafView can find them.
        ensurePanelsForAllLeaves()

        // Observe workspace changes to auto-register panels for new leaves
        workspaceManager.objectWillChange
            .debounce(for: .zero, scheduler: RunLoop.main)
            .sink { [weak self] _ in
                self?.ensurePanelsForAllLeaves()
            }
            .store(in: &cancellables)
    }

    /// Ensure every PaneLeaf in every workspace has a registered TerminalPanel.
    func ensurePanelsForAllLeaves() {
        for workspace in workspaceManager.workspaces {
            for leaf in workspace.allPanels where leaf.panelType == .terminal {
                if panels[leaf.id] == nil {
                    let panel = TerminalPanel(id: leaf.id)
                    panels[leaf.id] = panel
                }
            }
        }
    }

    // MARK: - Panel factory

    /// Create a new TerminalPanel (does not insert it into any workspace tree).
    func createTerminalPanel(workingDirectory: String? = nil) -> TerminalPanel {
        let panel = TerminalPanel(workingDirectory: workingDirectory)
        panels[panel.id] = panel
        return panel
    }

    /// Restore a TerminalPanel with a known ID during session restore.
    /// The `scrollbackFile` path, if present, should be forwarded to the shell
    /// via the MOSAIC_RESTORE_SCROLLBACK_FILE environment variable by shell integration.
    @discardableResult
    func restoreTerminalPanel(id: UUID, workingDirectory: String?, scrollbackFile: String?) -> TerminalPanel {
        let session = TerminalSession(id: id, workingDirectory: workingDirectory)
        let panel = TerminalPanel(id: id, workingDirectory: workingDirectory, session: session)
        panel.scrollbackRestoreFile = scrollbackFile
        panels[id] = panel
        return panel
    }

    // MARK: - Split / close

    /// Split the pane at `id`, adding `newPanel` as a sibling in `direction`.
    /// Updates the selected workspace's pane tree and focuses the new panel.
    func splitPanel(id: UUID, direction: SplitDirection, newPanel: TerminalPanel) {
        guard var workspace = workspaceManager.selectedWorkspace else { return }
        let leaf = PaneLeaf(id: newPanel.id)
        workspace.paneTree = workspace.paneTree.insertSplit(at: id, direction: direction, newPanel: leaf)
        workspace.focusedPanelID = newPanel.id
        panels[newPanel.id] = newPanel
        workspaceManager.update(workspace)
        applyFocus(in: workspace)
    }

    /// Close the panel with `id`, collapsing the tree if needed.
    /// Automatically focuses an adjacent panel.
    func closePanel(id: UUID) {
        guard var workspace = workspaceManager.selectedWorkspace else { return }
        guard let newTree = workspace.paneTree.removePane(id: id) else { return }
        workspace.paneTree = newTree

        // Choose a new focus target.
        if workspace.focusedPanelID == id {
            workspace.focusedPanelID = newTree.allPanels.first?.id
        }

        // Clean up the panel.
        panels[id]?.close()
        panels.removeValue(forKey: id)

        workspaceManager.update(workspace)
        applyFocus(in: workspace)
    }

    // MARK: - Focus

    /// Set focus to the panel with the given ID.
    func focusPanel(id: UUID) {
        guard var workspace = workspaceManager.selectedWorkspace else { return }
        guard workspace.paneTree.findPane(id: id) != nil else { return }
        workspace.focusedPanelID = id
        workspaceManager.update(workspace)
        applyFocus(in: workspace)
    }

    /// Move focus to the nearest panel in `direction` from the currently focused panel.
    func focusDirection(_ direction: NavigationDirection) {
        guard var workspace = workspaceManager.selectedWorkspace else { return }
        guard let currentID = workspace.focusedPanelID else { return }
        guard let nextID = workspace.paneTree.focusInDirection(direction, from: currentID) else { return }
        workspace.focusedPanelID = nextID
        workspaceManager.update(workspace)
        applyFocus(in: workspace)
    }

    /// Move focus to the next panel in document order.
    func focusNext() {
        guard var workspace = workspaceManager.selectedWorkspace else { return }
        guard let currentID = workspace.focusedPanelID else { return }
        guard let nextID = workspace.paneTree.focusNext(after: currentID) else { return }
        workspace.focusedPanelID = nextID
        workspaceManager.update(workspace)
        applyFocus(in: workspace)
    }

    /// Move focus to the previous panel in document order.
    func focusPrevious() {
        guard var workspace = workspaceManager.selectedWorkspace else { return }
        guard let currentID = workspace.focusedPanelID else { return }
        guard let prevID = workspace.paneTree.focusPrevious(before: currentID) else { return }
        workspace.focusedPanelID = prevID
        workspaceManager.update(workspace)
        applyFocus(in: workspace)
    }

    // MARK: - Convenience helpers (used by CommandPalette + keyboard shortcuts)

    /// Split the currently focused panel in the selected workspace.
    func splitFocusedPanel(direction: SplitDirection) {
        guard let focusedID = workspaceManager.selectedWorkspace?.focusedPanelID else { return }
        let newPanel = createTerminalPanel()
        splitPanel(id: focusedID, direction: direction, newPanel: newPanel)
    }

    /// Close the currently focused panel in the selected workspace.
    func closeFocusedPanel() {
        guard let focusedID = workspaceManager.selectedWorkspace?.focusedPanelID else { return }
        closePanel(id: focusedID)
    }

    // MARK: - Resize

    /// Adjust the split ratio for the split node identified by `splitID`.
    func resizeSplit(splitID: UUID, ratio: Double) {
        guard var workspace = workspaceManager.selectedWorkspace else { return }
        workspace.paneTree = workspace.paneTree.resizeSplit(splitID: splitID, ratio: ratio)
        workspaceManager.update(workspace)
    }

    // MARK: - Lookup

    /// Retrieve the live panel object for a given leaf ID.
    func panel(for id: UUID) -> TerminalPanel? {
        panels[id]
    }

    // MARK: - Private helpers

    /// Tell sessions which one owns keyboard focus.
    private func applyFocus(in workspace: Workspace) {
        let focusedID = workspace.focusedPanelID
        for leaf in workspace.allPanels {
            let intent: FocusIntent = leaf.id == focusedID ? .capture : .resign
            panels[leaf.id]?.handleFocus(intent)
        }
    }
}
