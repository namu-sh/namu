import Foundation

/// Protocol for executing custom commands. Enables testing without real terminal.
@MainActor
protocol CommandExecuting {
    /// Send a shell command string to the focused terminal pane.
    func sendToFocusedTerminal(_ text: String)
    /// Create a new workspace with the given name, color, and layout.
    func createWorkspace(name: String?, color: String?, cwd: String?)
    /// Check if a workspace with the given name already exists.
    func workspaceExists(name: String) -> Bool
    /// Delete a workspace by name.
    func deleteWorkspace(name: String)
}

/// Executes custom commands from namu.json config.
@MainActor
final class CommandExecutor {

    private let target: any CommandExecuting
    private let configLoader: ProjectConfigLoader

    init(target: any CommandExecuting, configLoader: ProjectConfigLoader) {
        self.target = target
        self.configLoader = configLoader
    }

    /// Execute a command definition. Returns false if execution was skipped.
    @discardableResult
    func execute(_ command: CommandDefinition, configPath: String?) -> Bool {
        // Handle restart behavior if workspace already exists.
        if let wsName = command.workspace?.name ?? command.name as String?,
           target.workspaceExists(name: wsName) {
            switch command.restart ?? .recreate {
            case .ignore:
                return false
            case .confirm:
                // Caller (UI layer) should show confirmation before calling execute.
                // If we get here, proceed with recreate.
                target.deleteWorkspace(name: wsName)
            case .recreate:
                target.deleteWorkspace(name: wsName)
            }
        }

        // Handle confirmation for untrusted directories.
        if command.confirm == true, let path = configPath {
            if !DirectoryTrust.shared.isTrusted(configPath: path) {
                // Caller (UI layer) should show confirmation dialog.
                // This check is a safety net — the UI should prevent reaching here.
                return false
            }
        }

        if command.workspace != nil {
            executeWorkspaceCommand(command)
        } else if let shellCmd = command.command {
            target.sendToFocusedTerminal(shellCmd + "\n")
        }

        return true
    }

    private func executeWorkspaceCommand(_ command: CommandDefinition) {
        guard let ws = command.workspace else { return }
        target.createWorkspace(
            name: ws.name ?? command.name,
            color: ws.color,
            cwd: ws.cwd
        )
        // Layout-based workspace creation (split panes) deferred until needed.
    }
}

// MARK: - PanelManager + WorkspaceManager adapter

/// Bridges PanelManager/WorkspaceManager to the CommandExecuting protocol.
@MainActor
final class NamuCommandTarget: CommandExecuting {

    private let workspaceManager: WorkspaceManager
    private let panelManager: PanelManager

    init(workspaceManager: WorkspaceManager, panelManager: PanelManager) {
        self.workspaceManager = workspaceManager
        self.panelManager = panelManager
    }

    func sendToFocusedTerminal(_ text: String) {
        guard let ws = workspaceManager.selectedWorkspace,
              let focusedID = ws.activePanelID,
              let panel = panelManager.panel(for: focusedID) else { return }
        panel.session.sendText(text)
    }

    func createWorkspace(name: String?, color: String?, cwd: String?) {
        let ws = workspaceManager.createWorkspace(title: name ?? "New Workspace")
        if let color {
            workspaceManager.setWorkspaceColor(id: ws.id, color: color)
        }
        workspaceManager.selectWorkspace(id: ws.id)
    }

    func workspaceExists(name: String) -> Bool {
        workspaceManager.workspaces.contains { $0.title == name || $0.customTitle == name }
    }

    func deleteWorkspace(name: String) {
        guard let ws = workspaceManager.workspaces.first(where: { $0.title == name || $0.customTitle == name }) else { return }
        workspaceManager.deleteWorkspace(id: ws.id)
    }
}
