import SwiftUI
import UniformTypeIdentifiers

// MARK: - Command model

/// A single executable command shown in the palette.
struct PaletteCommand: Identifiable {
    let id: UUID
    let title: String
    let icon: String
    let action: () -> Void

    init(title: String, icon: String, action: @escaping () -> Void) {
        self.id = UUID()
        self.title = title
        self.icon = icon
        self.action = action
    }
}

// MARK: - CommandPaletteView

/// Floating fuzzy-search overlay. Triggered by Cmd+K or Cmd+P.
/// Presents workspace names and fixed commands; executes on Enter or click.
/// Observable selection state so NSEvent monitor mutations trigger SwiftUI re-renders.
private class PaletteSelection: ObservableObject {
    @Published var index: Int = 0
}

struct CommandPaletteView: View {
    @Binding var isPresented: Bool
    let workspaceManager: WorkspaceManager
    let panelManager: PanelManager
    var projectConfigLoader: ProjectConfigLoader?

    @State private var query: String = ""
    @StateObject private var selection = PaletteSelection()
    @FocusState private var fieldFocused: Bool

    // MARK: - Commands

    private var builtInCommands: [PaletteCommand] {
        [
            PaletteCommand(title: String(localized: "palette.command.newWorkspace", defaultValue: "New Workspace"), icon: "plus.rectangle") {
                panelManager.createWorkspace()
            },
            PaletteCommand(title: String(localized: "palette.command.splitHorizontal", defaultValue: "Split Horizontal"), icon: "rectangle.split.2x1") {
                panelManager.splitActivePanel(direction: .horizontal)
            },
            PaletteCommand(title: String(localized: "palette.command.splitVertical", defaultValue: "Split Vertical"), icon: "rectangle.split.1x2") {
                panelManager.splitActivePanel(direction: .vertical)
            },
            PaletteCommand(title: String(localized: "palette.command.closePane", defaultValue: "Close Pane"), icon: "xmark.rectangle") {
                panelManager.closeActivePanel()
            },
            PaletteCommand(title: String(localized: "palette.command.toggleSidebar", defaultValue: "Toggle Sidebar"), icon: "sidebar.left") {
                NotificationCenter.default.post(name: .toggleSidebar, object: nil)
            },
            PaletteCommand(title: String(localized: "palette.command.openBrowser", defaultValue: "Open Browser"), icon: "globe") {
                NotificationCenter.default.post(name: .openBrowserPanel, object: nil)
            },
            PaletteCommand(title: String(localized: "palette.command.findInTerminal", defaultValue: "Find in Terminal"), icon: "magnifyingglass") {
                NotificationCenter.default.post(name: .toggleFindOverlay, object: nil)
            },
            PaletteCommand(title: String(localized: "palette.command.toggleMinimalMode", defaultValue: "Toggle Minimal Mode"), icon: "rectangle.compress.vertical") {
                NotificationCenter.default.post(name: .toggleMinimalMode, object: nil)
            },
        ]
    }

    private var workspaceCommands: [PaletteCommand] {
        workspaceManager.workspaces.map { workspace in
            PaletteCommand(title: workspace.title, icon: "rectangle.3.group") {
                NotificationCenter.default.post(
                    name: .selectWorkspace,
                    object: nil,
                    userInfo: ["id": workspace.id]
                )
            }
        }
    }

    private var customCommands: [PaletteCommand] {
        guard let loader = projectConfigLoader else { return [] }
        let executor = CommandExecutor(
            target: NamuCommandTarget(workspaceManager: workspaceManager, panelManager: panelManager),
            configLoader: loader
        )
        return loader.commands.map { cmd in
            PaletteCommand(
                title: cmd.name,
                icon: cmd.workspace != nil ? "rectangle.3.group" : "terminal"
            ) {
                executor.execute(cmd, configPath: loader.projectPath)
            }
        }
    }

    private var allCommands: [PaletteCommand] {
        customCommands + builtInCommands + workspaceCommands
    }

    private var filteredCommands: [PaletteCommand] {
        if query.isEmpty { return allCommands }
        return allCommands.filter { fuzzyMatch(query: query, in: $0.title) }
    }

    /// The top match title used as inline ghost-text suggestion.
    private var inlineSuggestion: String? {
        guard !query.isEmpty, let first = filteredCommands.first else { return nil }
        let title = first.title
        // Only show ghost text if the title starts with the query (case-insensitive).
        if title.lowercased().hasPrefix(query.lowercased()) {
            return title
        }
        return nil
    }

    // MARK: - Body

    var body: some View {
        ZStack {
            // Dismiss on background tap
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { dismiss() }
                .ignoresSafeArea()

            VStack(spacing: 0) {
                // Search field
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                        .font(.system(size: 14))

                    ZStack(alignment: .leading) {
                        // Inline completion ghost text
                        if let suggestion = inlineSuggestion, !query.isEmpty {
                            Text(suggestion)
                                .font(.system(size: 14))
                                .foregroundStyle(.tertiary)
                        }
                        TextField(String(localized: "palette.search.placeholder", defaultValue: "Search commands and workspaces…"), text: $query)
                            .textFieldStyle(.plain)
                            .font(.system(size: 14))
                            .focused($fieldFocused)
                            .onSubmit { executeSelected() }
                            .accessibilityIdentifier("namu-command-palette-search")
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)

                if !filteredCommands.isEmpty {
                    Divider()
                        .opacity(0.2)

                    ScrollViewReader { proxy in
                        ScrollView(.vertical, showsIndicators: false) {
                            VStack(spacing: 0) {
                                ForEach(Array(filteredCommands.enumerated()), id: \.element.id) { idx, cmd in
                                    commandRow(cmd, index: idx)
                                        .id("\(idx)-\(selection.index)")
                                }
                            }
                            .padding(.vertical, 4)
                        }
                        .frame(maxHeight: 300)
                        .onChange(of: selection.index) { _, newIdx in
                            withAnimation(.easeInOut(duration: 0.1)) {
                                proxy.scrollTo(newIdx, anchor: .center)
                            }
                        }
                    }
                }
            }
            .background(paletteBackground)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(NamuColors.separator, lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.5), radius: 24, x: 0, y: 8)
            .frame(width: 480)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("namu-command-palette")
        }
        .onAppear {
            fieldFocused = true
            selection.index = 0
            updateDebugSnapshot()
        }
        .onChange(of: query) { _, _ in
            selection.index = 0
            updateDebugSnapshot()
        }
        .onDisappear {
            PaletteDebugSnapshot.current = nil
        }
        // Keyboard navigation handled via NSEvent monitor installed in onAppear
        .background(KeyEventHandler { event in
            handleKeyEvent(event)
        })
    }

    // MARK: - Row

    @ViewBuilder
    private func commandRow(_ cmd: PaletteCommand, index: Int) -> some View {
        HStack(spacing: 10) {
            Image(systemName: cmd.icon)
                .font(.system(size: 13))
                .foregroundStyle(index == selection.index ? .primary : .secondary)
                .frame(width: 18)

            Text(cmd.title)
                .font(.system(size: 13))
                .foregroundStyle(.primary)

            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background {
            if index == selection.index {
                RoundedRectangle(cornerRadius: 6)
                    .fill(.selection)
                    .padding(.horizontal, 4)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            selection.index = index
            executeSelected()
        }
    }

    // MARK: - Palette background (blur)

    private var paletteBackground: some View {
        PaletteBlurView()
    }

    // MARK: - Actions

    private func handleKeyEvent(_ event: NSEvent) {
        let count = filteredCommands.count
        guard count > 0 else { return }

        // Wrap in async to ensure SwiftUI observes the @State change
        // from the NSEvent monitor callback.
        DispatchQueue.main.async {
            switch event.keyCode {
            case 125: // Down arrow
                selection.index = min(selection.index + 1, count - 1)
            case 126: // Up arrow
                selection.index = max(selection.index - 1, 0)
            case 36:  // Return
                executeSelected()
            case 53:  // Escape
                dismiss()
            default:
                break
            }
        }
    }

    private func executeSelected() {
        guard filteredCommands.indices.contains(selection.index) else { return }
        let cmd = filteredCommands[selection.index]
        dismiss()
        cmd.action()
    }

    private func dismiss() {
        PaletteDebugSnapshot.current = nil
        query = ""
        isPresented = false
    }

    /// Publish current palette state for debug.command_palette.* introspection.
    private func updateDebugSnapshot() {
        let filtered = filteredCommands
        PaletteDebugSnapshot.current = PaletteDebugSnapshot(
            isVisible: isPresented,
            query: query,
            selectedIndex: selection.index,
            results: filtered.map { cmd in
                PaletteDebugSnapshot.PaletteResultSnapshot(title: cmd.title, score: 0)
            }
        )
    }

    // MARK: - Fuzzy match

    private func fuzzyMatch(query: String, in text: String) -> Bool {
        let q = query.lowercased()
        let t = text.lowercased()
        var tIdx = t.startIndex
        for ch in q {
            guard let found = t[tIdx...].firstIndex(of: ch) else { return false }
            tIdx = t.index(after: found)
        }
        return true
    }
}

// MARK: - Blur background (NSVisualEffectView)

private struct PaletteBlurView: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .hudWindow
        v.blendingMode = .behindWindow
        v.state = .active
        return v
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

// MARK: - KeyEventHandler (bridges NSEvent to SwiftUI)

/// Transparent view that installs a local NSEvent monitor for key-down events.
private struct KeyEventHandler: NSViewRepresentable {
    let handler: (NSEvent) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = KeyCaptureView()
        view.handler = handler
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

private final class KeyCaptureView: NSView {
    var handler: ((NSEvent) -> Void)?
    private var monitor: Any?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil, monitor == nil {
            NamuDebug.log("[Namu] KeyCaptureView: installing monitor")
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                self?.handler?(event)
                // Return nil to consume navigation keys, event otherwise
                let consumed: Set<UInt16> = [125, 126, 36, 53]
                if consumed.contains(event.keyCode) {
                    NamuDebug.log("[Namu] KeyCaptureView: consumed keyCode=\(event.keyCode)")
                }
                return consumed.contains(event.keyCode) ? nil : event
            }
        } else {
            if let m = monitor { NSEvent.removeMonitor(m) }
            monitor = nil
        }
    }

    deinit {
        if let m = monitor { NSEvent.removeMonitor(m) }
    }
}

// MARK: - Notification name

extension Notification.Name {
    static let toggleSidebar = Notification.Name("namu.toggleSidebar")
    static let toggleAIChat = Notification.Name("namu.toggleAIChat")
    static let openSettings = Notification.Name("namu.openSettings")
    static let selectWorkspace = Notification.Name("namu.selectWorkspace")
    static let toggleFindOverlay = Notification.Name("namu.toggleFindOverlay")
    static let openBrowserPanel = Notification.Name("namu.openBrowserPanel")
    static let toggleMinimalMode = Notification.Name("namu.toggleMinimalMode")
    static let toggleNotificationPanel = Notification.Name("namu.toggleNotificationPanel")
    static let renameWorkspace = Notification.Name("namu.renameWorkspace")
    static let toggleSplitZoom = Notification.Name("namu.toggleSplitZoom")
    static let toggleBrowserDevTools = Notification.Name("namu.browser.devtools.toggle")
    static let showBrowserConsole = Notification.Name("namu.browser.devtools.console")
    static let nextSurface = Notification.Name("namu.nextSurface")
    static let prevSurface = Notification.Name("namu.prevSurface")
    static let openBrowser = Notification.Name("namu.openBrowser")
    static let triggerFlash = Notification.Name("namu.triggerFlash")
    static let openFolder = Notification.Name("namu.openFolder")
    static let sendFeedback = Notification.Name("namu.sendFeedback")
    static let splitBrowserRight = Notification.Name("namu.browser.split.right")
    static let splitBrowserDown = Notification.Name("namu.browser.split.down")
    static let renameTab = Notification.Name("namu.renameTab")
    static let toggleTerminalCopyMode = Notification.Name("namu.toggleTerminalCopyMode")
}
