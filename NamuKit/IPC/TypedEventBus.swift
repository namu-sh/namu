import Foundation

// MARK: - Typed App Events

/// Strongly-typed events replacing string-based NotificationCenter usage.
/// New code (Phases 1-5) uses these exclusively. Existing EventBus is kept
/// for socket JSON-RPC notification subscriptions during migration.
indirect enum AppEvent: Sendable {
    // Terminal lifecycle
    case terminalExited(panelID: UUID, exitCode: Int32)
    case shellStateChanged(panelID: UUID, state: ShellState)
    case titleChanged(panelID: UUID, title: String)
    case pwdChanged(panelID: UUID, path: String)

    // Layout
    case paneCreated(panelID: UUID, workspaceID: UUID)
    case paneClosed(panelID: UUID, workspaceID: UUID)
    case focusChanged(workspaceID: UUID, from: UUID?, to: UUID?)
    case layoutChanged(workspaceID: UUID, snapshot: NamuLayoutSnapshot)

    // Workspace
    case workspaceCreated(id: UUID)
    case workspaceDeleted(id: UUID)
    case workspaceSelected(id: UUID)

    // External integrations
    case portChanged(panelID: UUID, ports: [UInt16])
}

// MARK: - TypedEventBus

/// Actor-isolated typed event bus using AsyncStream for subscribers.
/// Runs alongside the existing EventBus during migration.
actor TypedEventBus {
    private var continuations: [UUID: AsyncStream<AppEvent>.Continuation] = [:]

    /// Subscribe to all app events. Returns an AsyncStream that yields events.
    func subscribe() -> AsyncStream<AppEvent> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<AppEvent>.makeStream()
        continuations[id] = continuation
        continuation.onTermination = { [weak self] _ in
            guard let self else { return }
            Task { await self.removeContinuation(id: id) }
        }
        return stream
    }

    /// Publish an event to all active subscribers.
    func publish(_ event: AppEvent) {
        for (_, continuation) in continuations {
            continuation.yield(event)
        }
    }

    // MARK: - Private

    private func removeContinuation(id: UUID) {
        continuations.removeValue(forKey: id)
    }
}
