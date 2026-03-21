import SwiftUI
import UniformTypeIdentifiers

// MARK: - Workspace drag UTType

extension UTType {
    /// Custom type for dragging workspace rows within the sidebar.
    static let mosaicWorkspace = UTType(exportedAs: "com.manaflow.mosaic.workspace")
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

    var body: some View {
        ZStack(alignment: .bottom) {
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(spacing: 2) {
                    ForEach(viewModel.items) { item in
                        if renamingID == item.id {
                            renameField(for: item)
                        } else {
                            SidebarItemView(
                                title: item.title,
                                isSelected: viewModel.selection == .workspace(item.id),
                                isPinned: item.isPinned,
                                panelCount: item.panelCount,
                                gitBranch: item.gitBranch,
                                workingDirectory: item.workingDirectory,
                                listeningPorts: item.listeningPorts,
                                shellState: item.shellState,
                                onSelect: {
                                    viewModel.selectWorkspace(id: item.id)
                                },
                                onRename: { beginRename(item: item) },
                                onTogglePin: { viewModel.togglePin(id: item.id) },
                                onClose: { viewModel.closeWorkspace(id: item.id) }
                            )
                            // Note: .equatable() removed — live isSelected from viewModel.selection
                            // ensures sidebar always reflects current selection state.
                            .padding(.horizontal, 8)
                            .opacity(draggingID == item.id ? 0.4 : 1.0)
                            .overlay(
                                dropTargetID == item.id
                                    ? RoundedRectangle(cornerRadius: 6)
                                        .strokeBorder(Color.accentColor, lineWidth: 2)
                                        .padding(.horizontal, 8)
                                    : nil
                            )
                            // Drag source: encode workspace ID as UTF-8 data
                            .onDrag {
                                draggingID = item.id
                                let provider = NSItemProvider()
                                let idString = item.id.uuidString
                                provider.registerDataRepresentation(
                                    forTypeIdentifier: UTType.mosaicWorkspace.identifier,
                                    visibility: .all
                                ) { completion in
                                    completion(idString.data(using: .utf8), nil)
                                    return nil
                                }
                                return provider
                            }
                            // Drop target: reorder when a workspace is dropped here
                            .onDrop(
                                of: [.mosaicWorkspace],
                                delegate: WorkspaceDropDelegate(
                                    targetID: item.id,
                                    items: viewModel.items,
                                    draggingID: $draggingID,
                                    dropTargetID: $dropTargetID,
                                    onMove: { source, dest in
                                        viewModel.moveWorkspace(from: source, to: dest)
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
                                .foregroundStyle(.white)
                            Text("Settings")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(.white)
                            Spacer()
                            // Close button to dismiss settings
                            Button(action: {
                                // Go back to the last workspace
                                viewModel.selectWorkspace(id: viewModel.lastWorkspaceID)
                            }) {
                                Image(systemName: "xmark")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundStyle(.white.opacity(0.6))
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(Color.accentColor)
                        )
                        .padding(.horizontal, 8)
                    }

                    Spacer().frame(height: 48)
                }
                .padding(.top, 8)
            }

            // "+" button pinned at the bottom
            addButton
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
        }
        .background(SidebarBackgroundView())
        .accessibilityIdentifier("Sidebar")
    }

    // MARK: - Subviews

    private var addButton: some View {
        Button(action: { viewModel.createWorkspace() }) {
            Label("New Workspace", systemImage: "plus")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 6)
                .padding(.horizontal, 10)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.primary.opacity(0.05))
                )
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func renameField(for item: SidebarItemData) -> some View {
        TextField("Workspace name", text: $renameText)
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

// MARK: - Sidebar background (NSVisualEffectView sidebar material)

private struct SidebarBackgroundView: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

// MARK: - WorkspaceDropDelegate

/// Handles drop targeting and reordering of workspace rows.
private struct WorkspaceDropDelegate: DropDelegate {
    let targetID: UUID
    let items: [SidebarItemData]
    @Binding var draggingID: UUID?
    @Binding var dropTargetID: UUID?
    let onMove: (IndexSet, Int) -> Void

    func dropEntered(info: DropInfo) {
        dropTargetID = targetID
    }

    func dropExited(info: DropInfo) {
        if dropTargetID == targetID { dropTargetID = nil }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        defer {
            draggingID = nil
            dropTargetID = nil
        }

        guard let provider = info.itemProviders(for: [.mosaicWorkspace]).first else { return false }

        provider.loadDataRepresentation(forTypeIdentifier: UTType.mosaicWorkspace.identifier) { data, _ in
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
        guard let dragging = draggingID else { return false }
        return dragging != targetID
    }
}
