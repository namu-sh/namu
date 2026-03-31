import SwiftUI

@main
struct NamuApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup("Namu") {
            ContentView(appDelegate: appDelegate)
        }
        .defaultSize(width: 900, height: 600)
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unifiedCompact(showsTitle: false))

    }
}

// MARK: - ContentView

/// Root layout: narrow sidebar on the left, active workspace on the right.
struct ContentView: View {
    let appDelegate: AppDelegate
    /// Non-nil when this ContentView was created for a secondary window via AppDelegate.createMainWindow().
    let windowContext: WindowContext?

    @StateObject private var workspaceManager: WorkspaceManager
    @StateObject private var sidebarViewModel: SidebarViewModel
    @StateObject private var panelManager: PanelManager

    @State private var isSidebarVisible: Bool = true
    @State private var isCommandPalettePresented: Bool = false
    @State private var isAIChatVisible: Bool = false
    @State private var servicesStarted: Bool = false
    @State private var aiChatViewModel: AIChatViewModel?
    @State private var isMinimalMode: Bool = false

    // Resizable sidebar
    @State private var sidebarWidth: CGFloat = {
        let saved = UserDefaults.standard.double(forKey: "namu.sidebarWidth")
        return saved > 0 ? saved : 220
    }()
    private let sidebarMinWidth: CGFloat = 160
    private let sidebarMaxWidth: CGFloat = 400

    // Find overlay
    @State private var isFindOverlayVisible: Bool = false
    @State private var findSearchText: String = ""

    init(appDelegate: AppDelegate, windowContext: WindowContext? = nil) {
        self.appDelegate = appDelegate
        self.windowContext = windowContext
        let wm = windowContext?.workspaceManager ?? WorkspaceManager()
        let pm = windowContext?.panelManager ?? PanelManager(workspaceManager: wm)
        let svm = SidebarViewModel(workspaceManager: wm, panelManager: pm)
        _workspaceManager = StateObject(wrappedValue: wm)
        _panelManager = StateObject(wrappedValue: pm)
        _sidebarViewModel = StateObject(wrappedValue: svm)
    }

    var body: some View {
        ZStack {
            HStack(spacing: 0) {
                if isSidebarVisible && !isMinimalMode {
                    SidebarView(viewModel: sidebarViewModel)
                        .frame(width: sidebarWidth)
                        .transaction { t in t.animation = nil }
                        .transition(.move(edge: .leading))
                        .accessibilityIdentifier("namu-sidebar")

                    // Draggable sidebar edge
                    SidebarResizeHandle(
                        sidebarWidth: $sidebarWidth,
                        minWidth: sidebarMinWidth,
                        maxWidth: sidebarMaxWidth
                    )
                }

                ZStack {
                    ForEach(workspaceManager.workspaces) { workspace in
                        let isSelectedWorkspace = workspace.id == workspaceManager.selectedWorkspaceID
                        let isWorkspaceMode = sidebarViewModel.selection != .settings && sidebarViewModel.selection != .notifications
                        let active = isSelectedWorkspace && isWorkspaceMode
                        WorkspaceView(workspaceID: workspace.id, panelManager: panelManager, isActive: active)
                            .opacity(active ? 1 : 0)
                            .allowsHitTesting(active)
                    }

                    if sidebarViewModel.selection == .settings {
                        SettingsView()
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .accessibilityElement(children: .contain)
                            .accessibilityIdentifier("namu-settings")
                    }

                    if sidebarViewModel.selection == .notifications,
                       let ns = appDelegate.serviceContainer?.notificationService {
                        NotificationPanelView(
                            notificationService: ns,
                            workspaceManager: workspaceManager,
                            onSelectWorkspace: { wsID in
                                sidebarViewModel.selectWorkspace(id: wsID)
                            },
                            onJumpToUnread: {
                                appDelegate.jumpToLatestUnread()
                                sidebarViewModel.selection = .workspace(sidebarViewModel.lastWorkspaceID)
                            }
                        )
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .accessibilityElement(children: .contain)
                        .accessibilityIdentifier("namu-notifications")
                    }

                    // Find overlay — draggable, snaps to nearest corner
                    if isFindOverlayVisible {
                        FindOverlayView(
                            isVisible: $isFindOverlayVisible,
                            searchText: $findSearchText,
                            matchIndex: nil,
                            matchTotal: nil,
                            onNext: { findNavigate(forward: true) },
                            onPrevious: { findNavigate(forward: false) },
                            onDismiss: { restoreFocusToTerminal() }
                        )
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .zIndex(50)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("namu-workspace-content")
                // AI Chat panel (slides in from the right)
                if isAIChatVisible, let vm = aiChatViewModel {
                    // 1pt separator
                    Rectangle()
                        .fill(Color.white.opacity(0.08))
                        .frame(width: 1)
                        .frame(maxHeight: .infinity)

                    AIChatPanelView(viewModel: vm)
                        .transition(.move(edge: .trailing))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.black)
            .animation(.easeInOut(duration: 0.18), value: isSidebarVisible)
            .animation(.easeInOut(duration: 0.18), value: isAIChatVisible)

            // Command palette overlay
            if isCommandPalettePresented {
                CommandPaletteView(
                    isPresented: $isCommandPalettePresented,
                    workspaceManager: workspaceManager,
                    panelManager: panelManager
                )
                .transition(.opacity.combined(with: .scale(scale: 0.97)))
                .zIndex(100)
            }
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                Button(action: { isCommandPalettePresented = true }) {
                    HStack(spacing: 4) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                        Text(String(localized: "toolbar.search.placeholder", defaultValue: "Search..."))
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    }
                    .frame(width: 160)
                }
                .buttonStyle(.plain)
                .controlSize(.mini)
            }

            ToolbarItem(placement: .automatic) {
                Button(action: {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        sidebarViewModel.openSettings()
                    }
                }) {
                    Image(systemName: "gearshape")
                        .font(.system(size: 10))
                }
                .controlSize(.mini)
            }
        }
        .onAppear {
            // Apply saved appearance settings at window level.
            AppearanceManager.shared.applyTheme()
            AppearanceManager.shared.applyWindowOpacity()

            if let ctx = windowContext {
                // Secondary window: register its context with AppDelegate for IPC routing.
                if let nsWindow = NSApp.keyWindow {
                    appDelegate.registerMainWindow(window: nsWindow, context: ctx)
                }
                // Secondary windows don't start services — they share the singleton ServiceContainer.
                servicesStarted = true
                if let selectedID = workspaceManager.selectedWorkspaceID {
                    sidebarViewModel.selectWorkspace(id: selectedID)
                } else if let firstID = workspaceManager.workspaces.first?.id {
                    sidebarViewModel.selectWorkspace(id: firstID)
                }
            } else {
                // Primary window: wire AppDelegate shortcuts and start services.
                if let window = NSApp.windows.first(where: { $0.title == "Namu" || $0.isKeyWindow }) {
                    window.identifier = NSUserInterfaceItemIdentifier("namu-primary")
                }
                appDelegate.workspaceManager = workspaceManager
                appDelegate.panelManager = panelManager
                appDelegate.toggleCommandPalette = {
                    withAnimation(.easeOut(duration: 0.12)) {
                        isCommandPalettePresented.toggle()
                    }
                }
                appDelegate.toggleSidebar = {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        isSidebarVisible.toggle()
                    }
                }

                // Start all services once (IPC, persistence, alerts, AI).
                if !servicesStarted {
                    let container = ServiceContainer(
                        workspaceManager: workspaceManager,
                        panelManager: panelManager,
                        sidebarViewModel: sidebarViewModel
                    )
                    container.start()
                    appDelegate.serviceContainer = container
                    aiChatViewModel = AIChatViewModel(namuAI: container.namuAI)
                    sidebarViewModel.setNotificationService(container.notificationService)
                    servicesStarted = true

                    // Restore window frame from session (best-effort: window must exist).
                    if let frame = container.sessionPersistence.restoredWindowFrame,
                       frame.width > 200, frame.height > 100,
                       let window = NSApp.windows.first(where: { $0.identifier?.rawValue == "namu-primary" }) {
                        window.setFrame(frame, display: false)
                    }

                    // Sync sidebar selection after session restore — the initial workspace
                    // from WorkspaceManager.init() may have been replaced by restored workspaces.
                    if let selectedID = workspaceManager.selectedWorkspaceID {
                        sidebarViewModel.selectWorkspace(id: selectedID)
                    } else if let firstID = workspaceManager.workspaces.first?.id {
                        sidebarViewModel.selectWorkspace(id: firstID)
                    }
                }
            }

            // Wire cross-window move callbacks for the "Move to Window" context menu.
            sidebarViewModel.availableWindows = appDelegate.windowContexts.values
                .filter { $0.workspaceManager !== workspaceManager }
                .enumerated()
                .map { idx, ctx in
                    let title = String(localized: "sidebar.window.label", defaultValue: "Window \(idx + 2)")
                    return (id: ctx.windowID, title: title)
                }
            sidebarViewModel.onMoveWorkspaceToWindow = { [weak appDelegate] wsID, targetWindowID in
                appDelegate?.moveWorkspaceToWindow(workspaceId: wsID, targetWindowId: targetWindowID)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .toggleSidebar)) { _ in
            withAnimation(.easeInOut(duration: 0.18)) {
                isSidebarVisible.toggle()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .toggleAIChat)) { _ in
            withAnimation(.easeInOut(duration: 0.18)) {
                isAIChatVisible.toggle()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .toggleFindOverlay)) { _ in
            withAnimation(.easeOut(duration: 0.15)) {
                isFindOverlayVisible.toggle()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .toggleMinimalMode)) { _ in
            withAnimation(.easeInOut(duration: 0.18)) {
                isMinimalMode.toggle()
            }
        }
        // Notification panel toggle is handled by SidebarViewModel's NotificationCenter subscriber.
        // Do NOT add a duplicate .onReceive here — it would double-toggle and cancel itself out.
        .keyboardShortcut("m", modifiers: [.command, .shift])
        .keyboardHintOverlay()
        // Note: .selectWorkspace and .openSettings notifications are handled
        // by SidebarViewModel directly, keeping selection as the single source of truth.
    }

    // MARK: - Find helpers

    private func findNavigate(forward: Bool) {
        guard let wsID = workspaceManager.selectedWorkspaceID,
              let focusedID = panelManager.focusedPanelID(in: wsID),
              let panel = panelManager.panel(for: focusedID),
              let surface = panel.session.surface else { return }
        let action = forward ? "search_forward" : "search_backward"
        ghostty_surface_binding_action(surface, action, UInt(action.utf8.count))
    }

    /// Restore first responder to the focused terminal surface after the find
    /// overlay is dismissed. Runs on the next runloop tick so SwiftUI can
    /// finish removing the overlay before we steal focus.
    private func restoreFocusToTerminal() {
        guard let wsID = workspaceManager.selectedWorkspaceID,
              let focusedID = panelManager.focusedPanelID(in: wsID),
              let panel = panelManager.panel(for: focusedID) else { return }
        let surfaceView = panel.surfaceView
        DispatchQueue.main.async {
            surfaceView.window?.makeFirstResponder(surfaceView)
            // Arm escape suppression so the Escape keyDown that dismissed the
            // overlay is not forwarded to the terminal (Task 4.5 pattern).
            surfaceView.beginFindEscapeSuppression()
        }
    }
}

// MARK: - SidebarResizeHandle

/// Draggable edge on the right side of the sidebar for resizing.
private struct SidebarResizeHandle: View {
    @Binding var sidebarWidth: CGFloat
    let minWidth: CGFloat
    let maxWidth: CGFloat

    @State private var isHovered = false
    @State private var dragStartWidth: CGFloat = 0
    @State private var isDragging = false

    var body: some View {
        ZStack {
            // Wider invisible hit area
            Color.clear
                .contentShape(Rectangle())
                .frame(width: 8)

            // Visible 1pt line
            Rectangle()
                .fill(isHovered || isDragging ? Color.white.opacity(0.28) : Color.white.opacity(0.08))
                .frame(width: 1)
                .animation(.easeInOut(duration: 0.12), value: isHovered)
        }
        .frame(maxHeight: .infinity)
        .onHover { hovering in
            isHovered = hovering
            if hovering {
                NSCursor.resizeLeftRight.push()
            } else {
                NSCursor.pop()
            }
        }
        .highPriorityGesture(
            DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { value in
                    if !isDragging {
                        dragStartWidth = sidebarWidth
                        isDragging = true
                    }
                    let newWidth = max(minWidth, min(maxWidth, dragStartWidth + value.translation.width))
                    if abs(newWidth - sidebarWidth) > 0.5 {
                        withTransaction(Transaction(animation: nil)) {
                            sidebarWidth = newWidth
                        }
                    }
                }
                .onEnded { _ in
                    isDragging = false
                    UserDefaults.standard.set(sidebarWidth, forKey: "namu.sidebarWidth")
                }
        )
        .onTapGesture(count: 2) {
            sidebarWidth = 220
            UserDefaults.standard.set(sidebarWidth, forKey: "namu.sidebarWidth")
        }
    }
}
