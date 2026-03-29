import Foundation
import Combine
import Bonsplit

/// Manages panel lifecycle and layout for all workspaces.
/// BonsplitLayoutEngine is the single source of truth for splits/tabs/focus.
@MainActor
final class PanelManager: ObservableObject {

    // MARK: - Dependencies

    let workspaceManager: WorkspaceManager
    private var cancellables = Set<AnyCancellable>()

    // MARK: - Layout engines (one per workspace)

    private(set) var engines: [UUID: BonsplitLayoutEngine] = [:]

    // MARK: - Panel registry

    /// Maps panel UUID → live TerminalPanel. PaneLeaf IDs are the join key.
    private(set) var panels: [UUID: TerminalPanel] = [:]

    // MARK: - Previous focus tracking

    private(set) var previousFocusedPanelID: UUID?

    // MARK: - Title observation

    private var observedPanelIDs = Set<UUID>()

    // MARK: - Init

    init(workspaceManager: WorkspaceManager) {
        self.workspaceManager = workspaceManager
        // Bootstrap engines + panels for existing workspaces
        for workspace in workspaceManager.workspaces {
            bootstrapWorkspace(workspace)
        }
    }

    // MARK: - Engine access

    /// Get the layout engine for a workspace. Creates one if missing.
    func engine(for workspaceID: UUID) -> BonsplitLayoutEngine {
        if let existing = engines[workspaceID] { return existing }
        let engine = BonsplitLayoutEngine(workspaceID: workspaceID)
        engine.onNewTabRequested = { [weak self] kind, paneID in
            guard let self else { return }
            let panel = self.createTerminalPanel(workspaceID: workspaceID)
            if let tabID = engine.createTab(title: "Terminal", kind: kind, inPane: paneID) {
                engine.registerMapping(tabID: tabID, panelID: panel.id)
            }
        }
        engines[workspaceID] = engine
        return engine
    }

    /// Get the BonsplitController for a workspace (for BonsplitView rendering).
    func controller(for workspaceID: UUID) -> BonsplitController {
        engine(for: workspaceID).controller
    }

    // MARK: - Bootstrap

    /// Set up engine + initial panel for a workspace.
    private func bootstrapWorkspace(_ workspace: Workspace) {
        let eng = engine(for: workspace.id)

        // Check if any pane already has tabs with mapped panels.
        let hasContent = eng.allPaneIDs.contains { paneID in
            eng.controller.tabs(inPane: paneID).contains { tab in
                eng.panelID(for: tab.id) != nil
            }
        }

        if !hasContent {
            // Capture Bonsplit's default Welcome tab IDs before creating ours
            let welcomeTabIds = eng.controller.allTabIds
            let targetPane = eng.allPaneIDs.first

            // Create our terminal tab first
            let panel = createTerminalPanel(workspaceID: workspace.id)
            if let tabID = eng.createTab(title: "Terminal", kind: "terminal", inPane: targetPane) {
                eng.registerMapping(tabID: tabID, panelID: panel.id)

                // Now close the Welcome tab(s) — must happen AFTER creating our tab
                // so Bonsplit never has zero tabs (which would recreate Welcome)
                for welcomeTabId in welcomeTabIds {
                    eng.closeTab(welcomeTabId)
                }

                // Focus the pane and select our tab
                if let paneID = targetPane {
                    eng.focusPane(paneID)
                }
                eng.controller.selectTab(tabID)
            }
        }
    }

    // MARK: - Workspace bootstrap

    /// Bootstrap a restored workspace — maps existing panels (already in self.panels)
    /// to Bonsplit tabs. Called by SessionPersistence after restoring panels.
    /// - Parameters:
    ///   - workspace: The workspace metadata (id, title, etc.)
    ///   - panelIDs: Panel IDs to create tabs for (from the persisted layout)
    ///   - activePanelID: The panel that should be focused after restore
    func bootstrapRestoredWorkspace(_ workspace: Workspace, panelIDs: [UUID], activePanelID: UUID?) {
        let eng = engine(for: workspace.id)
        let welcomeTabIds = eng.controller.allTabIds

        for panelID in panelIDs {
            if let panel = panels[panelID] {
                let title = panel.title.isEmpty ? "Terminal" : panel.title
                if let tabID = eng.createTab(title: title, kind: "terminal", inPane: nil) {
                    eng.registerMapping(tabID: tabID, panelID: panelID)
                }
                observePanelTitle(panel, workspaceID: workspace.id)
            }
        }

        // Close Welcome tabs after our tabs are created
        for welcomeTabId in welcomeTabIds {
            eng.closeTab(welcomeTabId)
        }

        // Focus the active panel
        let focusID = activePanelID ?? panelIDs.first
        if let focusID, let tabID = eng.tabID(for: focusID) {
            if let paneID = eng.allPaneIDs.first {
                eng.focusPane(paneID)
            }
            eng.controller.selectTab(tabID)
        }
    }

    // MARK: - Workspace creation (single entry point)

    /// Create a new workspace with a bootstrapped terminal and select it.
    /// All workspace creation MUST go through this method to ensure the
    /// BonsplitLayoutEngine is set up with an initial terminal tab.
    @discardableResult
    func createWorkspace(title: String = String(localized: "workspace.default.title", defaultValue: "New Workspace")) -> Workspace {
        let ws = workspaceManager.createWorkspace(title: title)
        bootstrapWorkspace(ws)

        workspaceManager.selectWorkspace(id: ws.id)
        return ws
    }

    /// Delete a workspace — cleans up engine + panels, then removes from WorkspaceManager.
    /// All workspace deletion MUST go through this method.
    func deleteWorkspace(id: UUID) {
        onWorkspaceDeleted(workspaceID: id)
        workspaceManager.deleteWorkspace(id: id)
    }

    // MARK: - Panel factory

    /// Create a new TerminalPanel with per-pane environment variables.
    func createTerminalPanel(
        workspaceID: UUID? = nil,
        workingDirectory: String? = nil
    ) -> TerminalPanel {
        let paneID = UUID()
        let wsID = workspaceID ?? workspaceManager.selectedWorkspaceID
        let env = namuEnvironment(paneID: paneID, workspaceID: wsID)
        let panel = TerminalPanel(
            id: paneID,
            workingDirectory: workingDirectory,
            environmentVariables: env
        )
        panels[panel.id] = panel
        if let wsID {
            observePanelTitle(panel, workspaceID: wsID)
        }
        return panel
    }

    /// Restore a TerminalPanel with a known ID during session restore.
    @discardableResult
    func restoreTerminalPanel(
        id: UUID,
        workingDirectory: String?,
        scrollbackFile: String?,
        gitBranch: String? = nil,
        customTitle: String? = nil
    ) -> TerminalPanel {
        let session = TerminalSession(id: id, workingDirectory: workingDirectory)
        let panel = TerminalPanel(id: id, workingDirectory: workingDirectory, session: session)
        panel.scrollbackRestoreFile = scrollbackFile
        panel.customTitle = customTitle
        if let branch = gitBranch {
            panel.restoreGitBranch(branch)
        }
        panels[id] = panel
        return panel
    }

    // MARK: - Split

    /// Split the focused pane in the given workspace, creating a new terminal.
    func splitPane(
        in workspaceID: UUID,
        paneID: Bonsplit.PaneID? = nil,
        direction: SplitDirection,
        workingDirectory: String? = nil
    ) {
        let eng = engine(for: workspaceID)
        let orientation: Bonsplit.SplitOrientation = direction == .horizontal ? .horizontal : .vertical
        let targetPane = paneID ?? eng.focusedPaneID

        guard let newPaneID = eng.splitPane(targetPane, orientation: orientation) else { return }

        // Create terminal panel for the new pane
        let panel = createTerminalPanel(workspaceID: workspaceID, workingDirectory: workingDirectory)
        if let tabID = eng.createTab(title: "Terminal", kind: "terminal", inPane: newPaneID) {
            eng.registerMapping(tabID: tabID, panelID: panel.id)
        }

        // Focus the new pane
        eng.focusPane(newPaneID)
        objectWillChange.send()
    }

    /// Convenience: split the active pane in the selected workspace.
    func splitActivePanel(direction: SplitDirection) {
        guard let wsID = workspaceManager.selectedWorkspaceID else { return }
        splitPane(in: wsID, direction: direction)
    }

    // MARK: - Close

    /// Close a specific panel by ID.
    func closePanel(id: UUID) {
        guard let wsID = workspaceIDForPanel(id) else { return }
        let eng = engine(for: wsID)

        // Find and close the tab in bonsplit
        if let tabID = eng.tabID(for: id) {
            eng.removeMapping(panelID: id)
            eng.closeTab(tabID)
        }

        // Clean up the panel
        panels[id]?.close()
        panels.removeValue(forKey: id)
        observedPanelIDs.remove(id)
        objectWillChange.send()
    }

    /// Close the active panel in the selected workspace.
    func closeActivePanel() {
        guard let wsID = workspaceManager.selectedWorkspaceID else { return }
        let eng = engine(for: wsID)
        guard let focusedPane = eng.focusedPaneID,
              let selectedTab = eng.controller.selectedTab(inPane: focusedPane),
              let panelID = eng.panelID(for: selectedTab.id) else { return }
        closePanel(id: panelID)
    }

    // MARK: - Focus

    /// Activate (focus) a specific panel.
    func activatePanel(id: UUID) {
        guard let wsID = workspaceIDForPanel(id) else { return }
        let eng = engine(for: wsID)

        // Track previous focus
        if let currentFocused = focusedPanelID(in: wsID), currentFocused != id {
            previousFocusedPanelID = currentFocused
        }

        // Find the pane containing this panel's tab and focus it
        if let tabID = eng.tabID(for: id) {
            for paneID in eng.allPaneIDs {
                let tabs = eng.controller.tabs(inPane: paneID)
                if tabs.contains(where: { $0.id == tabID }) {
                    eng.focusPane(paneID)
                    break
                }
            }
        }

        applyFocusState(in: wsID)
        objectWillChange.send()
    }

    /// Navigate focus in a direction within the selected workspace.
    func activateDirection(_ direction: NavigationDirection) {
        guard let wsID = workspaceManager.selectedWorkspaceID else { return }
        let eng = engine(for: wsID)

        let bonsplitDir: Bonsplit.NavigationDirection
        switch direction {
        case .left: bonsplitDir = .left
        case .right: bonsplitDir = .right
        case .up: bonsplitDir = .up
        case .down: bonsplitDir = .down
        }

        eng.navigateFocus(bonsplitDir)
        applyFocusState(in: wsID)
        objectWillChange.send()
    }

    /// Move focus to next pane in the selected workspace.
    func activateNext() {
        guard let wsID = workspaceManager.selectedWorkspaceID else { return }
        let eng = engine(for: wsID)
        eng.navigateFocus(.right)
        applyFocusState(in: wsID)
        objectWillChange.send()
    }

    /// Move focus to previous pane in the selected workspace.
    func activatePrevious() {
        guard let wsID = workspaceManager.selectedWorkspaceID else { return }
        let eng = engine(for: wsID)
        eng.navigateFocus(.left)
        applyFocusState(in: wsID)
        objectWillChange.send()
    }

    // MARK: - Zoom

    @discardableResult
    func toggleZoom(in workspaceID: UUID, paneID: Bonsplit.PaneID? = nil) -> Bool {
        let eng = engine(for: workspaceID)
        let target = paneID ?? eng.focusedPaneID
        return eng.toggleZoom(target)
    }

    // MARK: - Resize

    func resizeSplit(in workspaceID: UUID, splitID: UUID, ratio: CGFloat) {
        let eng = engine(for: workspaceID)
        eng.setDividerPosition(ratio, forSplit: splitID)
        objectWillChange.send()
    }

    // MARK: - Query

    /// Get the focused panel ID for a workspace.
    func focusedPanelID(in workspaceID: UUID) -> UUID? {
        let eng = engine(for: workspaceID)
        guard let focusedPane = eng.focusedPaneID,
              let selectedTab = eng.controller.selectedTab(inPane: focusedPane) else { return nil }
        return eng.panelID(for: selectedTab.id)
    }

    /// Look up a panel by ID.
    func panel(for id: UUID) -> TerminalPanel? {
        panels[id]
    }

    /// All panel IDs in a workspace.
    func allPanelIDs(in workspaceID: UUID) -> [UUID] {
        let eng = engine(for: workspaceID)
        var result: [UUID] = []
        for paneID in eng.allPaneIDs {
            for tab in eng.controller.tabs(inPane: paneID) {
                if let panelID = eng.panelID(for: tab.id) {
                    result.append(panelID)
                }
            }
        }
        return result
    }

    /// Returns true if the panel has a running shell process.
    func isProcessRunning(id: UUID) -> Bool {
        guard let panel = panels[id] else { return false }
        if case .running = panel.session.state { return true }
        return false
    }

    /// Find which workspace owns a panel.
    func workspaceIDForPanel(_ panelID: UUID) -> UUID? {
        for (wsID, eng) in engines {
            if eng.tabID(for: panelID) != nil { return wsID }
        }
        return nil
    }

    // MARK: - Workspace lifecycle

    /// Called when a new workspace is created. Sets up engine + initial panel.
    func onWorkspaceCreated(_ workspace: Workspace) {
        bootstrapWorkspace(workspace)
        objectWillChange.send()
    }

    /// Called when a workspace is deleted. Cleans up engine + panels.
    func onWorkspaceDeleted(workspaceID: UUID) {
        if let eng = engines.removeValue(forKey: workspaceID) {
            // Close all panels in this workspace
            for paneID in eng.allPaneIDs {
                for tab in eng.controller.tabs(inPane: paneID) {
                    if let panelID = eng.panelID(for: tab.id) {
                        panels[panelID]?.close()
                        panels.removeValue(forKey: panelID)
                        observedPanelIDs.remove(panelID)
                    }
                }
            }
        }
        objectWillChange.send()
    }

    // MARK: - Private

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

    /// Tell sessions which one owns keyboard focus.
    private func applyFocusState(in workspaceID: UUID) {
        let focusedID = focusedPanelID(in: workspaceID)
        for panelID in allPanelIDs(in: workspaceID) {
            let intent: FocusIntent = panelID == focusedID ? .capture : .resign
            panels[panelID]?.handleFocus(intent)
        }
    }

    /// Forward terminal title changes to the workspace for sidebar display.
    private func observePanelTitle(_ panel: TerminalPanel, workspaceID: UUID) {
        guard !observedPanelIDs.contains(panel.id) else { return }
        observedPanelIDs.insert(panel.id)

        panel.$title
            .dropFirst()
            .debounce(for: .milliseconds(100), scheduler: RunLoop.main)
            .sink { [weak self] newTitle in
                guard let self,
                      let idx = self.workspaceManager.workspaces.firstIndex(where: { $0.id == workspaceID }),
                      self.focusedPanelID(in: workspaceID) == panel.id else { return }
                self.workspaceManager.workspaces[idx].applyProcessTitle(newTitle)
            }
            .store(in: &cancellables)
    }
}
