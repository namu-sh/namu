import Foundation
import Combine
import os.log

private let logger = Logger(subsystem: "com.namu.app", category: "SessionPersistence")

// MARK: - Policy constants

private enum Policy {
    static let autosaveInterval: TimeInterval = 8.0
    static let maxBackupCount: Int = 3
    static let sessionFileName = "session.json"
    static let appSupportSubdirectory = "Namu"
}

// MARK: - SessionPersistence

/// Manages autosave and restore of application session state.
///
/// - Save location: ~/Library/Application Support/Namu/session.json
/// - Autosave: every 8 seconds via a repeating timer
/// - Atomic writes: write to .tmp then rename
/// - Backup rotation: keeps last 3 good copies (session.1.json … session.3.json)
/// - Corrupt snapshot: logged and moved aside; app starts fresh
/// - Scrollback: pane snapshots carry a `scrollbackFile` path written by shell integration;
///   on restore the path is forwarded so the shell can replay it
@MainActor
final class SessionPersistence: ObservableObject {

    // MARK: - Published state

    enum SaveStatus: Equatable {
        case idle
        case saving
        case saved(at: Date)
        case failed(reason: String)
    }

    @Published private(set) var saveStatus: SaveStatus = .idle

    // MARK: - Dependencies

    private let workspaceManager: WorkspaceManager
    private let panelManager: PanelManager

    // MARK: - Private state

    private var autosaveTimer: AnyCancellable?
    private let fileManager = FileManager.default

    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .prettyPrinted]
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    // MARK: - Multi-window support

    /// Additional window contexts to include in the snapshot. Each entry maps windowID → context.
    /// The primary workspaceManager/panelManager always maps to windows[0].
    var additionalWindowContexts: [WindowContext] = []

    // MARK: - Init

    init(workspaceManager: WorkspaceManager, panelManager: PanelManager) {
        self.workspaceManager = workspaceManager
        self.panelManager = panelManager
    }

    // MARK: - Autosave

    /// Start the repeating autosave timer. Call once on launch after session restore.
    func startAutosave() {
        autosaveTimer = Timer.publish(every: Policy.autosaveInterval, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    await self?.save()
                }
            }
    }

    /// Stop the autosave timer (e.g. before a manual save on quit).
    func stopAutosave() {
        autosaveTimer = nil
    }

    // MARK: - Save

    /// Snapshot and persist the current session atomically.
    func save() async {
        saveStatus = .saving
        let snapshot = buildSnapshot()
        do {
            try writeSnapshot(snapshot)
            saveStatus = .saved(at: Date())
            let windowCount = snapshot.windows.count
            let workspaceCount = snapshot.windows.reduce(0) { $0 + $1.workspaces.count }
            logger.info("Session saved: \(windowCount) window(s), \(workspaceCount) workspace(s)")
        } catch {
            let reason = error.localizedDescription
            saveStatus = .failed(reason: reason)
            logger.error("Session save failed: \(reason)")
        }
    }

    // MARK: - Restore

    /// Load and apply a previously saved session snapshot.
    /// Returns true if a session was successfully restored.
    /// On corrupt data: logs the error, moves the file aside, returns false.
    @discardableResult
    func restoreIfAvailable() -> Bool {
        guard let fileURL = sessionFileURL() else { return false }
        guard fileManager.fileExists(atPath: fileURL.path) else { return false }

        do {
            let data = try Data(contentsOf: fileURL)
            let snapshot = try decoder.decode(SessionSnapshot.self, from: data)
            guard let migrated = snapshot.migrated() else {
                logger.warning("Session snapshot v\(snapshot.version) is unrecognized, starting fresh")
                rotateCorruptSnapshot(at: fileURL)
                return false
            }
            applySnapshot(migrated)
            let windowCount = migrated.windows.count
            let workspaceCount = migrated.windows.reduce(0) { $0 + $1.workspaces.count }
            logger.info("Session restored: \(windowCount) window(s), \(workspaceCount) workspace(s)")
            return true
        } catch {
            logger.error("Session restore failed (corrupt): \(error.localizedDescription)")
            rotateCorruptSnapshot(at: fileURL)
            return false
        }
    }

    // MARK: - Snapshot building

    private func buildSnapshot() -> SessionSnapshot {
        // Build window snapshots: primary window first, then additional windows.
        var windows: [WindowSnapshot] = []

        let primaryWindowSnap = buildWindowSnapshot(
            windowID: UUID(),
            workspaceManager: workspaceManager,
            panelManager: panelManager
        )
        windows.append(primaryWindowSnap)

        for ctx in additionalWindowContexts {
            let winSnap = buildWindowSnapshot(
                windowID: ctx.windowID,
                workspaceManager: ctx.workspaceManager,
                panelManager: ctx.panelManager
            )
            windows.append(winSnap)
        }

        return SessionSnapshot(windows: windows)
    }

    private func buildWindowSnapshot(
        windowID: UUID,
        workspaceManager: WorkspaceManager,
        panelManager: PanelManager
    ) -> WindowSnapshot {
        let workspaceSnapshots = workspaceManager.workspaces.map { workspace in
            WorkspaceSnapshot(
                id: workspace.id,
                title: workspace.title,
                order: workspace.order,
                isPinned: workspace.isPinned,
                customTitle: workspace.customTitle,
                processTitle: workspace.processTitle.isEmpty ? nil : workspace.processTitle,
                layout: buildLayoutSnapshot(from: workspace.paneTree, panelManager: panelManager),
                activePanelID: workspace.activePanelID
            )
        }
        return WindowSnapshot(
            windowID: windowID,
            workspaces: workspaceSnapshots,
            selectedWorkspaceID: workspaceManager.selectedWorkspaceID
        )
    }

    private func buildLayoutSnapshot(from tree: PaneTree, panelManager: PanelManager) -> WorkspaceLayoutSnapshot {
        switch tree {
        case .pane(let leaf):
            let panel = panelManager.panel(for: leaf.id)
            let pane = PaneSnapshot(
                id: leaf.id,
                panelType: leaf.panelType,
                workingDirectory: panel?.workingDirectory,
                scrollbackFile: nil  // Scrollback written by shell integration, not readable here
            )
            return .pane(pane)

        case .split(let split):
            return .split(SplitSnapshot(
                id: split.id,
                direction: split.direction,
                ratio: split.ratio,
                first: buildLayoutSnapshot(from: split.first, panelManager: panelManager),
                second: buildLayoutSnapshot(from: split.second, panelManager: panelManager)
            ))
        }
    }

    // MARK: - Snapshot application

    private func applySnapshot(_ snapshot: SessionSnapshot) {
        guard !snapshot.windows.isEmpty else { return }
        // Restore primary window from windows[0]. Additional windows are stored in
        // additionalWindowContexts by the time save() is called, but on restore we only
        // bring back the primary window; additional windows are recreated lazily by AppDelegate.
        let primaryWindowSnap = snapshot.windows[0]
        applyWindowSnapshot(primaryWindowSnap, workspaceManager: workspaceManager, panelManager: panelManager)
    }

    private func applyWindowSnapshot(
        _ windowSnap: WindowSnapshot,
        workspaceManager: WorkspaceManager,
        panelManager: PanelManager
    ) {
        guard !windowSnap.workspaces.isEmpty else { return }

        var restoredWorkspaces: [Workspace] = []

        let defaultTitle = String(localized: "workspace.default.title", defaultValue: "New Workspace")
        for workspaceSnap in windowSnap.workspaces.sorted(by: { $0.order < $1.order }) {
            let paneTree = buildPaneTree(from: workspaceSnap.layout)
            // Title priority: customTitle > processTitle (cleaned) > default
            let restoredTitle: String = {
                if let custom = workspaceSnap.customTitle, !custom.isEmpty { return custom }
                if let process = workspaceSnap.processTitle, !process.isEmpty { return process }
                return defaultTitle
            }()
            var workspace = Workspace(
                id: workspaceSnap.id,
                title: restoredTitle,
                order: workspaceSnap.order,
                isPinned: workspaceSnap.isPinned,
                paneTree: paneTree,
                activePanelID: workspaceSnap.activePanelID
            )
            workspace.customTitle = workspaceSnap.customTitle
            workspace.processTitle = workspaceSnap.processTitle ?? ""
            restoredWorkspaces.append(workspace)
            createPanels(from: workspaceSnap.layout, panelManager: panelManager)
        }

        workspaceManager.workspaces = restoredWorkspaces
        if let selectedID = windowSnap.selectedWorkspaceID,
           restoredWorkspaces.contains(where: { $0.id == selectedID }) {
            workspaceManager.selectedWorkspaceID = selectedID
        } else {
            workspaceManager.selectedWorkspaceID = restoredWorkspaces.first?.id
        }
    }

    private func buildPaneTree(from layout: WorkspaceLayoutSnapshot) -> PaneTree {
        switch layout {
        case .pane(let snap):
            return .pane(PaneLeaf(id: snap.id, panelType: snap.panelType))
        case .split(let snap):
            return .split(PaneSplit(
                id: snap.id,
                direction: snap.direction,
                ratio: snap.ratio,
                first: buildPaneTree(from: snap.first),
                second: buildPaneTree(from: snap.second)
            ))
        }
    }

    /// Recreate TerminalPanels for all pane leaves in the layout.
    /// The scrollback file path is stored on the panel; shell integration reads
    /// NAMU_RESTORE_SCROLLBACK_FILE on startup to replay the scrollback content.
    private func createPanels(from layout: WorkspaceLayoutSnapshot, panelManager: PanelManager) {
        switch layout {
        case .pane(let snap):
            panelManager.restoreTerminalPanel(
                id: snap.id,
                workingDirectory: snap.workingDirectory,
                scrollbackFile: snap.scrollbackFile
            )
        case .split(let snap):
            createPanels(from: snap.first, panelManager: panelManager)
            createPanels(from: snap.second, panelManager: panelManager)
        }
    }

    // MARK: - File I/O

    private func writeSnapshot(_ snapshot: SessionSnapshot) throws {
        guard let fileURL = sessionFileURL() else {
            throw PersistenceError.noSaveLocation
        }

        let directory = fileURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        // Rotate backups before overwriting the current snapshot.
        if fileManager.fileExists(atPath: fileURL.path) {
            rotateBackups(sessionURL: fileURL)
        }

        // Atomic write: encode → temp file → rename over destination.
        let tempURL = directory.appendingPathComponent("session.tmp.\(UUID().uuidString).json")
        let data = try encoder.encode(snapshot)
        try data.write(to: tempURL, options: .atomic)
        _ = try fileManager.replaceItemAt(fileURL, withItemAt: tempURL)
    }

    /// Shift backups: session.2.json→session.3.json, session.1.json→session.2.json,
    /// session.json→session.1.json. The oldest backup (3) is dropped first.
    private func rotateBackups(sessionURL: URL) {
        let directory = sessionURL.deletingLastPathComponent()
        let base = sessionURL.deletingPathExtension().lastPathComponent

        // Drop oldest.
        let oldestURL = directory.appendingPathComponent("\(base).\(Policy.maxBackupCount).json")
        try? fileManager.removeItem(at: oldestURL)

        // Shift N → N+1 (descending to avoid collisions).
        for n in stride(from: Policy.maxBackupCount - 1, through: 1, by: -1) {
            let src = directory.appendingPathComponent("\(base).\(n).json")
            let dst = directory.appendingPathComponent("\(base).\(n + 1).json")
            guard fileManager.fileExists(atPath: src.path) else { continue }
            try? fileManager.moveItem(at: src, to: dst)
        }

        // Current → backup 1.
        let backup1 = directory.appendingPathComponent("\(base).1.json")
        try? fileManager.moveItem(at: sessionURL, to: backup1)
    }

    /// Move a corrupt snapshot aside so it isn't retried but is preserved for debugging.
    private func rotateCorruptSnapshot(at fileURL: URL) {
        let directory = fileURL.deletingLastPathComponent()
        let stamp = Int(Date().timeIntervalSince1970)
        let corruptURL = directory.appendingPathComponent("session.corrupt.\(stamp).json")
        try? fileManager.moveItem(at: fileURL, to: corruptURL)
    }

    // MARK: - Path helpers

    /// ~/Library/Application Support/Namu/session.json
    func sessionFileURL() -> URL? {
        guard let appSupport = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else { return nil }

        let namuDir = appSupport.appendingPathComponent(Policy.appSupportSubdirectory, isDirectory: true)
        let namuURL = namuDir.appendingPathComponent(Policy.sessionFileName)

        return namuURL
    }
}

// MARK: - Errors

private enum PersistenceError: LocalizedError {
    case noSaveLocation

    var errorDescription: String? {
        switch self {
        case .noSaveLocation:
            return "Could not resolve ~/Library/Application Support for session save."
        }
    }
}
