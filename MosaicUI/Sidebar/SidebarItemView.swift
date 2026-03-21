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
        lhs.panelCount == rhs.panelCount &&
        lhs.gitBranch == rhs.gitBranch &&
        lhs.workingDirectory == rhs.workingDirectory &&
        lhs.listeningPorts == rhs.listeningPorts &&
        lhs.shellState == rhs.shellState
    }

    let title: String
    let isSelected: Bool
    let isPinned: Bool
    let panelCount: Int
    let gitBranch: String?
    let workingDirectory: String?
    let listeningPorts: [PortInfo]
    let shellState: ShellState

    // Provide defaults so existing call sites that don't pass metadata still compile.
    init(
        title: String,
        isSelected: Bool,
        isPinned: Bool,
        panelCount: Int,
        gitBranch: String? = nil,
        workingDirectory: String? = nil,
        listeningPorts: [PortInfo] = [],
        shellState: ShellState = .unknown,
        onSelect: @escaping () -> Void = {},
        onRename: @escaping () -> Void = {},
        onTogglePin: @escaping () -> Void = {},
        onClose: @escaping () -> Void = {}
    ) {
        self.title = title
        self.isSelected = isSelected
        self.isPinned = isPinned
        self.panelCount = panelCount
        self.gitBranch = gitBranch
        self.workingDirectory = workingDirectory
        self.listeningPorts = listeningPorts
        self.shellState = shellState
        self.onSelect = onSelect
        self.onRename = onRename
        self.onTogglePin = onTogglePin
        self.onClose = onClose
    }

    // Action closures are excluded from == — they're recreated on every parent
    // eval but don't affect rendering, so comparing them would always be false.
    var onSelect: () -> Void
    var onRename: () -> Void
    var onTogglePin: () -> Void
    var onClose: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 8) {
            // Pin indicator rail
            Rectangle()
                .fill(isPinned ? Color.accentColor : Color.clear)
                .frame(width: 3)
                .cornerRadius(1.5)

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
