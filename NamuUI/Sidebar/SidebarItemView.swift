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
        lhs.hasActivity == rhs.hasActivity &&
        lhs.progress == rhs.progress &&
        lhs.unreadCount == rhs.unreadCount &&
        lhs.notificationSubtitle == rhs.notificationSubtitle &&
        lhs.progressLabel == rhs.progressLabel &&
        lhs.latestLog == rhs.latestLog &&
        lhs.logLevel == rhs.logLevel &&
        lhs.isRemoteSSH == rhs.isRemoteSSH &&
        lhs.pullRequests == rhs.pullRequests &&
        lhs.panelBranches == rhs.panelBranches &&
        lhs.metadataEntries.count == rhs.metadataEntries.count &&
        zip(lhs.metadataEntries, rhs.metadataEntries).allSatisfy({ $0 == $1 }) &&
        lhs.statusEntries == rhs.statusEntries &&
        lhs.markdownBlocks == rhs.markdownBlocks &&
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
    var hasActivity: Bool = false
    var progress: Double? = nil
    var unreadCount: Int = 0
    var notificationSubtitle: String? = nil
    var progressLabel: String? = nil
    var latestLog: String? = nil
    var logLevel: String? = nil
    var isRemoteSSH: Bool = false
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
            // Leading color indicator
            leadingIndicator
                .frame(width: 14)

            VStack(alignment: .leading, spacing: 0) {
                // Always visible: title row
                titleRow
                    .padding(.bottom, 3)

                // Always visible: subtitle row
                subtitleRow

                // Detail drawer — only when selected (hover just highlights)
                if isSelected {
                    detailDrawer
                        .padding(.top, 6)
                        .transition(.opacity)
                }

                // Progress always visible when active
                if progress != nil || hasActivity {
                    progressView
                        .padding(.top, 5)
                }
            }

            Spacer(minLength: 4)

            // Trailing accessories
            trailingAccessories
        }
        .padding(.vertical, 10)
        .padding(.trailing, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(rowBackground)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.15)) { isHovering = hovering }
        }
        .onTapGesture { onSelect() }
        .animation(.easeInOut(duration: 0.2), value: isSelected)
        .animation(.easeOut(duration: 0.15), value: isHovering)
        .contextMenu { contextMenuContent }
    }

    // MARK: - Leading Indicator

    @ViewBuilder
    private var leadingIndicator: some View {
        VStack(spacing: 4) {
            if let hex = customColor, let color = Color(hex: hex) {
                Circle()
                    .fill(color)
                    .frame(width: 8, height: 8)
            } else if isPinned {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(Color.accentColor)
                    .frame(width: 3, height: 16)
            } else {
                Circle()
                    .fill(shellDotColor)
                    .frame(width: 6, height: 6)
            }
        }
        .frame(width: 14, height: 30)
        .contentShape(Rectangle())
        .onTapGesture { showColorPopover = true }
        .popover(isPresented: $showColorPopover, arrowEdge: .trailing) {
            colorPopoverContent
        }
    }

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

    // MARK: - Title Row

    private var titleRow: some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.tail)
                .accessibilityIdentifier("namu-workspace-title")

            if panelCount > 1 {
                Text("\(panelCount)")
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(.quaternary, in: Capsule())
            }

            Spacer(minLength: 0)

            if isHovering {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .frame(width: 18, height: 18)
                        .background(.quaternary, in: Circle())
                }
                .buttonStyle(.plain)
                .transition(.scale(scale: 0.5).combined(with: .opacity))
                .help(String(localized: "sidebar.item.close.tooltip", defaultValue: "Close Workspace"))
            }
        }
    }

    // MARK: - Subtitle Row

    private var subtitleRow: some View {
        HStack(spacing: 5) {
            if isRemoteSSH {
                Image(systemName: "globe")
                    .font(.system(size: 9))
                    .foregroundStyle(.orange)
            }

            if let branch = gitBranch {
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                Text(branch)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if gitDirty {
                    Circle()
                        .fill(.orange)
                        .frame(width: 5, height: 5)
                }
            } else if let dir = workingDirectory {
                Image(systemName: "folder")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                Text(shortenedPath(dir))
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            if !listeningPorts.isEmpty {
                Text(listeningPorts.prefix(2).map { ":\($0.port)" }.joined(separator: " "))
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }

            Spacer(minLength: 0)
        }
    }

    // MARK: - Detail Drawer (progressive disclosure)

    @ViewBuilder
    private var detailDrawer: some View {
        VStack(alignment: .leading, spacing: 5) {
            if let subtitle = notificationSubtitle, !subtitle.isEmpty {
                Label(subtitle, systemImage: "bell.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            if !panelBranches.isEmpty && panelBranches.count > 1 {
                let branches = Array(panelBranches.values).filter { $0 != gitBranch }
                if !branches.isEmpty {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.triangle.branch")
                            .font(.system(size: 8))
                            .foregroundStyle(.tertiary)
                        Text(branches.prefix(3).joined(separator: ", "))
                            .font(.system(size: 10.5))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }
            }

            ForEach(pullRequests, id: \.number) { pr in
                pullRequestRow(pr)
            }

            let sortedStatus = statusEntries.values
                .sorted { lhs, rhs in
                    if lhs.priority != rhs.priority { return lhs.priority > rhs.priority }
                    return lhs.timestamp > rhs.timestamp
                }
            if !sortedStatus.isEmpty {
                FlowLayout(spacing: 4) {
                    ForEach(Array(sortedStatus.prefix(4)), id: \.key) { entry in
                        statusPill(entry)
                    }
                }
            }

            ForEach(metadataEntries.prefix(3), id: \.0) { key, value in
                HStack(spacing: 4) {
                    Text(key).font(.system(size: 10, weight: .medium)).foregroundStyle(.tertiary)
                    Text(value).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                }
            }

            ForEach(markdownBlocks.prefix(2), id: \.self) { block in
                if let attributed = try? AttributedString(
                    markdown: block,
                    options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
                ) {
                    Text(attributed).font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(3)
                }
            }

            if listeningPorts.count > 2 {
                HStack(spacing: 4) {
                    ForEach(listeningPorts.prefix(4), id: \.port) { info in
                        portBadge(info)
                    }
                    if listeningPorts.count > 4 {
                        Text("+\(listeningPorts.count - 4)")
                            .font(.system(size: 9.5, weight: .medium))
                            .foregroundStyle(.tertiary)
                    }
                }
            }

            if let log = latestLog, !log.isEmpty {
                HStack(spacing: 4) {
                    Image(systemName: logLevelIcon)
                        .font(.system(size: 9))
                        .foregroundStyle(logLevelColor)
                    Text(log)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
    }

    // MARK: - Progress

    @ViewBuilder
    private var progressView: some View {
        if let pct = progress {
            VStack(alignment: .leading, spacing: 2) {
                if let label = progressLabel, !label.isEmpty {
                    Text(label)
                        .font(.system(size: 9.5))
                        .foregroundStyle(.tertiary)
                }
                ProgressView(value: max(0, min(1, pct)))
                    .progressViewStyle(.linear)
                    .tint(.accentColor)
                    .scaleEffect(y: 0.6, anchor: .center)
            }
        } else if hasActivity {
            ProgressView()
                .progressViewStyle(.linear)
                .tint(.accentColor)
                .scaleEffect(y: 0.6, anchor: .center)
        }
    }

    // MARK: - Trailing Accessories

    @ViewBuilder
    private var trailingAccessories: some View {
        VStack(alignment: .trailing, spacing: 4) {
            if unreadCount > 0 {
                Text(unreadCount < 100 ? "\(unreadCount)" : "99+")
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(.red, in: Capsule())
                    .transition(.scale.combined(with: .opacity))
            }
            if isPinned && customColor == nil {
                Image(systemName: "pin.fill")
                    .font(.system(size: 8))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(45))
            }
        }
    }

    // MARK: - Row Background

    @ViewBuilder
    private var rowBackground: some View {
        if isSelected {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(.selection)
        } else if isHovering {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(0.04))
        }
    }

    // MARK: - Shell Dot Color

    private var shellDotColor: Color {
        switch shellState {
        case .idle:         return .secondary.opacity(0.3)
        case .prompt:       return .green
        case .running:      return .orange
        case .commandInput: return .yellow
        case .unknown:      return .secondary.opacity(0.15)
        }
    }

    // MARK: - Sub-views

    private func statusPill(_ entry: SidebarStatusEntry) -> some View {
        HStack(spacing: 3) {
            if let icon = entry.icon {
                Image(systemName: icon)
                    .font(.system(size: 8))
            }
            Text(entry.key.isEmpty ? entry.value : entry.key)
                .font(.system(size: 9.5, weight: .medium))
            if !entry.key.isEmpty && !entry.value.isEmpty {
                Text(entry.value)
                    .font(.system(size: 9.5))
            }
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(
            entry.color.flatMap { Color(hex: $0) }?.opacity(0.15) ?? Color.primary.opacity(0.05),
            in: Capsule()
        )
    }

    private func portBadge(_ info: PortInfo) -> some View {
        Text(info.processName.map { "\($0):\(info.port)" } ?? ":\(info.port)")
            .font(.system(size: 9.5, weight: .medium, design: .monospaced))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
    }

    @ViewBuilder
    private func pullRequestRow(_ pr: PullRequestDisplay) -> some View {
        HStack(spacing: 5) {
            Image(systemName: "arrow.triangle.pull")
                .font(.system(size: 9))
                .foregroundStyle(prStateColor(pr.state))
            Text("#\(pr.number)")
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(.primary)
            Text(prStateLabel(pr.state))
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 5)
                .padding(.vertical, 1.5)
                .background(prStateColor(pr.state), in: Capsule())
            if let checks = pr.checksStatus, checks != .none {
                Image(systemName: checks == .pass ? "checkmark.circle.fill" : checks == .fail ? "xmark.circle.fill" : "circle.dotted")
                    .font(.system(size: 10))
                    .foregroundStyle(checks == .pass ? .green : checks == .fail ? .red : .secondary)
            }
        }
    }

    private func prStateLabel(_ state: PRState) -> String {
        switch state {
        case .open: return "Open"
        case .merged: return "Merged"
        case .closed: return "Closed"
        }
    }

    private func prStateColor(_ state: PRState) -> Color {
        switch state {
        case .open: return .green
        case .merged: return .purple
        case .closed: return .red
        }
    }

    private func shortenedPath(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }

    private var logLevelIcon: String {
        switch logLevel {
        case "error": return "exclamationmark.circle.fill"
        case "warning": return "exclamationmark.triangle.fill"
        case "success": return "checkmark.circle.fill"
        default: return "info.circle.fill"
        }
    }

    private var logLevelColor: Color {
        switch logLevel {
        case "error": return .red
        case "warning": return .orange
        case "success": return .green
        default: return .secondary
        }
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

// MARK: - FlowLayout (horizontal wrapping for pills)

private struct FlowLayout: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = arrange(proposal: proposal, subviews: subviews)
        return result.size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrange(proposal: proposal, subviews: subviews)
        for (index, position) in result.positions.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + position.x, y: bounds.minY + position.y), proposal: .unspecified)
        }
    }

    private func arrange(proposal: ProposedViewSize, subviews: Subviews) -> (positions: [CGPoint], size: CGSize) {
        let maxWidth = proposal.width ?? .infinity
        var positions: [CGPoint] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var totalWidth: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > maxWidth && x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            positions.append(CGPoint(x: x, y: y))
            rowHeight = max(rowHeight, size.height)
            x += size.width + spacing
            totalWidth = max(totalWidth, x - spacing)
        }
        return (positions, CGSize(width: totalWidth, height: y + rowHeight))
    }
}
