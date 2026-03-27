import Foundation
import Combine

/// Transient zoom state for a workspace. Not persisted — lives in PanelManager only.
struct WorkspaceUIState {
    var isZoomed: Bool = false
    var zoomedPanelID: UUID? = nil
}

/// Manages panel lifecycle within the selected workspace.
/// Delegates workspace state mutations to WorkspaceManager.
@MainActor
final class PanelManager: ObservableObject {

    // MARK: - Dependencies

    private let workspaceManager: WorkspaceManager
    private var cancellables = Set<AnyCancellable>()

    /// Socket path injected by ServiceContainer after the server starts.

    // MARK: - In-memory panel registry
    // Panels are reference types and are not stored in the value-type Workspace.
    // PaneLeaf IDs serve as the join key between the tree and this registry.

    private var panels: [UUID: TerminalPanel] = [:]

    // MARK: - Transient UI state (not persisted)

    private var uiState: [UUID: WorkspaceUIState] = [:]

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
    private var observedPanelIDs = Set<UUID>()

    func ensurePanelsForAllLeaves() {
        for workspace in workspaceManager.workspaces {
            for leaf in workspace.allPanels where leaf.panelType == .terminal {
                if panels[leaf.id] == nil {
                    let env = namuEnvironment(paneID: leaf.id, workspaceID: workspace.id)
                    let panel = TerminalPanel(id: leaf.id, environmentVariables: env)
                    panels[leaf.id] = panel
                }
                // Observe title for all panels, including restored ones.
                if let panel = panels[leaf.id], !observedPanelIDs.contains(leaf.id) {
                    observePanelTitle(panel, workspaceID: workspace.id)
                    observedPanelIDs.insert(leaf.id)
                }
            }
        }
    }

    /// Forward terminal title changes to the workspace for sidebar display.
    private func observePanelTitle(_ panel: TerminalPanel, workspaceID: UUID) {
        panel.$title
            .dropFirst()
            .debounce(for: .milliseconds(100), scheduler: RunLoop.main)
            .sink { [weak self] newTitle in
                guard let self,
                      let idx = self.workspaceManager.workspaces.firstIndex(where: { $0.id == workspaceID }),
                      self.workspaceManager.workspaces[idx].activePanelID == panel.id else { return }
                self.workspaceManager.workspaces[idx].applyProcessTitle(newTitle)
            }
            .store(in: &cancellables)
    }

    // MARK: - Panel factory

    /// Create a new TerminalPanel (does not insert it into any workspace tree).
    /// Each pane receives per-pane `NAMU_*` environment variables so that
    /// subprocesses (e.g. Claude Code subagents) can connect back to the
    /// socket and identify which workspace/pane they belong to.
    ///
    func createTerminalPanel(workingDirectory: String? = nil) -> TerminalPanel {
        let paneID = UUID()
        let env = namuEnvironment(
            paneID: paneID,
            workspaceID: workspaceManager.selectedWorkspaceID
        )
        let panel = TerminalPanel(
            id: paneID,
            workingDirectory: workingDirectory,
            environmentVariables: env
        )
        panels[panel.id] = panel
        return panel
    }

    /// Restore a TerminalPanel with a known ID during session restore.
    /// The `scrollbackFile` path, if present, should be forwarded to the shell
    /// via the NAMU_RESTORE_SCROLLBACK_FILE environment variable by shell integration.
    ///
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
    /// Updates the selected workspace's pane tree and activates the new panel.
    func splitPanel(id: UUID, direction: SplitDirection, newPanel: TerminalPanel) {
        guard var workspace = workspaceManager.selectedWorkspace else { return }
        let leaf = PaneLeaf(id: newPanel.id)
        workspace.paneTree = workspace.paneTree.insertSplit(at: id, direction: direction, newPanel: leaf)
        workspace.activePanelID = newPanel.id
        panels[newPanel.id] = newPanel
        workspaceManager.update(workspace)
        applyActiveState(in: workspace)
    }

    /// Close the panel with `id`, collapsing the tree if needed.
    /// Automatically activates an adjacent panel.
    func closePanel(id: UUID) {
        guard var workspace = workspaceManager.selectedWorkspace else { return }
        guard let newTree = workspace.paneTree.removePane(id: id) else { return }
        workspace.paneTree = newTree

        // Choose a new active target.
        if workspace.activePanelID == id {
            workspace.activePanelID = newTree.allPanels.first?.id
        }

        // Clean up the panel.
        panels[id]?.close()
        panels.removeValue(forKey: id)

        workspaceManager.update(workspace)

        // Force SwiftUI to re-render the workspace view so the remaining
        // pane fills the space left by the closed pane.
        objectWillChange.send()

        applyActiveState(in: workspace)
    }

    /// Break a pane out of its current workspace into a brand-new workspace.
    /// The pane is removed from the current workspace tree; if the workspace
    /// would become empty the workspace is deleted (minimum 1 must remain).
    /// Returns the new workspace ID, or nil if the pane was not found.
    @discardableResult
    func breakOutPanel(id: UUID) -> UUID? {
        // Find which workspace owns this pane.
        guard let srcIdx = workspaceManager.workspaces.firstIndex(where: { $0.paneTree.findPane(id: id) != nil }) else { return nil }
        var srcWorkspace = workspaceManager.workspaces[srcIdx]

        guard let (leaf, remaining) = srcWorkspace.paneTree.breakPane(id: id) else { return nil }

        // Build the new workspace with just this pane.
        let newWorkspace = workspaceManager.createWorkspace(
            title: srcWorkspace.title + " (break-out)",
            paneTree: .pane(leaf)
        )

        // Transfer the panel registry entry to the new workspace (it's the same object).
        // The panel already exists in `panels`; no re-creation needed.

        // Update source workspace.
        if let remaining {
            srcWorkspace.paneTree = remaining
            if srcWorkspace.activePanelID == id {
                srcWorkspace.activePanelID = remaining.allPanels.first?.id
            }
            workspaceManager.update(srcWorkspace)
            applyActiveState(in: srcWorkspace)
        } else {
            // Source workspace is now empty — delete it (only if it's not the last one).
            if workspaceManager.workspaces.count > 1 {
                workspaceManager.deleteWorkspace(id: srcWorkspace.id)
            }
        }

        // Switch to the new workspace.
        workspaceManager.selectWorkspace(id: newWorkspace.id)
        objectWillChange.send()
        return newWorkspace.id
    }

    // MARK: - Activation

    /// Set the active (keyboard-receiving) panel to the given ID.
    func activatePanel(id: UUID) {
        guard var workspace = workspaceManager.selectedWorkspace else { return }
        guard workspace.paneTree.findPane(id: id) != nil else { return }
        workspace.activePanelID = id
        // Clear attention state when the user activates this pane.
        workspace.attentionPanelIDs.remove(id)
        workspaceManager.update(workspace)
        applyActiveState(in: workspace)
    }

    /// Move the active panel to the nearest pane in `direction`.
    func activateDirection(_ direction: NavigationDirection) {
        guard var workspace = workspaceManager.selectedWorkspace else { return }
        guard let currentID = workspace.activePanelID else { return }
        guard let nextID = workspace.paneTree.focusInDirection(direction, from: currentID) else { return }
        workspace.activePanelID = nextID
        workspace.attentionPanelIDs.remove(nextID)
        workspaceManager.update(workspace)
        applyActiveState(in: workspace)
    }

    /// Move the active panel to the next panel in document order.
    func activateNext() {
        guard var workspace = workspaceManager.selectedWorkspace else { return }
        guard let currentID = workspace.activePanelID else { return }
        guard let nextID = workspace.paneTree.focusNext(after: currentID) else { return }
        workspace.activePanelID = nextID
        workspace.attentionPanelIDs.remove(nextID)
        workspaceManager.update(workspace)
        applyActiveState(in: workspace)
    }

    /// Move the active panel to the previous panel in document order.
    func activatePrevious() {
        guard var workspace = workspaceManager.selectedWorkspace else { return }
        guard let currentID = workspace.activePanelID else { return }
        guard let prevID = workspace.paneTree.focusPrevious(before: currentID) else { return }
        workspace.activePanelID = prevID
        workspace.attentionPanelIDs.remove(prevID)
        workspaceManager.update(workspace)
        applyActiveState(in: workspace)
    }

    // MARK: - Attention

    /// Mark the pane with `panelID` as requesting attention (visual ring notification).
    /// If the pane is already the active pane, attention is not applied.
    func requestAttention(panelID: UUID) {
        guard var workspace = workspaceManager.selectedWorkspace else { return }
        // Don't flag the currently active pane — user is already looking at it.
        guard workspace.activePanelID != panelID else { return }
        workspace.attentionPanelIDs.insert(panelID)
        workspaceManager.update(workspace)
    }

    // MARK: - Convenience helpers (used by CommandPalette + keyboard shortcuts)

    /// Split the currently active panel in the selected workspace.
    func splitActivePanel(direction: SplitDirection) {
        guard let activeID = workspaceManager.selectedWorkspace?.activePanelID else { return }
        let newPanel = createTerminalPanel()
        splitPanel(id: activeID, direction: direction, newPanel: newPanel)
    }

    /// Close the currently active panel in the selected workspace.
    func closeActivePanel() {
        guard let activeID = workspaceManager.selectedWorkspace?.activePanelID else { return }
        closePanel(id: activeID)
    }

    // MARK: - Swap

    /// Swap the positions of two panes in the selected workspace's pane tree.
    /// Active state is preserved on whichever pane the user was in.
    func swapPanes(id idA: UUID, with idB: UUID) {
        guard var workspace = workspaceManager.selectedWorkspace else { return }
        workspace.paneTree = workspace.paneTree.swapPanes(id: idA, with: idB)
        workspaceManager.update(workspace)
        objectWillChange.send()
    }

    // MARK: - Resize

    /// Adjust the split ratio for the split node identified by `splitID`.
    func resizeSplit(splitID: UUID, ratio: Double) {
        guard var workspace = workspaceManager.selectedWorkspace else { return }
        workspace.paneTree = workspace.paneTree.resizeSplit(splitID: splitID, ratio: ratio)
        workspaceManager.update(workspace)
    }

    // MARK: - Zoom

    /// Returns the current zoom state for the selected workspace.
    func zoomState(for workspaceID: UUID) -> WorkspaceUIState {
        uiState[workspaceID] ?? WorkspaceUIState()
    }

    /// Zoom in on the pane with `id` in the selected workspace.
    func zoomPanel(id: UUID) {
        guard let workspace = workspaceManager.selectedWorkspace,
              workspace.paneTree.findPane(id: id) != nil else { return }
        uiState[workspace.id] = WorkspaceUIState(isZoomed: true, zoomedPanelID: id)
        objectWillChange.send()
    }

    /// Unzoom the selected workspace, restoring the full pane tree.
    func unzoomPanel() {
        guard let workspace = workspaceManager.selectedWorkspace else { return }
        uiState[workspace.id] = WorkspaceUIState()
        objectWillChange.send()
    }

    /// Toggle zoom on the pane with `id`: zoom in if not already zoomed on it, else unzoom.
    func toggleZoom(id: UUID) {
        guard let workspace = workspaceManager.selectedWorkspace else { return }
        let current = uiState[workspace.id] ?? WorkspaceUIState()
        if current.isZoomed && current.zoomedPanelID == id {
            unzoomPanel()
        } else {
            zoomPanel(id: id)
        }
    }

    // MARK: - Lookup

    /// Retrieve the live panel object for a given leaf ID.
    func panel(for id: UUID) -> TerminalPanel? {
        panels[id]
    }

    // MARK: - Environment

    /// Build per-pane identity environment variables.
    /// App-level env (PATH, ZDOTDIR, NAMU_SOCKET) is merged at surface
    /// creation time in TerminalSession.start() via appLevelEnvironment().
    private func namuEnvironment(paneID: UUID, workspaceID: UUID?) -> [String: String] {
        var env: [String: String] = [
            "NAMU_PANE_ID": paneID.uuidString,
            "NAMU_SURFACE_ID": paneID.uuidString,
        ]
        if let wsID = workspaceID {
            env["NAMU_WORKSPACE_ID"] = wsID.uuidString
        }
        return env
    }

    // MARK: - Private helpers

    /// Tell sessions which one owns keyboard focus.
    private func applyActiveState(in workspace: Workspace) {
        let activeID = workspace.activePanelID
        for leaf in workspace.allPanels {
            let intent: FocusIntent = leaf.id == activeID ? .capture : .resign
            panels[leaf.id]?.handleFocus(intent)
        }
    }
}
