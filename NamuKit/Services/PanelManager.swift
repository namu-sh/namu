import Foundation
import Combine

// MARK: - PanelFocusIntent

/// Rich focus intent that captures sub-panel focus targets for capture/restore.
enum PanelFocusIntent {
    case terminal(TerminalFocusTarget)
    case browser(BrowserFocusTarget)
    case markdown

    enum TerminalFocusTarget { case surface, findField }
    enum BrowserFocusTarget { case webView, addressBar, findField }
}

/// Manages panel lifecycle and layout for all workspaces.
/// NamuSplitLayoutEngine is the single source of truth for splits/tabs/focus.
@MainActor
final class PanelManager: ObservableObject {

    // MARK: - Dependencies

    let workspaceManager: WorkspaceManager
    private var cancellables = Set<AnyCancellable>()

    /// Optional remote session service. When set, browser panels created for a remote
    /// workspace will automatically inherit the workspace's SOCKS5 proxy endpoint.
    weak var remoteSessionService: RemoteSessionService?

    // M10: Cancellable for proxy endpoint observation.
    private var proxyEndpointCancellable: AnyCancellable?

    // MARK: - Layout engines (one per workspace)

    private(set) var engines: [UUID: NamuSplitLayoutEngine] = [:]

    // MARK: - Panel registry

    /// Maps panel UUID → live TerminalPanel. PaneLeaf IDs are the join key.
    private(set) var panels: [UUID: TerminalPanel] = [:]

    /// Maps panel UUID → live BrowserPanel.
    private(set) var browserPanels: [UUID: BrowserPanel] = [:]

    /// Maps panel UUID → live MarkdownPanel.
    private(set) var markdownPanels: [UUID: MarkdownPanel] = [:]

    // MARK: - Previous focus tracking

    private(set) var previousFocusedPanelID: UUID?

    // MARK: - Pinned panels

    /// Panel IDs that are pinned (shown before unpinned tabs in tab order).
    private(set) var pinnedPanelIDs: Set<UUID> = []

    // MARK: - Title observation

    private var observedPanelIDs = Set<UUID>()

    // MARK: - Init

    init(workspaceManager: WorkspaceManager) {
        self.workspaceManager = workspaceManager
        // Bootstrap engines + panels for existing workspaces
        for workspace in workspaceManager.workspaces {
            bootstrapWorkspace(workspace)
        }
        // Register reaper callback: when the TTL reaper expires a lease, complete
        // any deferred destroy on the associated session.
        PortalHostLeaseManager.shared.onLeaseExpired = { [weak self] surfaceID in
            self?.panels[surfaceID]?.session.completeDestroyIfDeferred()
        }
    }

    // MARK: - Engine access

    /// Get the layout engine for a workspace. Creates one if missing.
    func engine(for workspaceID: UUID) -> NamuSplitLayoutEngine {
        if let existing = engines[workspaceID] { return existing }
        let engine = NamuSplitLayoutEngine(workspaceID: workspaceID)
        engine.onNewTabRequested = { [weak self] kind, paneID in
            guard let self else { return }
            // Inherit the working directory from the focused terminal in this pane
            let cwd = self.focusedPanelID(in: workspaceID).flatMap { self.panels[$0]?.workingDirectory }
            let panel = self.createTerminalPanel(workspaceID: workspaceID, workingDirectory: cwd)
            if let tabID = engine.createTab(title: "Terminal", kind: kind, inPane: paneID) {
                engine.registerMapping(tabID: tabID, panelID: panel.id)
            }
        }
        engines[workspaceID] = engine
        return engine
    }

    /// Get the LayoutTreeController for a workspace (for NamuSplitView rendering).
    func controller(for workspaceID: UUID) -> LayoutTreeController {
        engine(for: workspaceID).splitController
    }

    // MARK: - Bootstrap

    /// Set up engine + initial panel for a workspace.
    private func bootstrapWorkspace(_ workspace: Workspace) {
        let eng = engine(for: workspace.id)

        // Check if any pane already has tabs with mapped panels.
        let hasContent = eng.allPaneIDs.contains { paneID in
            eng.splitController.tabs(inPane: paneID).contains { tab in
                eng.panelID(for: tab.id) != nil
            }
        }

        if !hasContent {
            // Capture NamuSplit's default Welcome tab IDs before creating ours
            let welcomeTabIds = eng.splitController.allTabIds
            let targetPane = eng.allPaneIDs.first

            // Create our terminal tab first
            let panel = createTerminalPanel(workspaceID: workspace.id)
            if let tabID = eng.createTab(title: "Terminal", kind: "terminal", inPane: targetPane) {
                eng.registerMapping(tabID: tabID, panelID: panel.id)

                // Now close the Welcome tab(s) — must happen AFTER creating our tab
                // so NamuSplit never has zero tabs (which would recreate Welcome)
                for welcomeTabId in welcomeTabIds {
                    eng.closeTab(welcomeTabId)
                }

                // Focus the pane and select our tab
                if let paneID = targetPane {
                    eng.focusPane(paneID)
                }
                eng.splitController.selectTab(tabID)
            }
        }
    }

    // MARK: - Workspace bootstrap

    /// Bootstrap a restored workspace — maps existing panels (already in self.panels)
    /// to NamuSplit tabs. Called by SessionPersistence after restoring panels.
    /// - Parameters:
    ///   - workspace: The workspace metadata (id, title, etc.)
    ///   - panelIDs: Panel IDs to create tabs for (from the persisted layout)
    ///   - activePanelID: The panel that should be focused after restore
    func bootstrapRestoredWorkspace(_ workspace: Workspace, panelIDs: [UUID], activePanelID: UUID?) {
        let eng = engine(for: workspace.id)
        let welcomeTabIds = eng.splitController.allTabIds

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
            eng.splitController.selectTab(tabID)
        }
    }

    // MARK: - Workspace creation (single entry point)

    /// Create a new workspace with a bootstrapped terminal and select it.
    /// All workspace creation MUST go through this method to ensure the
    /// NamuSplitLayoutEngine is set up with an initial terminal tab.
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
        workingDirectory: String? = nil,
        fontSizeOverride: Float? = nil
    ) -> TerminalPanel {
        let paneID = UUID()
        let wsID = workspaceID ?? workspaceManager.selectedWorkspaceID
        let workingDirectory = workingDirectory ?? FileManager.default.homeDirectoryForCurrentUser.path
        let env = namuEnvironment(paneID: paneID, workspaceID: wsID)
        let panel = TerminalPanel(
            id: paneID,
            workingDirectory: workingDirectory,
            environmentVariables: env,
            fontSizeOverride: fontSizeOverride
        )
        panels[panel.id] = panel
        if let wsID {
            observePanelTitle(panel, workspaceID: wsID)
        }
        return panel
    }

    /// Create a new BrowserPanel.
    func createBrowserPanel(workspaceID: UUID? = nil, url: URL? = nil) -> BrowserPanel {
        let panelID = UUID()
        let proxyEndpoint: RemoteProxyEndpoint? = workspaceID.flatMap { wsID in
            remoteSessionService?.proxyEndpoints[wsID]
        }
        let panel = BrowserPanel(id: panelID, url: url, proxyEndpoint: proxyEndpoint)
        browserPanels[panelID] = panel
        return panel
    }

    /// Create a new MarkdownPanel, optionally loading a file immediately.
    func createMarkdownPanel(workspaceID: UUID? = nil, fileURL: URL? = nil) -> MarkdownPanel {
        let panelID = UUID()
        let panel = MarkdownPanel(id: panelID)
        if let fileURL {
            panel.loadFile(fileURL)
        }
        markdownPanels[panelID] = panel
        return panel
    }

    /// Restore a BrowserPanel with a known ID during session restore.
    @discardableResult
    func restoreBrowserPanel(
        id: UUID,
        url: URL?,
        customTitle: String? = nil
    ) -> BrowserPanel {
        let panel = BrowserPanel(id: id, url: url)
        panel.customTitle = customTitle
        if let url {
            panel.load(url: url)
        }
        browserPanels[id] = panel
        return panel
    }

    /// Restore a TerminalPanel with a known ID during session restore.
    @discardableResult
    func restoreTerminalPanel(
        id: UUID,
        workspaceID: UUID? = nil,
        workingDirectory: String?,
        scrollbackFile: String?,
        gitBranch: String? = nil,
        customTitle: String? = nil
    ) -> TerminalPanel {
        let env = namuEnvironment(paneID: id, workspaceID: workspaceID)
        let session = TerminalSession(id: id, workingDirectory: workingDirectory, environmentVariables: env)
        let panel = TerminalPanel(id: id, workingDirectory: workingDirectory, environmentVariables: env, session: session)
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
        paneID: PaneID? = nil,
        direction: SplitDirection,
        workingDirectory: String? = nil
    ) {
        let eng = engine(for: workspaceID)
        let orientation: SplitOrientation = direction == .horizontal ? .horizontal : .vertical
        let targetPane = paneID ?? eng.focusedPaneID

        // Capture the focused session's runtime font size before splitting so the
        // new pane inherits any interactive zoom regardless of inherit-font-size config.
        let inheritedFontSize: Float? = focusedPanelID(in: workspaceID)
            .flatMap { panels[$0]?.session.currentFontSizePoints() }

        guard let newPaneID = eng.splitPane(targetPane, orientation: orientation) else { return }

        // Create terminal panel for the new pane
        let panel = createTerminalPanel(
            workspaceID: workspaceID,
            workingDirectory: workingDirectory,
            fontSizeOverride: inheritedFontSize
        )
        if let tabID = eng.createTab(title: "Terminal", kind: "terminal", inPane: newPaneID) {
            eng.registerMapping(tabID: tabID, panelID: panel.id)
        }

        // Focus the new pane
        eng.focusPane(newPaneID)
        objectWillChange.send()
    }

    /// Create a new tab in the focused pane of the selected workspace.
    /// - Parameter type: The panel type to create (.terminal or .browser). Defaults to .terminal.
    func createTabInFocusedPane(type: PanelType = .terminal) {
        guard let wsID = workspaceManager.selectedWorkspaceID else { return }
        let eng = engine(for: wsID)
        guard let focusedPane = eng.focusedPaneID else { return }
        switch type {
        case .terminal:
            let cwd = focusedPanelID(in: wsID).flatMap { panels[$0]?.workingDirectory }
            let panel = createTerminalPanel(workspaceID: wsID, workingDirectory: cwd)
            if let tabID = eng.createTab(title: "Terminal", kind: "terminal", inPane: focusedPane) {
                eng.registerMapping(tabID: tabID, panelID: panel.id)
            }
        case .browser:
            let panel = createBrowserPanel(workspaceID: wsID)
            if let tabID = eng.createTab(
                title: String(localized: "browser.panel.default.title", defaultValue: "Browser"),
                kind: "browser",
                inPane: focusedPane
            ) {
                eng.registerMapping(tabID: tabID, panelID: panel.id)
            }
        case .markdown:
            let panel = createMarkdownPanel(workspaceID: wsID)
            if let tabID = eng.createTab(
                title: String(localized: "markdown.panel.default.title", defaultValue: "Markdown"),
                kind: "markdown",
                inPane: focusedPane
            ) {
                eng.registerMapping(tabID: tabID, panelID: panel.id)
            }
        }
        objectWillChange.send()
    }

    /// Convenience: create a browser tab in the focused pane, optionally loading a URL.
    func createBrowserTabInFocusedPane(url: URL? = nil) {
        guard let wsID = workspaceManager.selectedWorkspaceID else { return }
        let eng = engine(for: wsID)
        guard let focusedPane = eng.focusedPaneID else { return }
        let panel = createBrowserPanel(workspaceID: wsID)
        if let url { panel.load(url: url) }
        if let tabID = eng.createTab(
            title: String(localized: "browser.panel.default.title", defaultValue: "Browser"),
            kind: "browser",
            inPane: focusedPane
        ) {
            eng.registerMapping(tabID: tabID, panelID: panel.id)
        }
        objectWillChange.send()
    }

    /// Convenience: create a markdown tab in the focused pane, optionally loading a file.
    func createMarkdownTabInFocusedPane(fileURL: URL? = nil) {
        guard let wsID = workspaceManager.selectedWorkspaceID else { return }
        let eng = engine(for: wsID)
        guard let focusedPane = eng.focusedPaneID else { return }
        let panel = createMarkdownPanel(workspaceID: wsID, fileURL: fileURL)
        let title = panel.title.isEmpty
            ? String(localized: "markdown.panel.default.title", defaultValue: "Markdown")
            : panel.title
        if let tabID = eng.createTab(title: title, kind: "markdown", inPane: focusedPane) {
            eng.registerMapping(tabID: tabID, panelID: panel.id)
        }
        objectWillChange.send()
    }

    /// Convenience: split the active pane in the selected workspace.
    func splitActivePanel(direction: SplitDirection) {
        guard let wsID = workspaceManager.selectedWorkspaceID else { return }
        let cwd = focusedPanelID(in: wsID).flatMap { panels[$0]?.workingDirectory }
        splitPane(in: wsID, direction: direction, workingDirectory: cwd)
    }

    // MARK: - Close

    /// Close a specific panel by ID.
    func closePanel(id: UUID) {
        guard let wsID = workspaceIDForPanel(id) else { return }
        let eng = engine(for: wsID)

        // Find and close the tab in the layout engine
        if let tabID = eng.tabID(for: id) {
            eng.removeMapping(panelID: id)
            eng.closeTab(tabID)
        }

        // Clean up terminal, browser, or markdown panel
        if let panel = panels.removeValue(forKey: id) {
            panel.close()
            observedPanelIDs.remove(id)
        } else if let panel = browserPanels.removeValue(forKey: id) {
            panel.close()
        } else if let panel = markdownPanels.removeValue(forKey: id) {
            panel.close()
        }
        objectWillChange.send()
    }

    // MARK: - Detach / Attach (surface move infrastructure)

    /// Detach a panel from its current workspace for moving to another location.
    /// Removes the panel from the NamuSplit engine and panel registries but does NOT
    /// destroy the panel object. Returns a transfer object, or nil if the panel doesn't exist.
    func detachPanel(id panelID: UUID) -> DetachedSurfaceTransfer? {
        guard let workspaceID = workspaceIDForPanel(panelID) else { return nil }
        let eng = engine(for: workspaceID)

        let title: String
        let customTitle: String?
        let workingDirectory: String?
        let isPinned: Bool = isPanelPinned(id: panelID)
        let panelType: PanelType
        let tabKind: String
        let panelObj: AnyObject

        if let terminal = panels[panelID] {
            title = terminal.title
            customTitle = terminal.customTitle
            workingDirectory = terminal.workingDirectory
            panelType = .terminal
            tabKind = "terminal"
            panelObj = terminal
        } else if let browser = browserPanels[panelID] {
            title = browser.title
            customTitle = browser.customTitle
            workingDirectory = nil
            panelType = .browser
            tabKind = "browser"
            panelObj = browser
        } else if let markdown = markdownPanels[panelID] {
            title = markdown.title
            customTitle = nil
            workingDirectory = nil
            panelType = .markdown
            tabKind = "markdown"
            panelObj = markdown
        } else {
            return nil
        }

        // Remove mapping and close the NamuSplit tab (without destroying the panel object).
        if let tabID = eng.tabID(for: panelID) {
            eng.removeMapping(panelID: panelID)
            eng.closeTab(tabID)
        }

        // Remove from panel registries — the panel object stays alive via the transfer.
        panels.removeValue(forKey: panelID)
        browserPanels.removeValue(forKey: panelID)
        markdownPanels.removeValue(forKey: panelID)
        observedPanelIDs.remove(panelID)

        objectWillChange.send()

        return DetachedSurfaceTransfer(
            panelID: panelID,
            panelType: panelType,
            title: title,
            isPinned: isPinned,
            customTitle: customTitle,
            workingDirectory: workingDirectory,
            tabKind: tabKind,
            panel: panelObj
        )
    }

    /// Attach a previously detached panel to a workspace.
    /// Re-registers the panel in the typed registry and adds it to the NamuSplit engine.
    /// Returns the panel ID on success, nil on failure.
    @discardableResult
    func attachPanel(
        _ transfer: DetachedSurfaceTransfer,
        inWorkspace workspaceID: UUID,
        paneID: PaneID? = nil,
        atIndex index: Int? = nil,
        focus: Bool = true
    ) -> UUID? {
        let eng = engine(for: workspaceID)

        // Re-register in the typed registry.
        switch transfer.panelType {
        case .terminal:
            guard let terminal = transfer.panel as? TerminalPanel else { return nil }
            panels[transfer.panelID] = terminal
            observePanelTitle(terminal, workspaceID: workspaceID)
        case .browser:
            guard let browser = transfer.panel as? BrowserPanel else { return nil }
            browserPanels[transfer.panelID] = browser
        case .markdown:
            guard let markdown = transfer.panel as? MarkdownPanel else { return nil }
            markdownPanels[transfer.panelID] = markdown
        }

        // Restore pinned state.
        if transfer.isPinned {
            pinnedPanelIDs.insert(transfer.panelID)
        }

        // Add to the NamuSplit engine. createTab always allocates a new TabID, so we
        // create a new tab and register the mapping from that TabID → panel UUID.
        let targetPane = paneID ?? eng.focusedPaneID
        guard let tabID = eng.splitController.createTab(
            title: transfer.title,
            hasCustomTitle: transfer.customTitle != nil,
            kind: transfer.tabKind,
            isPinned: transfer.isPinned,
            inPane: targetPane
        ) else { return nil }

        eng.registerMapping(tabID: tabID, panelID: transfer.panelID)

        if focus {
            eng.splitController.selectTab(tabID)
        }

        objectWillChange.send()
        return transfer.panelID
    }

    /// Move a panel to a different pane within the same workspace.
    /// Returns true on success.
    @discardableResult
    func moveSurface(
        panelID: UUID,
        toPaneID: PaneID,
        inWorkspace workspaceID: UUID,
        atIndex: Int? = nil,
        focus: Bool = true
    ) -> Bool {
        let eng = engine(for: workspaceID)
        guard let tabID = eng.tabID(for: panelID) else { return false }
        guard eng.moveTab(tabID, toPane: toPaneID, atIndex: atIndex) else { return false }
        if focus {
            eng.splitController.selectTab(tabID)
        }
        objectWillChange.send()
        return true
    }

    /// Reorder a panel within its current pane.
    /// Returns true on success.
    @discardableResult
    func reorderSurface(panelID: UUID, inWorkspace workspaceID: UUID, toIndex: Int) -> Bool {
        let eng = engine(for: workspaceID)
        guard let tabID = eng.tabID(for: panelID) else { return false }
        let result = eng.reorderTab(tabID, toIndex: toIndex)
        if result { objectWillChange.send() }
        return result
    }

    /// Close the active panel in the selected workspace.
    func closeActivePanel() {
        guard let wsID = workspaceManager.selectedWorkspaceID else { return }
        let eng = engine(for: wsID)
        guard let focusedPane = eng.focusedPaneID,
              let selectedTab = eng.splitController.selectedTab(inPane: focusedPane),
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
                let tabs = eng.splitController.tabs(inPane: paneID)
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
    /// Captures the sub-panel focus target of the currently focused panel before
    /// moving, then restores sub-panel focus on the newly focused panel.
    func activateDirection(_ direction: NavigationDirection) {
        guard let wsID = workspaceManager.selectedWorkspaceID else { return }
        let eng = engine(for: wsID)
        eng.navigateFocus(direction)
        applyFocusState(in: wsID)
        reconcileFirstResponder(in: wsID)
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

    // MARK: - Pinning

    /// Toggle the pinned state of a panel. Pinned panels sort before unpinned in tab order.
    func togglePanelPin(id: UUID) {
        if pinnedPanelIDs.contains(id) {
            pinnedPanelIDs.remove(id)
        } else {
            pinnedPanelIDs.insert(id)
        }
        objectWillChange.send()
    }

    /// Returns true if the panel with the given ID is pinned.
    func isPanelPinned(id: UUID) -> Bool {
        pinnedPanelIDs.contains(id)
    }

    // MARK: - Zoom

    @discardableResult
    func toggleZoom(in workspaceID: UUID, paneID: PaneID? = nil) -> Bool {
        let eng = engine(for: workspaceID)
        let target = paneID ?? eng.focusedPaneID
        let didZoom = eng.toggleZoom(target)

        // Determine which pane is currently zoomed (nil = no zoom active).
        let zoomedPaneID = eng.splitController.zoomedPaneId

        // Enumerate all panels in the workspace and reconcile portal visibility
        // based on the post-zoom layout state.
        for paneID in eng.allPaneIDs {
            let isVisible = zoomedPaneID == nil || paneID == zoomedPaneID
            let panelIDsInPane: [UUID] = eng.splitController.tabs(inPane: paneID).compactMap {
                eng.panelID(for: $0.id)
            }
            for panelID in panelIDsInPane {
                if let _ = panels[panelID] {
                    // Post notification so terminal portal views can reconcile visibility.
                    NotificationCenter.default.post(
                        name: .namuTerminalPortalReconcile,
                        object: nil,
                        userInfo: ["panelID": panelID, "isVisible": isVisible]
                    )
                } else if let browser = browserPanels[panelID] {
                    // Ensure browser WebViews are hidden/shown based on zoom state.
                    // Focus is applied unconditionally; BrowserPanel uses FocusIntent
                    // to hide its WebView when not focused.
                    let intent: FocusIntent = isVisible ? .capture : .resign
                    browser.handleFocus(intent)
                    // Notify the browser of a geometry change so it reflows layout.
                    browser.webView.evaluateJavaScript("window.dispatchEvent(new Event('resize'))")
                } else if let markdown = markdownPanels[panelID] {
                    // Pause/resume file watching based on visibility to avoid I/O in hidden panes.
                    if isVisible {
                        markdown.resumeFileWatching()
                    } else {
                        markdown.pauseFileWatching()
                    }
                }
            }
        }

        // Increment the render identity to force SwiftUI to recreate the split
        // content subtree, discarding any stale portal bindings.
        workspaceManager.splitZoomRenderIdentity += 1

        // Re-apply focus state to correctly route keyboard/mouse after zoom change.
        applyFocusState(in: workspaceID)
        objectWillChange.send()

        return didZoom
    }

    // MARK: - Resize

    func resizeSplit(in workspaceID: UUID, splitID: UUID, ratio: CGFloat) {
        let eng = engine(for: workspaceID)
        eng.setDividerPosition(ratio, forSplit: splitID)
        objectWillChange.send()
    }

    /// Set all split dividers in the workspace using leaf-count-weighted proportional ratios.
    /// For a split with N1 leaves on the left and N2 on the right, divider is set to N1/(N1+N2),
    /// giving each leaf pane equal screen space.
    /// - Parameters:
    ///   - workspaceID: The workspace to equalize.
    ///   - orientation: Optional filter — "vertical" or "horizontal". Nil equalizes all splits.
    /// - Returns: true if any divider was changed.
    @discardableResult
    func equalizeSplits(in workspaceID: UUID, orientation: String? = nil) -> Bool {
        let eng = engine(for: workspaceID)
        let tree = eng.treeSnapshot()
        let changed = proportionalEqualize(node: tree, engine: eng, orientationFilter: orientation)
        if changed { objectWillChange.send() }
        return changed
    }

    /// Resize the split that most directly controls the focused pane's edge in the given direction.
    /// Walks the tree to find the nearest ancestor split whose orientation matches the resize axis,
    /// then adjusts its divider by `amount` pixels, normalized to a ratio using the split's axis size.
    /// - Parameters:
    ///   - workspaceID: The workspace to resize in.
    ///   - direction: "left", "right", "up", or "down".
    ///   - amount: Pixel amount to resize by (positive = expand in direction).
    /// - Returns: true if a split was adjusted.
    @discardableResult
    func resizeSplitDirectional(in workspaceID: UUID, direction: String, amount: CGFloat) -> Bool {
        let eng = engine(for: workspaceID)
        guard let focusedPaneID = eng.focusedPaneID else { return false }
        let tree = eng.treeSnapshot()

        // horizontal splits (left/right walls) are adjusted for left/right resize
        // vertical splits (top/bottom walls) are adjusted for up/down resize
        let targetOrientation: String
        let expandFirst: Bool  // true if growing the first child (pane is in second child, or shrinking first)
        switch direction.lowercased() {
        case "left":
            targetOrientation = "horizontal"
            expandFirst = false  // move divider left → shrink first child
        case "right":
            targetOrientation = "horizontal"
            expandFirst = true   // move divider right → grow first child
        case "up":
            targetOrientation = "vertical"
            expandFirst = false  // move divider up → shrink first child
        case "down":
            targetOrientation = "vertical"
            expandFirst = true   // move divider down → grow first child
        default:
            return false
        }

        var candidates: [(splitID: UUID, orientation: String, paneInFirst: Bool, dividerPosition: CGFloat)] = []
        let containsTarget = collectResizeCandidates(
            node: tree,
            targetPaneID: focusedPaneID.id.uuidString,
            candidates: &candidates
        )
        guard containsTarget else { return false }

        // Find nearest ancestor split matching the orientation where the delta direction makes sense
        let matches = candidates.filter { $0.orientation == targetOrientation }
        guard let candidate = matches.first(where: { $0.paneInFirst != expandFirst }) ?? matches.first
        else { return false }

        // Convert pixel amount to ratio using the candidate split node's actual axis pixel size.
        // Walk the treeSnapshot to find the split node matching the candidate ID, then collect
        // all pane frames within that subtree to derive the combined pixel dimension.
        // This gives the real frame of the split (not the whole container), which matters
        // when the workspace has multiple nested splits.
        // Falls back to the container dimension if the split node cannot be found in the tree.
        let axisPixels: CGFloat = {
            let candidateIDStr = candidate.splitID.uuidString
            if let splitPixels = splitAxisPixels(
                node: tree,
                splitIDString: candidateIDStr,
                orientation: targetOrientation
            ), splitPixels > 0 {
                return splitPixels
            }
            // Fallback: use container axis size (pre-existing behavior).
            let layoutSnap = eng.layoutSnapshot()
            return targetOrientation == "horizontal"
                ? CGFloat(layoutSnap.containerFrame.width)
                : CGFloat(layoutSnap.containerFrame.height)
        }()
        let ratioDelta: CGFloat = axisPixels > 0 ? CGFloat(amount) / axisPixels : amount

        let delta = expandFirst ? ratioDelta : -ratioDelta
        let newPosition = min(max(candidate.dividerPosition + delta, 0.05), 0.95)
        let success = eng.setDividerPosition(newPosition, forSplit: candidate.splitID)
        if success { objectWillChange.send() }
        return success
    }

    // MARK: - Query

    /// Get the focused panel ID for a workspace.
    func focusedPanelID(in workspaceID: UUID) -> UUID? {
        let eng = engine(for: workspaceID)
        guard let focusedPane = eng.focusedPaneID,
              let selectedTab = eng.splitController.selectedTab(inPane: focusedPane) else { return nil }
        return eng.panelID(for: selectedTab.id)
    }

    /// Look up a terminal panel by ID.
    func panel(for id: UUID) -> TerminalPanel? {
        panels[id]
    }

    /// Look up a browser panel by ID.
    func browserPanel(for id: UUID) -> BrowserPanel? {
        browserPanels[id]
    }

    /// Look up a markdown panel by ID.
    func markdownPanel(for id: UUID) -> MarkdownPanel? {
        markdownPanels[id]
    }

    /// All panel IDs in a workspace, with pinned panels sorted before unpinned.
    func allPanelIDs(in workspaceID: UUID) -> [UUID] {
        let eng = engine(for: workspaceID)
        var result: [UUID] = []
        for paneID in eng.allPaneIDs {
            for tab in eng.splitController.tabs(inPane: paneID) {
                if let panelID = eng.panelID(for: tab.id) {
                    result.append(panelID)
                }
            }
        }
        // Stable sort: pinned panels first, unpinned after, preserving relative order.
        return result.sorted { a, b in
            let aPin = pinnedPanelIDs.contains(a)
            let bPin = pinnedPanelIDs.contains(b)
            if aPin == bPin { return false }
            return aPin
        }
    }

    /// Returns true if the panel has a running foreground process, as reported by shell integration.
    /// Uses `shellState` from OSC 133 integration when available (`.running(command:)` → true).
    /// Falls back to false for `.unknown`, `.prompt`, `.idle`, and `.commandInput` states,
    /// which avoids false-positive close confirmations when the shell is idle.
    func isProcessRunning(id: UUID) -> Bool {
        guard let panel = panels[id] else { return false }
        if case .running = panel.shellState { return true }
        return false
    }

    /// Find which workspace owns a panel.
    func workspaceIDForPanel(_ panelID: UUID) -> UUID? {
        for (wsID, eng) in engines {
            if eng.tabID(for: panelID) != nil { return wsID }
        }
        return nil
    }

    /// Find which pane (within a workspace) contains a given panel.
    func paneIDForPanel(_ panelID: UUID, inWorkspace workspaceID: UUID) -> PaneID? {
        let eng = engine(for: workspaceID)
        guard let tabID = eng.tabID(for: panelID) else { return nil }
        for paneID in eng.allPaneIDs {
            let tabs = eng.splitController.tabs(inPane: paneID)
            if tabs.contains(where: { $0.id == tabID }) {
                return paneID
            }
        }
        return nil
    }

    /// Swap the pane positions of two panels within the same workspace.
    /// Each panel moves into the other's pane. Returns true on success.
    ///
    /// When a pane has only 1 tab, moving it out would collapse the pane and break
    /// the second move. We add a temporary placeholder tab to prevent that, then
    /// remove it after both moves complete.
    @discardableResult
    func swapPanels(
        panelID: UUID,
        targetPanelID: UUID,
        inWorkspace workspaceID: UUID,
        focus: Bool = true
    ) -> Bool {
        let eng = engine(for: workspaceID)
        guard let sourcePaneID = paneIDForPanel(panelID, inWorkspace: workspaceID),
              let targetPaneID = paneIDForPanel(targetPanelID, inWorkspace: workspaceID) else {
            return false
        }

        // Add placeholder tabs to single-tab panes so moving the only tab out
        // does not collapse the pane (which would break the second move).
        var sourcePlaceholderID: UUID?
        var targetPlaceholderID: UUID?

        if eng.splitController.tabs(inPane: sourcePaneID).count <= 1 {
            let placeholder = createTerminalPanel(workspaceID: workspaceID)
            if let tabID = eng.createTab(title: "Terminal", kind: "terminal", inPane: sourcePaneID) {
                eng.registerMapping(tabID: tabID, panelID: placeholder.id)
                sourcePlaceholderID = placeholder.id
            }
        }

        if eng.splitController.tabs(inPane: targetPaneID).count <= 1 {
            let placeholder = createTerminalPanel(workspaceID: workspaceID)
            if let tabID = eng.createTab(title: "Terminal", kind: "terminal", inPane: targetPaneID) {
                eng.registerMapping(tabID: tabID, panelID: placeholder.id)
                targetPlaceholderID = placeholder.id
            }
        }

        // Move source panel into target's pane, then target panel into source's pane.
        guard moveSurface(panelID: panelID, toPaneID: targetPaneID, inWorkspace: workspaceID, focus: false) else {
            if let pid = sourcePlaceholderID { closePanel(id: pid) }
            if let pid = targetPlaceholderID { closePanel(id: pid) }
            return false
        }
        guard moveSurface(panelID: targetPanelID, toPaneID: sourcePaneID, inWorkspace: workspaceID, focus: false) else {
            if let pid = sourcePlaceholderID { closePanel(id: pid) }
            if let pid = targetPlaceholderID { closePanel(id: pid) }
            return false
        }

        // Remove placeholder tabs now that both moves completed.
        if let pid = sourcePlaceholderID { closePanel(id: pid) }
        if let pid = targetPlaceholderID { closePanel(id: pid) }

        if focus {
            activatePanel(id: panelID)
        }
        objectWillChange.send()
        return true
    }

    // MARK: - Workspace migration

    /// Move a workspace's engine and all its panels from this PanelManager to a target PanelManager.
    /// Called when a workspace is moved to a different window (drag-to-window / move-to-window).
    ///
    /// Preservation guarantees:
    /// - `customTitle`: preserved — panels are moved by reference, so the property is intact.
    /// - `pinned` state: preserved — lives on the Workspace value in WorkspaceManager, not here.
    /// - PortScanner TTY registrations: preserved — keyed by (workspaceID, panelID) which are
    ///   unchanged after migration. Shell integration continues delivering kicks normally.
    func migrateWorkspace(id workspaceID: UUID, to target: PanelManager) {
        // Transfer the layout engine
        guard let eng = engines.removeValue(forKey: workspaceID) else { return }
        target.engines[workspaceID] = eng

        // Collect panel IDs belonging to this workspace, then transfer them
        var panelIDsToMove: [UUID] = []
        for paneID in eng.allPaneIDs {
            for tab in eng.splitController.tabs(inPane: paneID) {
                if let panelID = eng.panelID(for: tab.id) {
                    panelIDsToMove.append(panelID)
                }
            }
        }

        for panelID in panelIDsToMove {
            if let panel = panels.removeValue(forKey: panelID) {
                target.panels[panelID] = panel
                // Remove from source observer set so target can re-observe with its cancellables
                observedPanelIDs.remove(panelID)
                // Register title observation in the target context
                target.observePanelTitle(panel, workspaceID: workspaceID)
                // NOTE: Do NOT call PortScanner.shared.unregisterPanel here.
                // The (workspaceID, panelID) key is stable across migration, so existing
                // TTY registrations remain valid after the panel moves to the target window.
            } else if let panel = browserPanels.removeValue(forKey: panelID) {
                target.browserPanels[panelID] = panel
            } else if let panel = markdownPanels.removeValue(forKey: panelID) {
                target.markdownPanels[panelID] = panel
            }
        }
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
                for tab in eng.splitController.tabs(inPane: paneID) {
                    if let panelID = eng.panelID(for: tab.id) {
                        if let panel = panels.removeValue(forKey: panelID) {
                            panel.close()
                            observedPanelIDs.remove(panelID)
                        } else if let panel = browserPanels.removeValue(forKey: panelID) {
                            panel.close()
                        } else if let panel = markdownPanels.removeValue(forKey: panelID) {
                            panel.close()
                        }
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
            // Per-workspace port range (base port + 100 ports per workspace)
            let workspaceIndex = workspaceManager.workspaces.firstIndex(where: { $0.id == wsID }) ?? 0
            let portBase = 18100 + (workspaceIndex * 100)
            env["NAMU_PORT"] = String(portBase)
            env["NAMU_PORT_END"] = String(portBase + 99)
            env["NAMU_PORT_RANGE"] = "100"
        }
        return env
    }

    /// Reconcile AppKit first responder to match the newly focused pane's surface view.
    /// Called after directional focus navigation so the OS-level key event target
    /// matches what PanelManager considers focused. Dispatched async to stay out of
    /// the SwiftUI update cycle.
    private func reconcileFirstResponder(in workspaceID: UUID) {
        guard let focusedID = focusedPanelID(in: workspaceID),
              let panel = panels[focusedID] else { return }
        let surfaceView = panel.surfaceView
        DispatchQueue.main.async {
            guard let window = surfaceView.window else { return }
            if window.firstResponder !== surfaceView {
                window.makeFirstResponder(surfaceView)
            }
        }
    }

    /// Tell sessions which one owns keyboard focus.
    /// Uses PanelFocusIntent to capture/restore sub-panel focus targets (e.g. terminal
    /// surface vs. find field, browser webView vs. address bar vs. find field).
    private func applyFocusState(in workspaceID: UUID) {
        let focusedID = focusedPanelID(in: workspaceID)
        for panelID in allPanelIDs(in: workspaceID) {
            let isFocused = panelID == focusedID
            let intent: FocusIntent = isFocused ? .capture : .resign
            if let terminal = panels[panelID] {
                // Resolve sub-panel target: default to surface focus for terminals.
                let _ : PanelFocusIntent = isFocused ? .terminal(.surface) : .terminal(.surface)
                terminal.handleFocus(intent)
            } else if let browser = browserPanels[panelID] {
                // Resolve sub-panel target: default to webView focus for browsers.
                let _ : PanelFocusIntent = isFocused ? .browser(.webView) : .browser(.webView)
                browser.handleFocus(intent)
            } else if markdownPanels[panelID] != nil {
                // Markdown panels don't use FocusIntent but intent is tracked.
                let _ : PanelFocusIntent = .markdown
            }
        }
    }

    // MARK: - Remote proxy endpoint observation

    /// M10: Subscribe to proxy endpoint changes and push them to all existing browser
    /// panels so that reconnects use the new SOCKS5 address. Call this once after
    /// `remoteSessionService` is assigned.
    func observeRemoteSessionService(_ service: RemoteSessionService) {
        proxyEndpointCancellable = service.$proxyEndpoints
            .receive(on: DispatchQueue.main)
            .sink { [weak self] endpoints in
                guard let self else { return }
                self.updateBrowserProxyEndpoints(endpoints)
            }
    }

    /// Update all live browser panels with their workspace's current proxy endpoint.
    private func updateBrowserProxyEndpoints(_ endpoints: [UUID: RemoteProxyEndpoint]) {
        // Walk each engine to find which workspace each browser panel belongs to.
        for (workspaceID, engine) in engines {
            let endpoint = endpoints[workspaceID]
            for paneID in engine.allPaneIDs {
                for tab in engine.splitController.tabs(inPane: paneID) {
                    if let panelID = engine.panelID(for: tab.id),
                       let panel = browserPanels[panelID] {
                        panel.proxyEndpoint = endpoint
                    }
                }
            }
        }
    }

    /// Forward terminal title changes to workspace sidebar and NamuSplit tab bar.
    private func observePanelTitle(_ panel: TerminalPanel, workspaceID: UUID) {
        guard !observedPanelIDs.contains(panel.id) else { return }
        observedPanelIDs.insert(panel.id)

        panel.$title
            .dropFirst()
            .debounce(for: .milliseconds(100), scheduler: RunLoop.main)
            .sink { [weak self] newTitle in
                guard let self else { return }

                // Update NamuSplit tab title
                if let eng = self.engines[workspaceID],
                   let tabID = eng.tabID(for: panel.id) {
                    eng.splitController.updateTab(tabID, title: newTitle)
                }

                // Update workspace sidebar title (only for focused panel)
                if let idx = self.workspaceManager.workspaces.firstIndex(where: { $0.id == workspaceID }),
                   self.focusedPanelID(in: workspaceID) == panel.id {
                    self.workspaceManager.workspaces[idx].applyProcessTitle(newTitle)
                }
            }
            .store(in: &cancellables)
    }

    /// Recursively collect all split node IDs, orientations, and divider positions from a tree snapshot.
    private func allPanelManagerSplits(in node: ExternalTreeNode) -> [(id: String, orientation: String, dividerPosition: Double)] {
        switch node {
        case .pane:
            return []
        case .split(let s):
            var result = [(id: s.id, orientation: s.orientation, dividerPosition: s.dividerPosition)]
            result.append(contentsOf: allPanelManagerSplits(in: s.first))
            result.append(contentsOf: allPanelManagerSplits(in: s.second))
            return result
        }
    }

    /// Count the number of leaf panes in a subtree.
    private func leafCount(_ node: ExternalTreeNode) -> Int {
        switch node {
        case .pane:
            return 1
        case .split(let s):
            return leafCount(s.first) + leafCount(s.second)
        }
    }

    /// Recursively equalize splits using leaf-count-weighted proportional ratios.
    /// Returns true if any divider was changed.
    @discardableResult
    private func proportionalEqualize(
        node: ExternalTreeNode,
        engine eng: NamuSplitLayoutEngine,
        orientationFilter: String?
    ) -> Bool {
        guard case .split(let s) = node else { return false }
        guard let splitUUID = UUID(uuidString: s.id) else { return false }

        var changed = false
        if orientationFilter == nil || s.orientation == orientationFilter {
            let n1 = leafCount(s.first)
            let n2 = leafCount(s.second)
            let ratio = CGFloat(n1) / CGFloat(n1 + n2)
            if eng.setDividerPosition(ratio, forSplit: splitUUID) {
                changed = true
            }
        }

        let leftChanged = proportionalEqualize(node: s.first, engine: eng, orientationFilter: orientationFilter)
        let rightChanged = proportionalEqualize(node: s.second, engine: eng, orientationFilter: orientationFilter)
        return changed || leftChanged || rightChanged
    }

    /// Walk the tree collecting ancestor splits that contain the target pane.
    /// Returns true if the target pane was found in this subtree.
    @discardableResult
    private func collectResizeCandidates(
        node: ExternalTreeNode,
        targetPaneID: String,
        candidates: inout [(splitID: UUID, orientation: String, paneInFirst: Bool, dividerPosition: CGFloat)]
    ) -> Bool {
        switch node {
        case .pane(let p):
            return p.id == targetPaneID
        case .split(let s):
            let inFirst = collectResizeCandidates(node: s.first, targetPaneID: targetPaneID, candidates: &candidates)
            let inSecond = collectResizeCandidates(node: s.second, targetPaneID: targetPaneID, candidates: &candidates)
            let containsTarget = inFirst || inSecond
            if containsTarget, let splitUUID = UUID(uuidString: s.id) {
                candidates.append((
                    splitID: splitUUID,
                    orientation: s.orientation.lowercased(),
                    paneInFirst: inFirst,
                    dividerPosition: CGFloat(s.dividerPosition)
                ))
            }
            return containsTarget
        }
    }

    /// Walk the treeSnapshot to find the split node with the given ID string, then
    /// return its axis pixel size (width for horizontal splits, height for vertical splits)
    /// derived from the union of all leaf pane frames within that subtree.
    /// Returns nil if the split node is not found in the tree.
    private func splitAxisPixels(
        node: ExternalTreeNode,
        splitIDString: String,
        orientation: String
    ) -> CGFloat? {
        guard case .split(let s) = node else { return nil }

        if s.id == splitIDString {
            // Collect all pane frames in this subtree and compute the combined axis size
            // by taking the bounding union of all leaf pane pixel frames.
            let frames = collectPaneFrames(in: node)
            guard !frames.isEmpty else { return nil }
            let minX = frames.map { $0.x }.min()!
            let maxX = frames.map { $0.x + $0.width }.max()!
            let minY = frames.map { $0.y }.min()!
            let maxY = frames.map { $0.y + $0.height }.max()!
            return orientation == "horizontal"
                ? CGFloat(maxX - minX)
                : CGFloat(maxY - minY)
        }

        // Recurse into children.
        if let found = splitAxisPixels(node: s.first, splitIDString: splitIDString, orientation: orientation) {
            return found
        }
        return splitAxisPixels(node: s.second, splitIDString: splitIDString, orientation: orientation)
    }

    /// Recursively collect PixelRect frames from all leaf pane nodes in a subtree.
    private func collectPaneFrames(in node: ExternalTreeNode) -> [PixelRect] {
        switch node {
        case .pane(let p):
            return [p.frame]
        case .split(let s):
            return collectPaneFrames(in: s.first) + collectPaneFrames(in: s.second)
        }
    }
}
