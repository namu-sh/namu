import Foundation
import Combine

// MARK: - Pane Context

struct PaneContext: Sendable {
    let id: String
    let workingDirectory: String?
    let gitBranch: String?
    let isFocused: Bool
}

// MARK: - Workspace Context

struct WorkspaceContext: Sendable {
    let id: String
    let title: String
    let isPinned: Bool
    let isSelected: Bool
    let panes: [PaneContext]
}

// MARK: - ContextSnapshot

struct ContextSnapshot: Sendable {
    let workspaces: [WorkspaceContext]
    let timestamp: Date

    /// Compact text representation for injection into the LLM system prompt.
    func compactDescription() -> String {
        var lines: [String] = []
        lines.append("Current state — \(workspaces.count) workspace(s):")
        for ws in workspaces {
            let selectedMark = ws.isSelected ? " [active]" : ""
            let pinnedMark = ws.isPinned ? " [pinned]" : ""
            lines.append("  Workspace \"\(ws.title)\"\(selectedMark)\(pinnedMark) (id: \(ws.id))")
            if ws.panes.isEmpty {
                lines.append("    (no panes)")
            }
            for pane in ws.panes {
                let focusMark = pane.isFocused ? " [focused]" : ""
                let cwd = pane.workingDirectory ?? "unknown"
                let branch = pane.gitBranch.map { " [\($0)]" } ?? ""
                lines.append("    Pane \(pane.id)\(focusMark): \(cwd)\(branch)")
            }
        }
        return lines.joined(separator: "\n")
    }
}

// MARK: - ContextCollector

/// Subscribes to WorkspaceManager and PanelManager to build a live snapshot
/// of workspace/pane state for injection into the LLM context.
@MainActor
final class ContextCollector: ObservableObject {

    @Published private(set) var snapshot: ContextSnapshot = ContextSnapshot(workspaces: [], timestamp: Date())

    private let workspaceManager: WorkspaceManager
    private let panelManager: PanelManager
    private let eventBus: EventBus
    private var cancellables = Set<AnyCancellable>()
    private var eventBusSubscriptionID: UUID?

    init(workspaceManager: WorkspaceManager, panelManager: PanelManager, eventBus: EventBus) {
        self.workspaceManager = workspaceManager
        self.panelManager = panelManager
        self.eventBus = eventBus
        subscribeToManagers()
        subscribeToEventBus()
        refresh()
    }

    deinit {
        if let id = eventBusSubscriptionID {
            eventBus.unsubscribe(id)
        }
    }

    // MARK: - Refresh

    func refresh() {
        let workspaces = workspaceManager.workspaces
        let selectedID = workspaceManager.selectedWorkspaceID

        let wsContexts: [WorkspaceContext] = workspaces.map { ws in
            let panels = ws.allPanels
            let paneContexts: [PaneContext] = panels.map { leaf in
                let panel = panelManager.panel(for: leaf.id)
                let isFocused = ws.focusedPanelID == leaf.id
                return PaneContext(
                    id: leaf.id.uuidString,
                    workingDirectory: panel?.workingDirectory,
                    gitBranch: panel?.gitBranch,
                    isFocused: isFocused
                )
            }
            return WorkspaceContext(
                id: ws.id.uuidString,
                title: ws.title,
                isPinned: ws.isPinned,
                isSelected: ws.id == selectedID,
                panes: paneContexts
            )
        }

        snapshot = ContextSnapshot(workspaces: wsContexts, timestamp: Date())
    }

    // MARK: - Private

    private func subscribeToManagers() {
        workspaceManager.$workspaces
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &cancellables)

        workspaceManager.$selectedWorkspaceID
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &cancellables)
    }

    private func subscribeToEventBus() {
        let id = eventBus.subscribe(events: [.workspaceChange]) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refresh()
            }
        }
        eventBusSubscriptionID = id
    }
}
