import SwiftUI

// PERF: SidebarItemView is Equatable so SwiftUI skips body re-evaluation when
// the parent rebuilds with unchanged values. Without this, every WorkspaceManager
// publish causes ALL sidebar items to re-evaluate during typing.
// Do NOT add @EnvironmentObject or @ObservedObject — use precomputed let props.
// Do NOT remove .equatable() from the call site in SidebarView.
struct SidebarItemView: View, Equatable {
    // All rendering inputs are precomputed value types so == is cheap and correct.
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
        lhs.markdownBlocks == rhs.markdownBlocks
    }

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
    let hasActivity: Bool
    let progress: Double?
    let unreadCount: Int
    let notificationSubtitle: String?
    let progressLabel: String?
    let latestLog: String?
    let logLevel: String?
    let isRemoteSSH: Bool
    let pullRequests: [PullRequestDisplay]
    let panelBranches: [UUID: String]
    let metadataEntries: [(String, String)]
    let markdownBlocks: [String]

    init(
        title: String,
        isSelected: Bool,
        isPinned: Bool,
        customColor: String? = nil,
        panelCount: Int,
        gitBranch: String? = nil,
        gitDirty: Bool = false,
        workingDirectory: String? = nil,
        listeningPorts: [PortInfo] = [],
        shellState: ShellState = .unknown,
        hasActivity: Bool = false,
        progress: Double? = nil,
        unreadCount: Int = 0,
        notificationSubtitle: String? = nil,
        progressLabel: String? = nil,
        latestLog: String? = nil,
        logLevel: String? = nil,
        isRemoteSSH: Bool = false,
        pullRequests: [PullRequestDisplay] = [],
        panelBranches: [UUID: String] = [:],
        metadataEntries: [(String, String)] = [],
        markdownBlocks: [String] = [],
        onSelect: @escaping () -> Void = {},
        onRename: @escaping () -> Void = {},
        onTogglePin: @escaping () -> Void = {},
        onSetColor: @escaping (String?) -> Void = { _ in },
        onClose: @escaping () -> Void = {}
    ) {
        self.title = title
        self.isSelected = isSelected
        self.isPinned = isPinned
        self.customColor = customColor
        self.panelCount = panelCount
        self.gitBranch = gitBranch
        self.gitDirty = gitDirty
        self.workingDirectory = workingDirectory
        self.listeningPorts = listeningPorts
        self.shellState = shellState
        self.hasActivity = hasActivity
        self.progress = progress
        self.unreadCount = unreadCount
        self.notificationSubtitle = notificationSubtitle
        self.progressLabel = progressLabel
        self.latestLog = latestLog
        self.logLevel = logLevel
        self.isRemoteSSH = isRemoteSSH
        self.pullRequests = pullRequests
        self.panelBranches = panelBranches
        self.metadataEntries = metadataEntries
        self.markdownBlocks = markdownBlocks
        self.onSelect = onSelect
        self.onRename = onRename
        self.onTogglePin = onTogglePin
        self.onSetColor = onSetColor
        self.onClose = onClose
    }

    // Action closures are excluded from == — they're recreated on every parent
    // eval but don't affect rendering, so comparing them would always be false.
    var onSelect: () -> Void
    var onRename: () -> Void
    var onTogglePin: () -> Void
    var onSetColor: (String?) -> Void
    var onClose: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 8) {
            // Color dot / pin indicator rail
            ZStack {
                Rectangle()
                    .fill(isPinned ? Color.accentColor : Color.clear)
                    .frame(width: 3)
                    .cornerRadius(1.5)
                if let hex = customColor, let color = Color(hex: hex) {
                    Circle()
                        .fill(color)
                        .frame(width: 8, height: 8)
                }
            }
            .frame(width: 8)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(isSelected ? .white : .primary)
                        .lineLimit(1)
                        .truncationMode(.tail)

                    Spacer()

                    // Panel count badge
                    if panelCount > 1 {
                        Text("\(panelCount)")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(isSelected ? Color.white.opacity(0.8) : .secondary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(
                                Capsule()
                                    .fill(isSelected
                                        ? Color.white.opacity(0.25)
                                        : Color.secondary.opacity(0.15))
                            )
                    }

                    // Close button on hover
                    if isHovering {
                        Button(action: onClose) {
                            Image(systemName: "xmark")
                                .font(.system(size: 9, weight: .medium))
                                .foregroundColor(isSelected ? Color.white.opacity(0.7) : .secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }

                // Notification subtitle
                if let subtitle = notificationSubtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 10))
                        .foregroundColor(isSelected ? Color.white.opacity(0.7) : .secondary)
                        .lineLimit(2)
                }

                // Remote SSH indicator
                if isRemoteSSH {
                    HStack(spacing: 3) {
                        Image(systemName: "network")
                            .font(.system(size: 9))
                            .foregroundColor(isSelected ? Color.white.opacity(0.7) : .orange)
                        Text("Remote")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(isSelected ? Color.white.opacity(0.7) : .orange)
                    }
                }

                // Second line: git branch or working directory + shell state dot
                HStack(spacing: 4) {
                    if let branch = gitBranch {
                        HStack(spacing: 3) {
                            Image(systemName: "arrow.triangle.branch")
                                .font(.system(size: 9))
                                .foregroundColor(isSelected ? Color.white.opacity(0.7) : .secondary)
                            Text(branch)
                                .font(.system(size: 11))
                                .foregroundColor(isSelected ? Color.white.opacity(0.7) : .secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            // Git dirty indicator
                            if gitDirty {
                                Text("●")
                                    .font(.system(size: 8))
                                    .foregroundColor(isSelected ? Color.yellow.opacity(0.9) : .orange)
                            }
                        }
                    } else if let dir = workingDirectory {
                        Text(shortenedPath(dir))
                            .font(.system(size: 11))
                            .foregroundColor(isSelected ? Color.white.opacity(0.7) : .secondary)
                            .lineLimit(1)
                            .truncationMode(.head)
                    }

                    Spacer()

                    // Shell state indicator dot
                    shellStateDot
                }

                // Per-panel branches (when splits are in different repos)
                if !panelBranches.isEmpty && panelBranches.count > 1 {
                    let branches = Array(panelBranches.values).filter { branch in
                        branch != gitBranch
                    }
                    if !branches.isEmpty {
                        HStack(spacing: 3) {
                            Image(systemName: "arrow.triangle.branch")
                                .font(.system(size: 8))
                                .foregroundColor(isSelected ? Color.white.opacity(0.5) : .secondary)
                            ForEach(branches.prefix(3), id: \.self) { branch in
                                Text(branch)
                                    .font(.system(size: 10))
                                    .foregroundColor(isSelected ? Color.white.opacity(0.5) : .secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                        }
                    }
                }

                // Pull request rows
                ForEach(pullRequests, id: \.number) { pr in
                    pullRequestRow(pr)
                }

                // Custom metadata key-value rows
                ForEach(metadataEntries.prefix(4), id: \.0) { key, value in
                    HStack(spacing: 4) {
                        Text(key)
                            .font(.system(size: 9, weight: .medium))
                            .foregroundColor(isSelected ? Color.white.opacity(0.5) : .secondary)
                        Text(value)
                            .font(.system(size: 9))
                            .foregroundColor(isSelected ? Color.white.opacity(0.6) : .secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }

                // Markdown blocks
                ForEach(markdownBlocks.prefix(2), id: \.self) { block in
                    if let attributed = try? AttributedString(
                        markdown: block,
                        options: AttributedString.MarkdownParsingOptions(
                            interpretedSyntax: .inlineOnlyPreservingWhitespace
                        )
                    ) {
                        Text(attributed)
                            .font(.system(size: 10))
                            .foregroundColor(isSelected ? Color.white.opacity(0.7) : .secondary)
                            .lineLimit(3)
                    } else {
                        Text(block)
                            .font(.system(size: 10))
                            .foregroundColor(isSelected ? Color.white.opacity(0.7) : .secondary)
                            .lineLimit(3)
                    }
                }

                // Port badges
                if !listeningPorts.isEmpty {
                    HStack(spacing: 3) {
                        ForEach(listeningPorts.prefix(4), id: \.port) { info in
                            portBadge(info)
                        }
                        if listeningPorts.count > 4 {
                            Text("+\(listeningPorts.count - 4)")
                                .font(.system(size: 9, weight: .medium))
                                .foregroundColor(isSelected ? Color.white.opacity(0.6) : .secondary)
                        }
                    }
                }

                // Latest log entry
                if let log = latestLog, !log.isEmpty {
                    HStack(spacing: 3) {
                        Image(systemName: logLevelIcon)
                            .font(.system(size: 8))
                            .foregroundColor(logLevelColor)
                        Text(log)
                            .font(.system(size: 10))
                            .foregroundColor(isSelected ? Color.white.opacity(0.6) : .secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }

                // Progress bar (determinate or indeterminate activity)
                if let pct = progress {
                    VStack(spacing: 1) {
                        if let label = progressLabel, !label.isEmpty {
                            Text(label)
                                .font(.system(size: 9))
                                .foregroundColor(isSelected ? Color.white.opacity(0.6) : .secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Capsule()
                                    .fill(Color.white.opacity(0.1))
                                    .frame(height: 3)
                                Capsule()
                                    .fill(isSelected ? Color.white.opacity(0.7) : Color.accentColor)
                                    .frame(width: geo.size.width * CGFloat(max(0, min(1, pct))), height: 3)
                            }
                        }
                        .frame(height: 3)
                    }
                } else if hasActivity {
                    IndeterminateProgressBar(isSelected: isSelected)
                        .frame(height: 3)
                }
            }

            // Unread notification badge
            if unreadCount > 0 {
                Text(unreadCount < 100 ? "\(unreadCount)" : "99+")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.red))
                    .transition(.scale.combined(with: .opacity))
            }

            // Pin icon shown on hover when pinned
            if isPinned {
                Image(systemName: "pin.fill")
                    .font(.system(size: 9))
                    .foregroundColor(isSelected ? Color.white.opacity(0.6) : Color.secondary.opacity(0.6))
            }
        }
        .padding(.vertical, 6)
        .padding(.trailing, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isSelected ? Color.accentColor : Color.clear)
        )
        .overlay(
            isSelected ? RoundedRectangle(cornerRadius: 6).stroke(Color.white.opacity(0.3), lineWidth: 1) : nil
        )
        .contentShape(Rectangle())
        .onHover { hovering in isHovering = hovering }
        .onTapGesture { onSelect() }
        .contextMenu {
            Button("Rename") { onRename() }
            Button(isPinned ? "Unpin" : "Pin") { onTogglePin() }
            Divider()
            Menu("Set Color") {
                Button("Red")    { onSetColor("#FF6B6B") }
                Button("Orange") { onSetColor("#FF9F43") }
                Button("Yellow") { onSetColor("#FECA57") }
                Button("Green")  { onSetColor("#1DD1A1") }
                Button("Blue")   { onSetColor("#54A0FF") }
                Button("Purple") { onSetColor("#A29BFE") }
                Button("Pink")   { onSetColor("#FD79A8") }
                Divider()
                Button("Clear Color") { onSetColor(nil) }
            }
            Divider()
            Button("Close Workspace", role: .destructive) { onClose() }
        }
    }

    @ViewBuilder
    private var shellStateDot: some View {
        switch shellState {
        case .idle:
            Circle()
                .fill(Color.secondary.opacity(0.4))
                .frame(width: 6, height: 6)
        case .prompt:
            Circle()
                .fill(Color.green.opacity(0.8))
                .frame(width: 6, height: 6)
        case .running:
            Circle()
                .fill(Color.orange.opacity(0.9))
                .frame(width: 6, height: 6)
        case .commandInput:
            Circle()
                .fill(Color.yellow.opacity(0.8))
                .frame(width: 6, height: 6)
        case .unknown:
            Circle()
                .fill(Color.secondary.opacity(0.2))
                .frame(width: 6, height: 6)
        }
    }

    private var logLevelIcon: String {
        switch logLevel {
        case "error": return "exclamationmark.circle.fill"
        case "warn", "warning": return "exclamationmark.triangle.fill"
        default: return "info.circle.fill"
        }
    }

    private var logLevelColor: Color {
        switch logLevel {
        case "error": return .red
        case "warn", "warning": return .orange
        default: return isSelected ? Color.white.opacity(0.5) : .secondary
        }
    }

    private func portBadge(_ info: PortInfo) -> some View {
        let label = info.processName.map { "\($0):\(info.port)" } ?? "\(info.port)"
        return Text(label)
            .font(.system(size: 9, weight: .medium, design: .monospaced))
            .foregroundColor(isSelected ? Color.white.opacity(0.75) : .secondary)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(
                RoundedRectangle(cornerRadius: 3)
                    .fill(isSelected
                          ? Color.white.opacity(0.2)
                          : Color.secondary.opacity(0.12))
            )
    }

    @ViewBuilder
    private func pullRequestRow(_ pr: PullRequestDisplay) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "arrow.triangle.pull")
                .font(.system(size: 9))
                .foregroundColor(isSelected ? Color.white.opacity(0.7) : prStateColor(pr.state))
            Text("#\(pr.number)")
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(isSelected ? Color.white.opacity(0.8) : .primary)
            prStateBadge(pr.state)
            if let checks = pr.checksStatus, !checks.isEmpty {
                Text(checks)
                    .font(.system(size: 9))
                    .foregroundColor(isSelected ? Color.white.opacity(0.6) : .secondary)
                    .lineLimit(1)
            }
            Spacer()
        }
    }

    @ViewBuilder
    private func prStateBadge(_ state: PRState) -> some View {
        let (label, color) = prStateLabelAndColor(state)
        Text(label)
            .font(.system(size: 8, weight: .semibold))
            .foregroundColor(.white)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(Capsule().fill(color))
    }

    private func prStateLabelAndColor(_ state: PRState) -> (String, Color) {
        switch state {
        case .open:   return ("open", .green)
        case .merged: return ("merged", .purple)
        case .closed: return ("closed", .red)
        }
    }

    private func prStateColor(_ state: PRState) -> Color {
        switch state {
        case .open:   return .green
        case .merged: return .purple
        case .closed: return .red
        }
    }

    private func shortenedPath(_ path: String) -> String {
        // Replace home directory with ~
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path.hasPrefix(home) {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }

    private var rowBackground: some View {
        Group {
            if isSelected {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.blue)
            } else if isHovering {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.primary.opacity(0.07))
            } else {
                Color.clear
            }
        }
    }
}

// MARK: - IndeterminateProgressBar

/// A simple animated shimmer bar for indeterminate activity.
private struct IndeterminateProgressBar: View {
    let isSelected: Bool
    @State private var phase: CGFloat = 0

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.white.opacity(0.1))
                    .frame(height: 3)
                Capsule()
                    .fill(isSelected ? Color.white.opacity(0.6) : Color.accentColor.opacity(0.7))
                    .frame(width: geo.size.width * 0.4, height: 3)
                    .offset(x: phase * geo.size.width)
            }
        }
        .frame(height: 3)
        .onAppear {
            withAnimation(.linear(duration: 1.2).repeatForever(autoreverses: false)) {
                phase = 1.0
            }
        }
        .clipped()
    }
}

// MARK: - Color hex initializer

private extension Color {
    /// Initialize a SwiftUI Color from a hex string like "#FF6B6B" or "FF6B6B".
    init?(hex: String) {
        var h = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if h.hasPrefix("#") { h = String(h.dropFirst()) }
        guard h.count == 6, let value = UInt64(h, radix: 16) else { return nil }
        let r = Double((value >> 16) & 0xFF) / 255
        let g = Double((value >>  8) & 0xFF) / 255
        let b = Double( value        & 0xFF) / 255
        self.init(red: r, green: g, blue: b)
    }
}
