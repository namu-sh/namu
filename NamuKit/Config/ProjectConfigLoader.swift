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

    private func startWatching() {
        if let path = projectPath {
            projectWatcher = watchFile(at: path)
        }
        globalWatcher = watchFile(at: Self.globalConfigPath)
    }

    private func watchFile(at path: String) -> DispatchSourceFileSystemObject? {
        // Watch the parent directory so we detect file creation too.
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
            self?.reload()
        }
        source.setCancelHandler {
            close(fd)
        }
        source.resume()
        return source
    }
}
