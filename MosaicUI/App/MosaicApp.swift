import SwiftUI

@main
struct MosaicApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup("Mosaic") {
            ContentView(appDelegate: appDelegate)
        }
        .defaultSize(width: 900, height: 600)
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified(showsTitle: false))

    }
}

// MARK: - ContentView

/// Root layout: narrow sidebar on the left, active workspace on the right.
struct ContentView: View {
    let appDelegate: AppDelegate

    @StateObject private var workspaceManager: WorkspaceManager
    @StateObject private var sidebarViewModel: SidebarViewModel
    @StateObject private var panelManager: PanelManager

    @State private var isSidebarVisible: Bool = true
    @State private var isCommandPalettePresented: Bool = false
    @State private var isAIChatVisible: Bool = false
    @State private var servicesStarted: Bool = false
    @State private var aiChatViewModel: AIChatViewModel?

    // Resizable sidebar
    @State private var sidebarWidth: CGFloat = {
        let saved = UserDefaults.standard.double(forKey: "mosaic.sidebarWidth")
        return saved > 0 ? saved : 220
    }()
    private let sidebarMinWidth: CGFloat = 160
    private let sidebarMaxWidth: CGFloat = 400

    // Find overlay
    @State private var isFindOverlayVisible: Bool = false
    @State private var findSearchText: String = ""

    init(appDelegate: AppDelegate) {
        self.appDelegate = appDelegate
        let wm = WorkspaceManager()
        let pm = PanelManager(workspaceManager: wm)
        let svm = SidebarViewModel(workspaceManager: wm)
        _workspaceManager = StateObject(wrappedValue: wm)
        _panelManager = StateObject(wrappedValue: pm)
        _sidebarViewModel = StateObject(wrappedValue: svm)
    }

    var body: some View {
        ZStack {
            HStack(spacing: 0) {
                if isSidebarVisible {
                    SidebarView(viewModel: sidebarViewModel)
                        .frame(width: sidebarWidth)
                        .transaction { t in t.animation = nil }
                        .transition(.move(edge: .leading))

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
                        let isWorkspaceMode = sidebarViewModel.selection != .settings
                        let active = isSelectedWorkspace && isWorkspaceMode
                        WorkspaceView(workspace: workspace, panelManager: panelManager, isActive: active)
                            .opacity(active ? 1 : 0)
                            .allowsHitTesting(active)
                    }

                    if sidebarViewModel.selection == .settings {
                        SettingsView()
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }

                    // Find overlay — floats in top-right corner
                    if isFindOverlayVisible {
                        VStack {
                            HStack {
                                Spacer()
                                FindOverlayView(
                                    isVisible: $isFindOverlayVisible,
                                    searchText: $findSearchText,
                                    matchIndex: nil,
                                    matchTotal: nil,
                                    onNext: { findNavigate(forward: true) },
                                    onPrevious: { findNavigate(forward: false) }
                                )
                            }
                            Spacer()
                        }
                        .zIndex(50)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                }
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
                        Text("Search...")
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
            // Wire AppDelegate shortcuts to our services
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
                    panelManager: panelManager
                )
                container.start()
                appDelegate.serviceContainer = container
                aiChatViewModel = AIChatViewModel(mosaicAI: container.mosaicAI)
                servicesStarted = true

                // Sync sidebar selection after session restore — the initial workspace
                // from WorkspaceManager.init() may have been replaced by restored workspaces.
                if let selectedID = workspaceManager.selectedWorkspaceID {
                    sidebarViewModel.selectWorkspace(id: selectedID)
                } else if let firstID = workspaceManager.workspaces.first?.id {
                    sidebarViewModel.selectWorkspace(id: firstID)
                }
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
        // Note: .selectWorkspace and .openSettings notifications are handled
        // by SidebarViewModel directly, keeping selection as the single source of truth.
    }

    // MARK: - Find helpers

    private func findNavigate(forward: Bool) {
        guard let focusedID = workspaceManager.selectedWorkspace?.focusedPanelID,
              let panel = panelManager.panel(for: focusedID),
              let surface = panel.session.surface else { return }
        let action = forward ? "search_forward" : "search_backward"
        ghostty_surface_binding_action(surface, action, UInt(action.utf8.count))
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
                    UserDefaults.standard.set(sidebarWidth, forKey: "mosaic.sidebarWidth")
                }
        )
        .onTapGesture(count: 2) {
            sidebarWidth = 220
            UserDefaults.standard.set(sidebarWidth, forKey: "mosaic.sidebarWidth")
        }
    }
}
