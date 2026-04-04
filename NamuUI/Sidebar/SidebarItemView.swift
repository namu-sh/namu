import SwiftUI

// PERF: SidebarItemView is Equatable so SwiftUI skips body re-evaluation when
// the parent rebuilds with unchanged values.
struct SidebarItemView: View, Equatable {
    nonisolated static func == (lhs: SidebarItemView, rhs: SidebarItemView) -> Bool {
        lhs.title == rhs.title &&
        lhs.isSelected == rhs.isSelected &&
        lhs.isPinned == rhs.isPinned &&
        lhs.customColor == rhs.customColor &&
        lhs.panelCount == rhs.panelCount &&
        lhs.gitBranch == rhs.gitBranch &&
        lhs.gitDirty == rhs.gitDirty &&
        lhs.workingDirectory == rhs.workingDirectory &&
        lhs.listeningPorts == rhs.listeningPorts &&
        lhs.shellState == rhs.shellState &&
        lhs.lastExitCode == rhs.lastExitCode &&
        lhs.lastCommand == rhs.lastCommand &&
        lhs.hasActivity == rhs.hasActivity &&
        lhs.progress == rhs.progress &&
        lhs.unreadCount == rhs.unreadCount &&
        lhs.isRemoteSSH == rhs.isRemoteSSH &&
        lhs.remoteConnectionDetail == rhs.remoteConnectionDetail &&
        lhs.remoteConnectionState == rhs.remoteConnectionState &&
        lhs.availableWindows.map(\.id) == rhs.availableWindows.map(\.id)
    }

    // MARK: - Data

    let title: String
    let isSelected: Bool
    let isPinned: Bool
    let customColor: String?
    let panelCount: Int
    let gitBranch: String?
    let gitDirty: Bool
    let workingDirectory: String?
    let listeningPorts: [PortInfo]
    let shellState: ShellState
    var lastExitCode: Int? = nil
    var lastCommand: String? = nil
    var hasActivity: Bool = false
    var progress: Double? = nil
    var unreadCount: Int = 0
    var isRemoteSSH: Bool = false
    var remoteConnectionDetail: String? = nil
    var remoteConnectionState: String? = nil
    var remoteForwardedPorts: [PortInfo]? = nil
    var notificationSubtitle: String? = nil
    var progressLabel: String? = nil
    var latestLog: String? = nil
    var logLevel: String? = nil
    var pullRequests: [PullRequestDisplay] = []
    var panelBranches: [UUID: String] = [:]
    var metadataEntries: [(String, String)] = []
    var statusEntries: [String: SidebarStatusEntry] = [:]
    var markdownBlocks: [String] = []

    // MARK: - Actions

    var onSelect: () -> Void = {}
    var onRename: () -> Void = {}
    var onTogglePin: () -> Void = {}
    var onSetColor: (String?) -> Void = { _ in }
    var onClose: () -> Void = {}
    var availableWindows: [(id: UUID, title: String)] = []
    var onMoveToWindow: ((UUID) -> Void)?
    var onReconnectSSH: (() -> Void)?
    var onDisconnectSSH: (() -> Void)?

    // MARK: - State

    @State private var isHovering = false
    @State private var showColorPopover = false

    // MARK: - Body

    var body: some View {
        HStack(spacing: 0) {
            // Leading indicator column
            leadingIndicator
                .frame(width: 16)
                .padding(.trailing, 4)

            // Content: 2 fixed lines
            VStack(alignment: .leading, spacing: 2) {
                titleLine
                contextLine
            }

            Spacer(minLength: 4)

            // Trailing column — badges or close button
            trailingArea
                .frame(width: 28, alignment: .trailing)
        }
        .padding(.vertical, 4)
        .padding(.leading, 4)
        .padding(.trailing, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .bottom) {
            // Progress strip — 2pt, overlaid at bottom edge
            if let pct = progress {
                ProgressView(value: max(0, min(1, pct)))
                    .progressViewStyle(.linear)
                    .tint(.accentColor)
                    .scaleEffect(y: 0.4, anchor: .bottom)
                    .padding(.horizontal, 4)
            } else if hasActivity {
                ProgressView()
                    .progressViewStyle(.linear)
                    .tint(.accentColor)
                    .scaleEffect(y: 0.4, anchor: .bottom)
                    .padding(.horizontal, 4)
            }
        }
        .background(rowBackground)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) { isHovering = hovering }
        }
        .popover(isPresented: $showColorPopover, arrowEdge: .trailing) {
            colorPopoverContent
        }
        .contextMenu { contextMenuContent }
    }

    // MARK: - Leading Indicator

    @ViewBuilder
    private var leadingIndicator: some View {
        Group {
            if isPinned {
                Image(systemName: "pin.fill")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(pinColor)
            } else if let hex = customColor, let color = Color(hex: hex) {
                Circle()
                    .fill(color)
                    .frame(width: 7, height: 7)
            } else {
                Circle()
                    .fill(shellDotColor)
                    .frame(width: 6, height: 6)
            }
        }
        .frame(width: 16, height: 32)
        .contentShape(Rectangle())
        .onTapGesture { showColorPopover = true }
    }

    private var pinColor: Color {
        if let hex = customColor, let c = Color(hex: hex) { return c }
        return .accentColor
    }

    // MARK: - Title Line

    private var titleLine: some View {
        HStack(spacing: 4) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.tail)
                .accessibilityIdentifier("namu-workspace-title")

            Spacer(minLength: 0)
        }
    }

    // MARK: - Context Line

    private var contextLine: some View {
        HStack(spacing: 0) {
            Text(contextString)
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 0)
        }
    }

    private var contextString: String {
        // Error state takes priority
        if let code = lastExitCode, code != 0 {
            let base = "exit \(code)"
            if let cmd = lastCommand { return "\(base) \u{b7} \(cmd)" }
            return base
        }

        // Running command takes priority
        if case .running(let cmd) = shellState, !cmd.isEmpty {
            return cmd
        }

        // Normal: build segments joined by " · "
        var parts: [String] = []

        if isRemoteSSH {
            if let detail = remoteConnectionDetail {
                parts.append(detail)
            }
            if let state = remoteConnectionState, state != "connected" {
                parts.append(state)
            }
        }

        if let branch = gitBranch {
            parts.append(branch + (gitDirty ? "*" : ""))
        }

        if let dir = workingDirectory {
            parts.append(shortenedPath(dir))
        }

        if !listeningPorts.isEmpty {
            parts.append(listeningPorts.prefix(2).map { ":\($0.port)" }.joined(separator: " "))
        }

        return parts.joined(separator: " \u{b7} ")
    }

    // MARK: - Trailing Area

    @ViewBuilder
    private var trailingArea: some View {
        ZStack {
            // Badges — hidden on hover
            HStack(spacing: 3) {
                if panelCount > 1 {
                    Text("\(panelCount)")
                        .font(.system(size: 9, weight: .medium, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.tertiary)
                }
                if unreadCount > 0 {
                    Text(unreadCount < 100 ? "\(unreadCount)" : "99+")
                        .font(.system(size: 8, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.white)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(.red, in: Capsule())
                }
            }
            .opacity(isHovering ? 0 : 1)

            // Close button — visible on hover
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .frame(width: 16, height: 16)
                    .background(.quaternary, in: Circle())
            }
            .buttonStyle(.plain)
            .opacity(isHovering ? 1 : 0)
            .help(String(localized: "sidebar.item.close.tooltip", defaultValue: "Close Workspace"))
        }
    }

    // MARK: - Row Background

    @ViewBuilder
    private var rowBackground: some View {
        if isSelected {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(NamuColors.selectedBackground)
        } else if isHovering {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(NamuColors.hoverBackground)
        }
    }

    // MARK: - Shell Dot Color

    private var shellDotColor: Color {
        switch shellState {
        case .idle(let code):
            if let c = code, c != 0 { return .red }
            return .secondary.opacity(0.3)
        case .prompt:       return .green
        case .running:      return .orange
        case .commandInput: return .yellow
        case .unknown:      return .secondary.opacity(0.15)
        }
    }

    // MARK: - Helpers

    private func shortenedPath(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }

    // MARK: - Color Popover

    private var colorPopoverContent: some View {
        VStack(spacing: 8) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 20), spacing: 6)], spacing: 6) {
                ForEach(WorkspaceColorPaletteSettings.allColors(), id: \.self) { hex in
                    Circle()
                        .fill(Color(hex: hex) ?? .gray)
                        .frame(width: 18, height: 18)
                        .overlay(
                            Circle().strokeBorder(
                                customColor == hex ? Color.primary : Color.clear,
                                lineWidth: 2
                            )
                        )
                        .onTapGesture {
                            onSetColor(hex)
                            showColorPopover = false
                        }
                }
            }
            if customColor != nil {
                Button(String(localized: "sidebar.color.clear", defaultValue: "Clear Color")) {
                    onSetColor(nil)
                    showColorPopover = false
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(width: 160)
    }

    // MARK: - Context Menu

    @ViewBuilder
    private var contextMenuContent: some View {
        Button(String(localized: "sidebar.item.menu.rename", defaultValue: "Rename")) { onRename() }

        Button(isPinned
            ? String(localized: "sidebar.item.menu.unpin", defaultValue: "Unpin")
            : String(localized: "sidebar.item.menu.pin", defaultValue: "Pin")
        ) { onTogglePin() }

        Divider()

        Menu(String(localized: "sidebar.item.menu.setColor", defaultValue: "Set Color")) {
            ForEach(WorkspaceColorPaletteSettings.allColors(), id: \.self) { hex in
                Button(hex) { onSetColor(hex) }
            }
            Divider()
            Button(String(localized: "sidebar.item.color.clear", defaultValue: "Clear Color")) { onSetColor(nil) }
        }

        if !availableWindows.isEmpty, let onMoveToWindow {
            Divider()
            Menu(String(localized: "sidebar.item.menu.moveToWindow", defaultValue: "Move to Window")) {
                ForEach(availableWindows, id: \.id) { window in
                    Button(window.title) { onMoveToWindow(window.id) }
                }
            }
        }

        if isRemoteSSH {
            Divider()
            Button(String(localized: "sidebar.item.menu.reconnectSSH", defaultValue: "Reconnect SSH")) {
                onReconnectSSH?()
            }.disabled(onReconnectSSH == nil)
            Button(String(localized: "sidebar.item.menu.disconnectSSH", defaultValue: "Disconnect SSH")) {
                onDisconnectSSH?()
            }.disabled(onDisconnectSSH == nil)
        }

        Divider()
        Button(String(localized: "sidebar.item.menu.closeWorkspace", defaultValue: "Close Workspace"), role: .destructive) { onClose() }
    }
}
