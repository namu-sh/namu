import Foundation
import Combine
import CoreGraphics
import os.log

private let logger = Logger(subsystem: "com.namu.app", category: "SessionPersistence")

// MARK: - Policy constants

private enum Policy {
    static let autosaveInterval: TimeInterval = 8.0
    static let maxBackupCount: Int = 3
    static let sessionFileName = "session.json"
    static let appSupportSubdirectory = "Namu"
    static let scrollbackSubdirectory = "scrollback"
    static let maxScrollbackChars: Int = 400_000
    static let maxScrollbackLines: Int = 4_000
    static let maxWindows: Int = 12
    static let maxWorkspaces: Int = 128
    static let maxPanels: Int = 512
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
    /// Fingerprint of the last successfully written snapshot data.
    /// Used to skip redundant writes when nothing has changed.
    private var lastSaveFingerprint: Int = 0

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

    // MARK: - Primary window frame (set by AppDelegate before save, read after restore)

    /// Window frame for the primary window. Set by AppDelegate just before save so that
    /// SessionPersistence does not need an AppKit import.
    var primaryWindowFrame: CGRect?
    var primarySidebarCollapsed: Bool = false
    var primarySidebarWidth: Double = 220

    /// Restored window frame for the primary window. Read by AppDelegate after `restoreIfAvailable`.
    private(set) var restoredWindowFrame: CGRect?
    private(set) var restoredSidebarCollapsed: Bool = false
    private(set) var restoredSidebarWidth: Double = 220

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

    /// Synchronous save for use during app termination (applicationWillTerminate
    /// returns immediately — async Tasks won't complete before the process exits).
    func saveSync() {
        let snapshot = buildSnapshot()
        // Debug: log workspace colors in snapshot
        for win in snapshot.windows {
            for ws in win.workspaces {
                print("[SessionPersistence.saveSync] workspace=\(ws.title) customColor=\(ws.customColor ?? "nil")")
            }
        }
        do {
            try writeSnapshot(snapshot)
            let activePanelIDs = Set(snapshot.windows.flatMap { win in
                win.workspaces.flatMap { ws in collectPanelIDs(from: ws.layout) }
            })
            cleanStaleScrollbackFiles(keepingPanelIDs: activePanelIDs)
            let windowCount = snapshot.windows.count
            let workspaceCount = snapshot.windows.reduce(0) { $0 + $1.workspaces.count }
            print("[SessionPersistence.saveSync] SAVED \(windowCount) window(s), \(workspaceCount) workspace(s)")
        } catch {
            print("[SessionPersistence.saveSync] FAILED: \(error.localizedDescription)")
        }
    }

    /// Snapshot and persist the current session atomically.
    /// Skips the write if the snapshot fingerprint matches the last save.
    func save() async {
        let snapshot = buildSnapshot()
        do {
            let data = try encoder.encode(snapshot)
            let fingerprint = data.hashValue
            guard fingerprint != lastSaveFingerprint else { return }

            saveStatus = .saving
            try writeSnapshotData(data)
            lastSaveFingerprint = fingerprint

            // Remove scrollback files for panels no longer in the snapshot.
            let activePanelIDs = Set(snapshot.windows.flatMap { win in
                win.workspaces.flatMap { ws in
                    collectPanelIDs(from: ws.layout)
                }
            })
            cleanStaleScrollbackFiles(keepingPanelIDs: activePanelIDs)
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

    /// Recursively collect all panel IDs from a layout snapshot.
    private func collectPanelIDs(from layout: WorkspaceLayoutSnapshot) -> [UUID] {
        switch layout {
        case .pane(let pane): return [pane.id]
        case .split(let split):
            return collectPanelIDs(from: split.first) + collectPanelIDs(from: split.second)
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
            panelManager: panelManager,
            windowFrame: primaryWindowFrame,
            sidebarCollapsed: primarySidebarCollapsed,
            sidebarWidth: primarySidebarWidth
        )
        windows.append(primaryWindowSnap)

        for ctx in additionalWindowContexts {
            let winSnap = buildWindowSnapshot(
                windowID: ctx.windowID,
                workspaceManager: ctx.workspaceManager,
                panelManager: ctx.panelManager,
                windowFrame: ctx.windowFrame,
                sidebarCollapsed: ctx.sidebarCollapsed,
                sidebarWidth: ctx.sidebarWidth
            )
            windows.append(winSnap)
        }

        if windows.count > Policy.maxWindows {
            logger.warning("Session snapshot truncated: \(windows.count) windows exceeds maxWindows (\(Policy.maxWindows))")
            windows = Array(windows.prefix(Policy.maxWindows))
        }

        return SessionSnapshot(windows: windows)
    }

    private func buildWindowSnapshot(
        windowID: UUID,
        workspaceManager: WorkspaceManager,
        panelManager: PanelManager,
        windowFrame: CGRect? = nil,
        sidebarCollapsed: Bool = false,
        sidebarWidth: Double = 220
    ) -> WindowSnapshot {
        let allWorkspaces = workspaceManager.workspaces
        let cappedWorkspaces: [Workspace]
        if allWorkspaces.count > Policy.maxWorkspaces {
            logger.warning("Session snapshot truncated: \(allWorkspaces.count) workspaces exceeds maxWorkspaces (\(Policy.maxWorkspaces))")
            cappedWorkspaces = Array(allWorkspaces.prefix(Policy.maxWorkspaces))
        } else {
            cappedWorkspaces = allWorkspaces
        }

        let workspaceSnapshots = cappedWorkspaces.map { workspace in
            // Derive workspace-level directory and git from focused panel
            let focusedID = panelManager.focusedPanelID(in: workspace.id)
            let focusedPanel = focusedID.flatMap { panelManager.panel(for: $0) }
            let gitSnap: GitBranchSnapshot? = focusedPanel?.gitBranch.map {
                GitBranchSnapshot(branch: $0, isDirty: false)
            }
            return WorkspaceSnapshot(
                id: workspace.id,
                title: workspace.title,
                order: workspace.order,
                isPinned: workspace.isPinned,
                customTitle: workspace.customTitle,
                processTitle: workspace.processTitle.isEmpty ? nil : workspace.processTitle,
                customColor: workspace.customColor,
                layout: buildLayoutFromController(workspaceID: workspace.id, panelManager: panelManager),
                activePanelID: focusedID,
                currentDirectory: focusedPanel?.workingDirectory,
                gitBranch: gitSnap
            )
        }
        let frameArray: [Double]? = windowFrame.map { [Double($0.origin.x), Double($0.origin.y), Double($0.size.width), Double($0.size.height)] }
        return WindowSnapshot(
            windowID: windowID,
            workspaces: workspaceSnapshots,
            selectedWorkspaceID: workspaceManager.selectedWorkspaceID,
            windowFrame: frameArray,
            sidebarCollapsed: sidebarCollapsed,
            sidebarWidth: sidebarWidth
        )
    }

    /// Build layout snapshot directly from LayoutTreeController's tree — single source of truth.
    private func buildLayoutFromController(workspaceID: UUID, panelManager: PanelManager) -> WorkspaceLayoutSnapshot {
        let eng = panelManager.engine(for: workspaceID)
        let treeNode = eng.treeSnapshot()
        return externalNodeToLayout(treeNode, engine: eng, panelManager: panelManager)
    }

    private func externalNodeToLayout(_ node: ExternalTreeNode, engine eng: NamuSplitLayoutEngine, panelManager: PanelManager) -> WorkspaceLayoutSnapshot {
        switch node {
        case .pane(let paneNode):
            // Find the first mapped panel in this pane's tabs
            var panelID: UUID?
            for tab in paneNode.tabs {
                if let tabUUID = UUID(uuidString: tab.id),
                   let id = eng.panelID(for: TabID(uuid: tabUUID)) {
                    panelID = id
                    break
                }
            }
            let id = panelID ?? UUID(uuidString: paneNode.id) ?? UUID()
            // Determine panel type: check browser registry first, fall back to terminal.
            if let browserPanel = panelManager.browserPanel(for: id) {
                let pinned: Bool? = panelManager.isPanelPinned(id: id) ? true : nil
                let pane = PaneSnapshot(
                    id: id,
                    panelType: .browser,
                    workingDirectory: nil,
                    scrollbackFile: nil,
                    gitBranch: nil,
                    customTitle: browserPanel.customTitle,
                    browserURL: browserPanel.url?.absoluteString,
                    browserZoom: browserPanel.zoom != 1.0 ? browserPanel.zoom : nil,
                    browserDevToolsVisible: browserPanel.devToolsVisible ? true : nil,
                    browserBackHistory: browserPanel.backHistory.isEmpty ? nil : browserPanel.backHistory,
                    browserForwardHistory: browserPanel.forwardHistory.isEmpty ? nil : browserPanel.forwardHistory,
                    isPinned: pinned
                )
                return .pane(pane)
            }
            let panel = panelManager.panel(for: id)
            let scrollbackPath = panel.flatMap { captureScrollback(panel: $0) }
            let pinned: Bool? = panelManager.isPanelPinned(id: id) ? true : nil
            let pane = PaneSnapshot(
                id: id,
                panelType: .terminal,
                workingDirectory: panel?.workingDirectory,
                scrollbackFile: scrollbackPath,
                gitBranch: panel?.gitBranch,
                customTitle: panel?.customTitle,
                isPinned: pinned
            )
            return .pane(pane)

        case .split(let splitNode):
            let direction: SplitDirection = splitNode.orientation == "vertical" ? .vertical : .horizontal
            let splitID = UUID(uuidString: splitNode.id) ?? UUID()
            return .split(SplitSnapshot(
                id: splitID,
                direction: direction,
                ratio: splitNode.dividerPosition,
                first: externalNodeToLayout(splitNode.first, engine: eng, panelManager: panelManager),
                second: externalNodeToLayout(splitNode.second, engine: eng, panelManager: panelManager)
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

        // Expose restored frame so AppDelegate can reposition the window.
        if let f = primaryWindowSnap.windowFrame, f.count == 4 {
            restoredWindowFrame = CGRect(x: f[0], y: f[1], width: f[2], height: f[3])
        }
        restoredSidebarCollapsed = primaryWindowSnap.sidebarCollapsed ?? false
        restoredSidebarWidth = primaryWindowSnap.sidebarWidth ?? 220
    }

    private func applyWindowSnapshot(
        _ windowSnap: WindowSnapshot,
        workspaceManager: WorkspaceManager,
        panelManager: PanelManager
    ) {
        guard !windowSnap.workspaces.isEmpty else { return }

        var restoredWorkspaces: [Workspace] = []

        let defaultTitle = String(localized: "workspace.default.title", defaultValue: "New Workspace")
        // Collect panel IDs per workspace for bootstrap
        var workspacePanelIDs: [UUID: [UUID]] = [:]
        var workspaceActivePanelIDs: [UUID: UUID?] = [:]

        for workspaceSnap in windowSnap.workspaces.sorted(by: { $0.order < $1.order }) {
            let restoredTitle: String = {
                if let custom = workspaceSnap.customTitle, !custom.isEmpty { return custom }
                if let process = workspaceSnap.processTitle, !process.isEmpty { return process }
                return defaultTitle
            }()
            var workspace = Workspace(
                id: workspaceSnap.id,
                title: restoredTitle,
                order: workspaceSnap.order,
                isPinned: workspaceSnap.isPinned
            )
            workspace.customTitle = workspaceSnap.customTitle
            workspace.processTitle = workspaceSnap.processTitle ?? ""
            workspace.customColor = workspaceSnap.customColor
            print("[SessionPersistence.restore] workspace=\(restoredTitle) customColor=\(workspaceSnap.customColor ?? "nil")")
            restoredWorkspaces.append(workspace)

            // Create panels in PanelManager's registry
            let panelIDs = collectPanelIDs(from: workspaceSnap.layout)
            workspacePanelIDs[workspace.id] = panelIDs
            workspaceActivePanelIDs[workspace.id] = workspaceSnap.activePanelID
            createPanels(from: workspaceSnap.layout, workspaceID: workspace.id, panelManager: panelManager)
        }

        workspaceManager.workspaces = restoredWorkspaces
        if let selectedID = windowSnap.selectedWorkspaceID,
           restoredWorkspaces.contains(where: { $0.id == selectedID }) {
            workspaceManager.selectedWorkspaceID = selectedID
        } else {
            workspaceManager.selectedWorkspaceID = restoredWorkspaces.first?.id
        }

        // Bootstrap NamuSplitLayoutEngines for restored workspaces.
        for workspace in restoredWorkspaces {
            let panelIDs = workspacePanelIDs[workspace.id] ?? []
            let activeID = workspaceActivePanelIDs[workspace.id] ?? nil
            panelManager.bootstrapRestoredWorkspace(workspace, panelIDs: panelIDs, activePanelID: activeID)
        }
    }



    /// Recreate panels for all pane leaves in the layout.
    /// Terminal panels: scrollback file path stored on the panel; shell integration reads
    /// NAMU_RESTORE_SCROLLBACK_FILE on startup to replay the scrollback content.
    /// Browser panels: URL, zoom, devtools, and nav history are applied after creation.
    private func createPanels(from layout: WorkspaceLayoutSnapshot, workspaceID: UUID, panelManager: PanelManager) {
        switch layout {
        case .pane(let snap):
            if snap.panelType == .browser {
                let url = snap.browserURL.flatMap { URL(string: $0) }
                let panel = panelManager.restoreBrowserPanel(id: snap.id, url: url, customTitle: snap.customTitle)
                if let zoom = snap.browserZoom {
                    panel.applyZoom(zoom)
                }
                if snap.browserDevToolsVisible == true {
                    panel.showDevToolsIfNeeded(true)
                }
            } else {
                panelManager.restoreTerminalPanel(
                    id: snap.id,
                    workspaceID: workspaceID,
                    workingDirectory: snap.workingDirectory,
                    scrollbackFile: snap.scrollbackFile,
                    gitBranch: snap.gitBranch,
                    customTitle: snap.customTitle
                )
            }
            // Restore pin state: only call togglePanelPin if the snapshot records pinned=true,
            // since the default state on a fresh panel is unpinned.
            if snap.isPinned == true {
                panelManager.togglePanelPin(id: snap.id)
            }
        case .split(let snap):
            createPanels(from: snap.first, workspaceID: workspaceID, panelManager: panelManager)
            createPanels(from: snap.second, workspaceID: workspaceID, panelManager: panelManager)
        }
    }

    // MARK: - File I/O

    private func writeSnapshot(_ snapshot: SessionSnapshot) throws {
        let data = try encoder.encode(snapshot)
        try writeSnapshotData(data)
    }

    private func writeSnapshotData(_ data: Data) throws {
        guard let fileURL = sessionFileURL() else {
            throw PersistenceError.noSaveLocation
        }

        let directory = fileURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        // Rotate backups before overwriting the current snapshot.
        if fileManager.fileExists(atPath: fileURL.path) {
            rotateBackups(sessionURL: fileURL)
        }

        // Atomic write: temp file → rename over destination.
        let tempURL = directory.appendingPathComponent("session.tmp.\(UUID().uuidString).json")
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

    // MARK: - Scrollback capture

    /// Capture the scrollback buffer of a panel to disk.
    /// Returns the file path on success, nil on failure or empty content.
    /// Line limit is applied before the character limit to bound restore size.
    private func captureScrollback(panel: TerminalPanel) -> String? {
        guard var text = panel.session.readScrollbackText(charLimit: .max),
              !text.isEmpty else { return nil }

        // Apply line limit first: drop oldest lines from the front if over limit.
        let lineCount = text.components(separatedBy: "\n").count
        if lineCount > Policy.maxScrollbackLines {
            var lines = text.components(separatedBy: "\n")
            let excess = lines.count - Policy.maxScrollbackLines
            lines.removeFirst(excess)
            text = lines.joined(separator: "\n")
        }

        // Apply character limit after line limit.
        if text.utf8.count > Policy.maxScrollbackChars {
            var bytes = Array(text.utf8)
            var cut = Policy.maxScrollbackChars
            // Step back over any UTF-8 continuation bytes to land on a codepoint boundary.
            while cut > 0 && bytes[cut] & 0xC0 == 0x80 { cut -= 1 }
            text = String(bytes: Array(bytes.prefix(cut)), encoding: .utf8) ?? text
        }

        // ANSI CSI safe truncation and replay wrapping.
        let safeStart = Self.ansiSafeTruncationStart(in: text, from: text.startIndex)
        text = Self.ansiSafeReplayText(String(text[safeStart...]))

        guard let scrollbackDir = scrollbackDirectoryURL() else { return nil }

        do {
            try fileManager.createDirectory(at: scrollbackDir, withIntermediateDirectories: true)
        } catch {
            logger.warning("Could not create scrollback directory: \(error.localizedDescription)")
            return nil
        }

        let fileURL = scrollbackDir.appendingPathComponent("\(panel.id.uuidString).txt")
        do {
            try text.write(to: fileURL, atomically: true, encoding: .utf8)
            return fileURL.path
        } catch {
            logger.warning("Failed to write scrollback for panel \(panel.id): \(error.localizedDescription)")
            return nil
        }
    }

    /// Delete stale scrollback files for panels no longer in the snapshot.
    private func cleanStaleScrollbackFiles(keepingPanelIDs activePanelIDs: Set<UUID>) {
        guard let scrollbackDir = scrollbackDirectoryURL(),
              fileManager.fileExists(atPath: scrollbackDir.path) else { return }

        guard let files = try? fileManager.contentsOfDirectory(at: scrollbackDir, includingPropertiesForKeys: nil) else { return }

        for file in files {
            let name = file.deletingPathExtension().lastPathComponent
            if let uuid = UUID(uuidString: name), !activePanelIDs.contains(uuid) {
                try? fileManager.removeItem(at: file)
            }
        }
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

    /// ~/Library/Application Support/Namu/scrollback/
    private func scrollbackDirectoryURL() -> URL? {
        guard let appSupport = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else { return nil }

        return appSupport
            .appendingPathComponent(Policy.appSupportSubdirectory, isDirectory: true)
            .appendingPathComponent(Policy.scrollbackSubdirectory, isDirectory: true)
    }
}

// MARK: - ANSI Helpers

private extension SessionPersistence {

    /// Find a safe truncation start that doesn't split a CSI escape sequence.
    static func ansiSafeTruncationStart(in text: String, from initialStart: String.Index) -> String.Index {
        // Scan backward from initialStart for ESC (0x1B)
        var idx = initialStart
        let searchLimit = 20
        var scanned = 0
        while idx > text.startIndex && scanned < searchLimit {
            idx = text.index(before: idx)
            scanned += 1
            if text[idx] == "\u{1B}" {
                // Found ESC — check if followed by '[' (CSI introducer)
                let next = text.index(after: idx)
                if next < initialStart && text[next] == "[" {
                    // Look for CSI final byte (0x40-0x7E) between next and initialStart
                    var scan = text.index(after: next)
                    while scan < initialStart {
                        let byte = text[scan].asciiValue ?? 0
                        if byte >= 0x40 && byte <= 0x7E {
                            // Complete CSI found — safe to truncate at initialStart
                            return initialStart
                        }
                        scan = text.index(after: scan)
                    }
                    // Incomplete CSI — truncate before the ESC
                    return idx
                }
                break
            }
        }
        return initialStart
    }

    /// Wrap scrollback text with SGR reset for clean replay state.
    static func ansiSafeReplayText(_ text: String) -> String {
        "\u{1B}[0m" + text + "\u{1B}[0m"
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
