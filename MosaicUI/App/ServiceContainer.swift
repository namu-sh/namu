import Foundation
import os.log

private let logger = Logger(subsystem: "com.mosaic.app", category: "ServiceContainer")

/// Centralised holder for long-lived services that outlive any single view.
///
/// Created once per app run.  `start()` is called from ContentView's `onAppear`
/// (after WorkspaceManager/PanelManager exist), and `stop()` from
/// `applicationWillTerminate`.
@MainActor
final class ServiceContainer {

    // MARK: - Core (owned by SwiftUI, passed in)

    let workspaceManager: WorkspaceManager
    let panelManager: PanelManager

    // MARK: - IPC

    let eventBus: EventBus
    let commandRegistry: CommandRegistry
    let accessController: AccessController
    let commandDispatcher: CommandDispatcher
    private(set) var socketServer: SocketServer?

    // MARK: - Persistence

    let sessionPersistence: SessionPersistence

    // MARK: - Notifications & Alerts

    let notificationService: NotificationService
    let alertEngine: AlertEngine

    // MARK: - AI

    let conversationManager: ConversationManager
    let commandSafety: CommandSafety
    let contextCollector: ContextCollector
    let mosaicAI: MosaicAI

    // MARK: - Command handlers (retained to keep weak-self closures alive)

    private var workspaceCommands: WorkspaceCommands?
    private var paneCommands: PaneCommands?
    private var surfaceCommands: SurfaceCommands?
    private var notificationCommands: NotificationCommands?
    private var browserCommands: BrowserCommands?
    private var systemCommands: SystemCommands?
    private var aiCommands: AICommands?

    // MARK: - Init

    init(workspaceManager: WorkspaceManager, panelManager: PanelManager) {
        self.workspaceManager = workspaceManager
        self.panelManager = panelManager

        // IPC infrastructure
        eventBus = EventBus()
        commandRegistry = CommandRegistry()
        accessController = AccessController(mode: .allowAll)
        commandDispatcher = CommandDispatcher(registry: commandRegistry)

        // Persistence
        sessionPersistence = SessionPersistence(
            workspaceManager: workspaceManager,
            panelManager: panelManager
        )

        // Notifications
        notificationService = NotificationService()

        // Alerts
        alertEngine = AlertEngine(eventBus: eventBus)

        // AI
        conversationManager = ConversationManager()
        commandSafety = CommandSafety()
        contextCollector = ContextCollector(
            workspaceManager: workspaceManager,
            panelManager: panelManager,
            eventBus: eventBus
        )
        // Auto-configure LLM provider from environment variables
        let llmProvider: (any LLMProvider)? = {
            if let key = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"], !key.isEmpty {
                return ClaudeProvider(apiKey: key)
            }
            if let key = ProcessInfo.processInfo.environment["OPENAI_API_KEY"], !key.isEmpty {
                return OpenAIProvider(apiKey: key)
            }
            if let key = ProcessInfo.processInfo.environment["GOOGLE_API_KEY"], !key.isEmpty {
                return GeminiProvider(apiKey: key)
            }
            return nil
        }()

        mosaicAI = MosaicAI(
            provider: llmProvider,
            commandRegistry: commandRegistry,
            commandSafety: commandSafety,
            conversationManager: conversationManager,
            contextCollector: contextCollector
        )
    }

    // MARK: - Lifecycle

    /// Register all command handlers, start the socket server, restore session,
    /// and begin autosave.  Call once from ContentView.onAppear.
    func start() {
        registerCommands()
        startSocketServer()

        // Session restore
        sessionPersistence.restoreIfAvailable()
        sessionPersistence.startAutosave()

        // Alert engine
        alertEngine.loadRules()
        alertEngine.start()

        // Listen for shell exit → close the panel/workspace
        NotificationCenter.default.addObserver(
            forName: .ghosttySurfaceDidClose,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self,
                  let userdata = notification.userInfo?["userdata"] as? UnsafeMutableRawPointer else { return }
            let session = Unmanaged<TerminalSession>.fromOpaque(userdata).takeUnretainedValue()
            // Find which panel owns this session and close it
            for workspace in workspaceManager.workspaces {
                for leaf in workspace.allPanels {
                    if let panel = panelManager.panel(for: leaf.id), panel.session.id == session.id {
                        if workspace.panelCount <= 1 {
                            // Last pane — close the workspace
                            workspaceManager.deleteWorkspace(id: workspace.id)
                        } else {
                            panelManager.closePanel(id: leaf.id)
                        }
                        return
                    }
                }
            }
        }

        logger.info("ServiceContainer started")
    }

    /// Final cleanup before the process exits.
    func stop() {
        // Autosave one final snapshot synchronously (best-effort).
        sessionPersistence.stopAutosave()
        Task { @MainActor in
            await sessionPersistence.save()
        }

        socketServer?.stop()
        alertEngine.stop()

        logger.info("ServiceContainer stopped")
    }

    // MARK: - Private

    private func registerCommands() {
        let wc = WorkspaceCommands(workspaceManager: workspaceManager)
        wc.register(in: commandRegistry)
        workspaceCommands = wc

        let pc = PaneCommands(workspaceManager: workspaceManager, panelManager: panelManager)
        pc.register(in: commandRegistry)
        paneCommands = pc

        let sc = SurfaceCommands(workspaceManager: workspaceManager, panelManager: panelManager)
        sc.register(in: commandRegistry)
        surfaceCommands = sc

        let nc = NotificationCommands(
            workspaceManager: workspaceManager,
            notificationService: notificationService,
            eventBus: eventBus
        )
        nc.register(in: commandRegistry)
        notificationCommands = nc

        let bc = BrowserCommands(workspaceManager: workspaceManager)
        bc.register(in: commandRegistry)
        browserCommands = bc

        let sys = SystemCommands()
        sys.register(in: commandRegistry)
        systemCommands = sys

        let ai = AICommands(
            workspaceManager: workspaceManager,
            eventBus: eventBus,
            mosaicAI: mosaicAI,
            conversationManager: conversationManager
        )
        ai.register(in: commandRegistry)
        aiCommands = ai
    }

    private func startSocketServer() {
        let server = SocketServer(
            config: .defaultPath(),
            dispatcher: commandDispatcher,
            accessController: accessController,
            eventBus: eventBus
        )
        do {
            try server.start()
            logger.info("Socket server listening at \(server.socketPath)")
        } catch {
            logger.error("Socket server failed to start: \(error.localizedDescription)")
        }
        socketServer = server
    }
}
