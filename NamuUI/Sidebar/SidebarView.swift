import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Workspace drag UTType

extension UTType {
    /// Custom type for dragging workspace rows within the sidebar.
    static let namuWorkspace = UTType(exportedAs: "xyz.omlabs.namu.workspace")
}

/// Vertical tab list showing all workspaces.
/// Fixed ~220pt wide with NSVisualEffectView sidebar material backdrop.
struct SidebarView: View {
    @ObservedObject var viewModel: SidebarViewModel
    /// Workspace being renamed inline (nil = no active rename).
    @State private var renamingID: UUID? = nil
    @State private var renameText: String = ""

    /// ID of the workspace currently being dragged.
    @State private var draggingID: UUID? = nil

    /// ID of the workspace currently acting as drop target.
    @State private var dropTargetID: UUID? = nil

    /// Whether the current drag-over target is in split mode (Shift held).
    @State private var dropIsSplitMode: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            // Titlebar region: + and bell buttons, below traffic lights
            sidebarTitlebarButtons

            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(spacing: 1) {
                        ForEach(viewModel.items) { item in
                            if renamingID == item.id {
                                renameField(for: item)
                            } else {
                                SidebarItemView(
                                    title: item.title,
                                    isSelected: viewModel.selection == .workspace(item.id),
                                    isPinned: item.isPinned,
                                    customColor: item.customColor,
                                    panelCount: item.panelCount,
                                    gitBranch: item.gitBranch,
                                    gitDirty: item.gitDirty,
                                    workingDirectory: item.workingDirectory,
                                    listeningPorts: item.listeningPorts,
                                    shellState: item.shellState,
                                    notificationSubtitle: item.notificationSubtitle,
                                    progressLabel: item.progressLabel,
                                    latestLog: item.latestLog,
                                    logLevel: item.logLevel,
                                    isRemoteSSH: item.isRemoteSSH,
                                    pullRequests: item.pullRequests,
                                    panelBranches: item.panelBranches,
                                    metadataEntries: item.metadataEntries,
                                    markdownBlocks: item.markdownBlocks,
                                    onSelect: {
                                        viewModel.selectWorkspace(id: item.id)
                                    },
                                    onRename: { beginRename(item: item) },
                                    onTogglePin: { viewModel.togglePin(id: item.id) },
                                    onSetColor: { color in
                                        viewModel.setColor(color, for: item.id)
                                    },
                                    onClose: { viewModel.closeWorkspace(id: item.id) },
                                    availableWindows: viewModel.availableWindows,
                                    onMoveToWindow: viewModel.availableWindows.isEmpty ? nil : { windowID in
                                        viewModel.moveWorkspaceToWindow(workspaceID: item.id, targetWindowID: windowID)
                                    },
                                    onReconnectSSH: item.isRemoteSSH ? { viewModel.reconnectSSH(workspaceID: item.id) } : nil,
                                    onDisconnectSSH: item.isRemoteSSH ? { viewModel.disconnectSSH(workspaceID: item.id) } : nil
                                )
                                // Note: .equatable() removed — live isSelected from viewModel.selection
                                // ensures sidebar always reflects current selection state.
                                .padding(.horizontal, 8)
                                .onTapGesture { viewModel.selectWorkspace(id: item.id) }
                                .opacity(draggingID == item.id ? 0.4 : 1.0)
                                .overlay(
                                    dropTargetID == item.id
                                        ? RoundedRectangle(cornerRadius: 6)
                                            .strokeBorder(
                                                dropIsSplitMode ? Color.green : Color.accentColor,
                                                lineWidth: 2
                                            )
                                            .padding(.horizontal, 8)
                                        : nil
                                )
                                // Drag source: encode workspace ID as UTF-8 data
                                .onDrag {
                                    draggingID = item.id
                                    let provider = NSItemProvider()
                                    let idString = item.id.uuidString
                                    provider.registerDataRepresentation(
                                        forTypeIdentifier: UTType.namuWorkspace.identifier,
                                        visibility: .all
                                    ) { completion in
                                        completion(idString.data(using: .utf8), nil)
                                        return nil
                                    }
                                    return provider
                                }
                                // Drop target: reorder when a workspace is dropped here,
                                // or receive a pane tab dragged from another workspace.
                                .onDrop(
                                    of: [.namuWorkspace, .namuPaneTab],
                                    delegate: WorkspaceDropDelegate(
                                        targetID: item.id,
                                        items: viewModel.items,
                                        draggingID: $draggingID,
                                        dropTargetID: $dropTargetID,
                                        dropIsSplitMode: $dropIsSplitMode,
                                        onMove: { source, dest in
                                            viewModel.moveWorkspace(from: source, to: dest)
                                        },
                                        onMovePaneTab: { payload in
                                            if let direction = payload.splitTarget {
                                                viewModel.splitPanelToWorkspace(
                                                    panelID: payload.panelID,
                                                    sourceWorkspaceID: payload.sourceWorkspaceID,
                                                    targetWorkspaceID: item.id,
                                                    direction: direction
                                                )
                                            } else {
                                                viewModel.movePanelToWorkspace(
                                                    panelID: payload.panelID,
                                                    sourceWorkspaceID: payload.sourceWorkspaceID,
                                                    targetWorkspaceID: item.id
                                                )
                                            }
                                        }
                                    )
                                )
                            }
                        }
                        .onMove { source, destination in
                            viewModel.moveWorkspace(from: source, to: destination)
                        }

                        // Settings tab — appears in the list only when active
                        if viewModel.selection == .settings {
                            HStack(spacing: 8) {
                                Image(systemName: "gearshape.fill")
                                    .font(.system(size: 12))
                                    .foregroundStyle(.primary)
                                Text(String(localized: "settings.title", defaultValue: "Settings"))
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundStyle(.primary)
                                Spacer()
                                Button(action: {
                                    viewModel.selectWorkspace(id: viewModel.lastWorkspaceID)
                                }) {
                                    Image(systemName: "xmark")
                                        .font(.system(size: 9, weight: .semibold))
                                        .foregroundStyle(.tertiary)
                                        .frame(width: 18, height: 18)
                                        .background(.quaternary, in: Circle())
                                }
                                .buttonStyle(.plain)
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 10)
                            .background(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(.selection)
                            )
                            .padding(.horizontal, 8)
                        }

                    }
                    .padding(.top, 4)
                }
        }
        .ignoresSafeArea(.container, edges: .top)
        .background {
            SidebarBackgroundView()
                .ignoresSafeArea(.container, edges: .top)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("namu-sidebar-list")
    }

    // MARK: - Subviews

    /// Callback to open the command palette — injected by ContentView.
    var onOpenCommandPalette: () -> Void = {}

    @State private var isAddHovered = false
    @State private var isBellHovered = false
    @State private var isSearchHovered = false

    private var sidebarTitlebarButtons: some View {
        VStack(spacing: 12) {
            // Row 1: traffic light row — buttons pushed right
            HStack(spacing: 4) {
                Spacer()

                Button(action: { viewModel.createWorkspace() }) {
                    Image(systemName: "plus")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(isAddHovered ? .primary : .secondary)
                        .frame(width: 26, height: 26)
                        .background(
                            isAddHovered ? Color.primary.opacity(0.08) : Color.clear,
                            in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                        )
                        .contentShape(RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
                .onHover { isAddHovered = $0 }
                .animation(.easeOut(duration: 0.12), value: isAddHovered)
                .help(String(localized: "sidebar.addButton.tooltip", defaultValue: "New Workspace (⌘N)"))
                .accessibilityIdentifier("namu-new-workspace-button")

                Button(action: { viewModel.toggleNotifications() }) {
                    ZStack(alignment: .topTrailing) {
                        Image(systemName: viewModel.selection == .notifications ? "bell.fill" : "bell")
                            .font(.system(size: 12))
                            .foregroundStyle(
                                viewModel.selection == .notifications ? Color.accentColor
                                : isBellHovered ? .primary : .secondary
                            )

                        if viewModel.notificationUnreadCount > 0 {
                            Text(viewModel.notificationUnreadCount > 99 ? "99+" : "\(viewModel.notificationUnreadCount)")
                                .font(.system(size: 7, weight: .bold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 3)
                                .padding(.vertical, 1)
                                .background(Color.red, in: Capsule())
                                .offset(x: 7, y: -5)
                        }
                    }
                    .frame(width: 26, height: 26)
                    .background(
                        isBellHovered ? Color.primary.opacity(0.08) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                    )
                    .contentShape(RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
                .onHover { isBellHovered = $0 }
                .animation(.easeOut(duration: 0.12), value: isBellHovered)
                .help(String(localized: "sidebar.notifications.tooltip", defaultValue: "Notifications (⌘⇧I)"))
            }

            // Row 2: Search bar
            Button(action: onOpenCommandPalette) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                    Text(String(localized: "sidebar.search.placeholder", defaultValue: "Search..."))
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                    Spacer()
                    Text("⌘K")
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .foregroundStyle(.quaternary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    isSearchHovered ? Color.primary.opacity(0.06) : Color.primary.opacity(0.03),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                )
            }
            .buttonStyle(.plain)
            .onHover { isSearchHovered = $0 }
            .animation(.easeOut(duration: 0.12), value: isSearchHovered)
        }
        .padding(.horizontal, 12)
        .padding(.top, 7)
        .padding(.bottom, 8)
    }

    @ViewBuilder
    private func renameField(for item: SidebarItemData) -> some View {
        TextField(String(localized: "sidebar.rename.placeholder", defaultValue: "Workspace name"), text: $renameText)
            .textFieldStyle(.plain)
            .font(.system(size: 13, weight: .semibold))
            .padding(.vertical, 6)
            .padding(.horizontal, 18)
            .onSubmit { commitRename(id: item.id) }
            .onExitCommand { cancelRename() }
    }

    // MARK: - Rename helpers

    private func beginRename(item: SidebarItemData) {
        renameText = item.title
        renamingID = item.id
    }

    private func commitRename(id: UUID) {
        let trimmed = renameText.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty {
            viewModel.renameWorkspace(id: id, title: trimmed)
        }
        cancelRename()
    }

    private func cancelRename() {
        renamingID = nil
        renameText = ""
    }
}

// MARK: - Sidebar background (NSVisualEffectView + tint overlay from AppearanceManager)

private struct SidebarBackgroundView: View {
    @ObservedObject private var appearance = AppearanceManager.shared

    var body: some View {
        ZStack {
            SidebarMaterialView(material: appearance.sidebarMaterial.nsVisualEffect)
            // Tint overlay — resolves light/dark color automatically.
            resolvedTintColor
        }
    }

    private var resolvedTintColor: Color {
        let hex = appearance.resolvedSidebarTintColorHex
        return Color(nsColor: NSColor.fromHex(hex).withAlphaComponent(CGFloat(appearance.sidebarTintOpacity)))
    }
}

private struct SidebarMaterialView: NSViewRepresentable {
    let material: NSVisualEffectView.Material

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
    }
}

private extension NSColor {
    static func fromHex(_ hex: String) -> NSColor {
        var h = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if h.hasPrefix("#") { h.removeFirst() }
        guard h.count == 6, let rgb = UInt64(h, radix: 16) else { return .black }
        return NSColor(
            red: CGFloat((rgb >> 16) & 0xFF) / 255,
            green: CGFloat((rgb >> 8) & 0xFF) / 255,
            blue: CGFloat(rgb & 0xFF) / 255,
            alpha: 1.0
        )
    }
}

// MARK: - WorkspaceDropDelegate

/// Handles drop targeting and reordering of workspace rows,
/// and accepting pane tab drops from other workspaces.
private struct WorkspaceDropDelegate: DropDelegate {
    let targetID: UUID
    let items: [SidebarItemData]
    @Binding var draggingID: UUID?
    @Binding var dropTargetID: UUID?
    @Binding var dropIsSplitMode: Bool
    let onMove: (IndexSet, Int) -> Void
    var onMovePaneTab: ((PaneTabDragPayload) -> Void)? = nil

    func dropEntered(info: DropInfo) {
        dropTargetID = targetID
        updateSplitModeHint()
    }

    func dropExited(info: DropInfo) {
        if dropTargetID == targetID {
            dropTargetID = nil
            dropIsSplitMode = false
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        updateSplitModeHint()
        return DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        defer {
            draggingID = nil
            dropTargetID = nil
            dropIsSplitMode = false
        }

        // Pane tab drop takes priority over workspace reorder
        if let provider = info.itemProviders(for: [.namuPaneTab]).first {
            // Use NSApp.currentEvent?.modifierFlags — refers to the event being processed,
            // more reliable than the NSEvent class property during drag callbacks.
            let modifiers = NSApp.currentEvent?.modifierFlags ?? NSEvent.modifierFlags
            let isShift = modifiers.contains(.shift)
            let isOption = modifiers.contains(.option)
            provider.loadDataRepresentation(forTypeIdentifier: UTType.namuPaneTab.identifier) { data, _ in
                guard let data,
                      let decoded = try? JSONDecoder().decode(PaneTabDragPayload.self, from: data),
                      decoded.sourceWorkspaceID != targetID else { return }
                let splitTarget: SplitDirection?
                if isShift && isOption {
                    splitTarget = .vertical
                } else if isShift {
                    splitTarget = .horizontal
                } else {
                    splitTarget = nil
                }
                let payload = PaneTabDragPayload(
                    panelID: decoded.panelID,
                    sourceWorkspaceID: decoded.sourceWorkspaceID,
                    splitTarget: splitTarget
                )
                DispatchQueue.main.async {
                    onMovePaneTab?(payload)
                }
            }
            return true
        }

        guard let provider = info.itemProviders(for: [.namuWorkspace]).first else { return false }

        provider.loadDataRepresentation(forTypeIdentifier: UTType.namuWorkspace.identifier) { data, _ in
            guard
                let data = data,
                let idString = String(data: data, encoding: .utf8),
                let sourceID = UUID(uuidString: idString),
                let fromIdx = items.firstIndex(where: { $0.id == sourceID }),
                let toIdx = items.firstIndex(where: { $0.id == targetID }),
                fromIdx != toIdx
            else { return }

            DispatchQueue.main.async {
                // Insert after target when dragging downward, before when dragging upward.
                let destination = fromIdx < toIdx ? toIdx + 1 : toIdx
                onMove(IndexSet(integer: fromIdx), destination)
            }
        }
        return true
    }

    func validateDrop(info: DropInfo) -> Bool {
        // Accept pane tab drops from other workspaces
        if info.hasItemsConforming(to: [.namuPaneTab]) { return true }
        guard let dragging = draggingID else { return false }
        return dragging != targetID
    }

    // MARK: - Private

    private func updateSplitModeHint() {
        let modifiers = NSApp.currentEvent?.modifierFlags ?? NSEvent.modifierFlags
        dropIsSplitMode = modifiers.contains(.shift)
    }
}
