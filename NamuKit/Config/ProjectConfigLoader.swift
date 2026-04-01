import Combine
import Foundation

/// Loads and watches namu.json config files from project-local and global paths.
/// Publishes merged command definitions whenever either file changes.
@MainActor
final class ProjectConfigLoader: ObservableObject {

    @Published private(set) var commands: [CommandDefinition] = []
    @Published private(set) var lastError: String?

    /// The project-local config path (e.g., ./namu.json).
    let projectPath: String?

    /// The global config path (~/.config/namu/namu.json).
    static let globalConfigPath: String = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/.config/namu/namu.json"
    }()

    private var projectWatcher: DispatchSourceFileSystemObject?
    private var globalWatcher: DispatchSourceFileSystemObject?

    init(projectDirectory: String? = nil) {
        self.projectPath = projectDirectory.map { "\($0)/namu.json" }
        reload()
        startWatching()
    }

    deinit {
        projectWatcher?.cancel()
        globalWatcher?.cancel()
    }

    // MARK: - Loading

    func reload() {
        var allCommands: [CommandDefinition] = []
        lastError = nil

        // Global config (lower priority).
        if let globalCmds = loadFile(at: Self.globalConfigPath) {
            allCommands.append(contentsOf: globalCmds)
        }

        // Project-local config (higher priority — appended after global, deduplicated by name).
        if let path = projectPath, let localCmds = loadFile(at: path) {
            let globalNames = Set(allCommands.map(\.name))
            for cmd in localCmds {
                if globalNames.contains(cmd.name) {
                    allCommands.removeAll { $0.name == cmd.name }
                }
                allCommands.append(cmd)
            }
        }

        commands = allCommands
    }

    private func loadFile(at path: String) -> [CommandDefinition]? {
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: path))
            let config = try JSONDecoder().decode(NamuConfigFile.self, from: data)
            return config.commands
        } catch {
            lastError = "Failed to load \(path): \(error.localizedDescription)"
            return nil
        }
    }

    // MARK: - File Watching

    /// Debounce work item — cancels previous pending reload when events fire rapidly.
    private var debounceWork: DispatchWorkItem?

    /// Maximum reattach attempts after delete/rename before giving up.
    private static let maxReattachAttempts = 5

    private func startWatching() {
        if let path = projectPath {
            projectWatcher = watchDirectory(for: path, storeIn: \.projectWatcher)
        }
        globalWatcher = watchDirectory(for: Self.globalConfigPath, storeIn: \.globalWatcher)
    }

    /// Debounced reload — coalesces rapid file system events (e.g. atomic saves).
    private func scheduleReload() {
        debounceWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.reload()
        }
        debounceWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    /// Watch the parent directory of `path` for changes. Handles delete/rename with reattach.
    @discardableResult
    private func watchDirectory(
        for path: String,
        storeIn keyPath: ReferenceWritableKeyPath<ProjectConfigLoader, DispatchSourceFileSystemObject?>
    ) -> DispatchSourceFileSystemObject? {
        let dir = (path as NSString).deletingLastPathComponent
        guard FileManager.default.fileExists(atPath: dir) else { return nil }

        let fd = open(dir, O_EVTONLY)
        guard fd >= 0 else { return nil }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .rename, .delete],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            guard let self else { return }
            let flags = source.data
            if flags.contains(.delete) || flags.contains(.rename) {
                // Directory was moved/deleted — tear down and try to reattach.
                self[keyPath: keyPath]?.cancel()
                self[keyPath: keyPath] = nil
                self.scheduleReload()
                self.scheduleReattach(for: path, storeIn: keyPath, attempt: 1)
            } else {
                self.scheduleReload()
            }
        }
        source.setCancelHandler {
            close(fd)
        }
        source.resume()
        return source
    }

    /// Retry reattaching the file watcher after a delete/rename event.
    private func scheduleReattach(
        for path: String,
        storeIn keyPath: ReferenceWritableKeyPath<ProjectConfigLoader, DispatchSourceFileSystemObject?>,
        attempt: Int
    ) {
        guard attempt <= Self.maxReattachAttempts else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self else { return }
            // If already reattached (e.g. by another event), skip.
            if self[keyPath: keyPath] != nil { return }
            let dir = (path as NSString).deletingLastPathComponent
            if FileManager.default.fileExists(atPath: dir) {
                self[keyPath: keyPath] = self.watchDirectory(for: path, storeIn: keyPath)
            } else {
                self.scheduleReattach(for: path, storeIn: keyPath, attempt: attempt + 1)
            }
        }
    }
}
