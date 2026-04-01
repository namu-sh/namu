import Combine
import Foundation
import os.log

private let logger = Logger(subsystem: "com.namu.app", category: "ServiceContainer")

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
    let remoteSessionService: RemoteSessionService

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
    let channelCredentialStore: ChannelCredentialStore
    let alertRouter: AlertRouter

    // MARK: - AI

    let conversationManager: ConversationManager
    let commandSafety: CommandSafety
    let contextCollector: ContextCollector
    let namuAI: NamuAI

    // MARK: - Command handlers (retained to keep weak-self closures alive)

    private var workspaceCommands: WorkspaceCommands?
    private var paneCommands: PaneCommands?
    private var surfaceCommands: SurfaceCommands?
    private var notificationCommands: NotificationCommands?
    private var browserCommands: BrowserCommands?
    private var systemCommands: SystemCommands?
    private var aiCommands: AICommands?
    private var sidebarCommands: SidebarCommands?
    private var windowCommands: WindowCommands?
    private var debugCommands: DebugCommands?
    private var fullscreenCommands: FullscreenCommands?
    private var paletteDebugCommands: PaletteDebugCommands?

    // Held so registerCommands() can wire SidebarCommands after init
    private weak var sidebarViewModelForCommands: SidebarViewModel?

    // Per-panel port cache for merging into workspace-level SidebarMetadata.
    private var panelPortCache: [UUID: [PortInfo]] = [:]

    // NotificationCenter observer tokens registered in start(), removed in stop().
    private var notificationObservers: [Any] = []

    // MARK: - Init

    init(workspaceManager: WorkspaceManager, panelManager: PanelManager, sidebarViewModel: SidebarViewModel? = nil) {
        self.workspaceManager = workspaceManager
        self.panelManager = panelManager
        self.sidebarViewModelForCommands = sidebarViewModel
        remoteSessionService = RemoteSessionService()
        panelManager.remoteSessionService = remoteSessionService
        // M10: Subscribe to proxy endpoint changes so existing browser panels
        // get the updated SOCKS5 address on reconnect.
        panelManager.observeRemoteSessionService(remoteSessionService)

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

        // Alerts + multi-channel routing
        channelCredentialStore = ChannelCredentialStore()
        alertRouter = AlertRouter(credentialStore: channelCredentialStore)
        alertEngine = AlertEngine(eventBus: eventBus)
        alertEngine.setAlertRouter(alertRouter)

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

        namuAI = NamuAI(
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

        // Wire PortScanner → SidebarMetadata updates.
        // Callback is per-panel; merge all panels in the workspace before writing metadata.
        if let svm = sidebarViewModelForCommands {
            PortScanner.shared.onPortsUpdated = { [weak svm, weak self] workspaceID, panelID, ports in
                guard let svm, let self else { return }
                self.panelPortCache[panelID] = ports
                // Collect ports for all panels in this workspace and deduplicate.
                let allPanelIDs = self.panelManager.allPanelIDs(in: workspaceID)
                var seen = Set<UInt16>()
                var merged: [PortInfo] = []
                for pid in allPanelIDs {
                    for info in (self.panelPortCache[pid] ?? []) {
                        if seen.insert(info.port).inserted {
                            merged.append(info)
                        }
                    }
                }
                merged.sort { $0.port < $1.port }
                var meta = svm.currentMetadata(for: workspaceID)
                meta.listeningPorts = merged
                svm.updateMetadata(meta, for: workspaceID)
            }
        }

        // Alert engine + channel routing
        alertEngine.loadRules()
        alertEngine.start()
        Task { await alertRouter.reloadChannels() }

        // Wire focused-panel provider for precise desktop-notification suppression.
        // Uses the key window's context when available, otherwise the primary panelManager.
        notificationService.keyWindowFocusedPanelID = { [weak self] in
            guard let self else { return nil }
            let pm: PanelManager
            if let ctx = AppDelegate.shared?.keyWindowContext {
                pm = ctx.panelManager
                let wm = ctx.workspaceManager
                guard let wsID = wm.selectedWorkspaceID else { return nil }
                return pm.focusedPanelID(in: wsID)
            } else {
                guard let wsID = self.workspaceManager.selectedWorkspaceID else { return nil }
                return self.panelManager.focusedPanelID(in: wsID)
            }
        }

        // Request macOS notification permission on first launch.
        // UNUserNotificationCenter only prompts the user once; safe to call every launch.
        notificationService.requestAuthorization()

        // Wire auto-reorder: move notified workspace to top of unpinned list.
        notificationObservers.append(
            NotificationCenter.default.addObserver(
                forName: .namuWorkspaceAutoReorderRequested,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                guard let wsID = notification.userInfo?["workspace_id"] as? UUID else { return }
                self?.workspaceManager.moveWorkspaceToTop(id: wsID)
            }
        )

        // Clean up remote session state when a workspace is deleted.
        notificationObservers.append(
            NotificationCenter.default.addObserver(
                forName: .namuWorkspaceDidDelete,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                guard let self, let wsID = notification.userInfo?["workspace_id"] as? UUID else { return }
                self.remoteSessionService.workspaceDidDelete(wsID)
                // M11: Also clean up in secondary window contexts so that
                // multi-window setups don't leave stale remote session state.
                if let contexts = AppDelegate.shared?.windowContexts.values {
                    for ctx in contexts {
                        ctx.remoteSessionService.workspaceDidDelete(wsID)
                    }
                }
            }
        )

        // Listen for shell exit → close the panel/workspace
        notificationObservers.append(
            NotificationCenter.default.addObserver(
                forName: .ghosttySurfaceDidClose,
                object: nil,
                queue: .main
            ) { [weak self] notification in
            guard let self,
                  let userdata = notification.userInfo?["userdata"] as? UnsafeMutableRawPointer else { return }
            let session = Unmanaged<TerminalSession>.fromOpaque(userdata).takeUnretainedValue()

            // Build the list of all (workspaceManager, panelManager) pairs to search —
            // primary window first, then any additional window contexts.
            var pairs: [(WorkspaceManager, PanelManager)] = [(workspaceManager, panelManager)]
            if let extraCtxs = AppDelegate.shared?.windowContexts.values {
                for ctx in extraCtxs {
                    if ctx.workspaceManager !== workspaceManager {
                        pairs.append((ctx.workspaceManager, ctx.panelManager))
                    }
                }
            }

            for (wm, pm) in pairs {
                for workspace in wm.workspaces {
                    let panelIDs = pm.allPanelIDs(in: workspace.id)
                    for panelID in panelIDs {
                        if let panel = pm.panel(for: panelID), panel.session.id == session.id {
                            if panelIDs.count <= 1 {
                                pm.deleteWorkspace(id: workspace.id)
                            } else {
                                pm.closePanel(id: panelID)
                            }
                            return
                        }
                    }
                }
            }
        })

        // Route terminal OSC notifications through NotificationService
        // (handles Claude session suppression, sound, and desktop notification).
        notificationObservers.append(
            NotificationCenter.default.addObserver(
                forName: .namuTerminalNotification,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                guard let self else { return }
                let title = notification.userInfo?["title"] as? String ?? ""
                let body = notification.userInfo?["body"] as? String ?? ""
                self.notificationService.handleTerminalNotification(
                    title: title,
                    body: body,
                    workspaceManager: self.workspaceManager
                )
            }
        )

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

        for observer in notificationObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        notificationObservers.removeAll()

        // Disconnect all active remote sessions.
        for workspaceID in workspaceManager.workspaces.map(\.id) {
            remoteSessionService.disconnectRemoteConnection(workspaceID: workspaceID)
        }

        logger.info("ServiceContainer stopped")
    }

    // MARK: - Window routing

    /// Resolve the WorkspaceManager for a given windowID string param, or the primary if absent/unknown.
    func workspaceManagerForWindow(windowIDString: String?) -> WorkspaceManager {
        guard let idStr = windowIDString,
              let windowID = UUID(uuidString: idStr),
              let ctx = AppDelegate.shared?.windowContexts[windowID] else {
            return workspaceManager
        }
        return ctx.workspaceManager
    }

    // MARK: - Private

    private func registerCommands() {
        let wc = WorkspaceCommands(workspaceManager: workspaceManager, panelManager: panelManager, remoteSessionService: remoteSessionService)
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
            panelManager: panelManager,
            notificationService: notificationService,
            eventBus: eventBus
        )
        nc.register(in: commandRegistry)
        notificationCommands = nc

        let bc = BrowserCommands(workspaceManager: workspaceManager, panelManager: panelManager)
        bc.register(in: commandRegistry)
        browserCommands = bc

        let sys = SystemCommands(workspaceManager: workspaceManager, panelManager: panelManager)
        sys.register(in: commandRegistry)
        systemCommands = sys

        // Agent hook handler — tracks active agent PIDs per workspace.
        commandRegistry.register("system.claude_hook") { [weak self] req in
            guard let self else { return .failure(id: req.id, error: .internalError("Service unavailable")) }
            let params = req.params?.object ?? [:]
            let event = (params["event"].flatMap { if case .string(let s) = $0 { return s } else { return nil } }) ?? ""
            let wsIDStr = params["workspace_id"].flatMap { if case .string(let s) = $0 { return s } else { return nil } }
            let agentPID = params["claude_pid"].flatMap { if case .string(let s) = $0 { return s } else { return nil } }
            // "tool" param identifies the agent type (e.g. "codex"); default to "claude_code".
            let agentType = (params["tool"].flatMap { if case .string(let s) = $0 { return s } else { return nil } }) ?? "claude_code"

            if let wsIDStr, let wsID = UUID(uuidString: wsIDStr),
               let idx = self.workspaceManager.workspaces.firstIndex(where: { $0.id == wsID }) {
                switch event {
                case "session-start", "prompt-submit", "pre-tool-use":
                    if let pid = agentPID {
                        self.workspaceManager.workspaces[idx].setAgentPID(type: agentType, pid: pid)
                    }
                case "session-end", "stop":
                    self.workspaceManager.workspaces[idx].clearAgentPID(type: agentType)
                default:
                    break
                }
            }
            return .success(id: req.id, result: .object(["ok": .bool(true)]))
        }

        let ai = AICommands(
            workspaceManager: workspaceManager,
            eventBus: eventBus,
            namuAI: namuAI,
            conversationManager: conversationManager
        )
        ai.register(in: commandRegistry)
        aiCommands = ai

        if let svm = sidebarViewModelForCommands {
            let sidebar = SidebarCommands(workspaceManager: workspaceManager, sidebarViewModel: svm)
            sidebar.register(in: commandRegistry)
            sidebarCommands = sidebar
        }

        let wnd = WindowCommands()
        wnd.register(in: commandRegistry)
        windowCommands = wnd

        let dbg = DebugCommands(workspaceManager: workspaceManager, panelManager: panelManager)
        dbg.register(in: commandRegistry)
        debugCommands = dbg

        let fs = FullscreenCommands()
        fs.register(in: commandRegistry)
        fullscreenCommands = fs

        let pd = PaletteDebugCommands()
        pd.register(in: commandRegistry)
        paletteDebugCommands = pd
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
            setenv("NAMU_SOCKET", server.socketPath, 1)
        } catch {
            logger.error("Socket server failed to start: \(error.localizedDescription)")
        }
        socketServer = server
    }
}
