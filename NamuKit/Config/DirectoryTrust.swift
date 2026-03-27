import Foundation

/// Manages trusted directories for namu.json command execution.
/// When a directory (or its git repo root) is trusted, commands with
/// `confirm: true` skip the confirmation dialog.
/// The global config (~/.config/namu/namu.json) is always trusted.
final class DirectoryTrust {

    static let shared = DirectoryTrust()

    private let storePath: String
    private var trustedPaths: Set<String>

    private init() {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first!.appendingPathComponent("Namu")
        storePath = appSupport.appendingPathComponent("trusted-directories.json").path

        if !FileManager.default.fileExists(atPath: appSupport.path) {
            try? FileManager.default.createDirectory(
                atPath: appSupport.path,
                withIntermediateDirectories: true
            )
        }

        if let data = FileManager.default.contents(atPath: storePath),
           let paths = try? JSONDecoder().decode([String].self, from: data) {
            trustedPaths = Set(paths)
        } else {
            trustedPaths = []
        }
    }

    /// Check if a config path is trusted.
    func isTrusted(configPath: String) -> Bool {
        if configPath == ProjectConfigLoader.globalConfigPath { return true }
        let key = trustKey(for: configPath)
        return trustedPaths.contains(key)
    }

    /// Trust the directory containing a config file.
    /// Uses git repo root if available, otherwise the config's parent directory.
    func trust(configPath: String) {
        let key = trustKey(for: configPath)
        trustedPaths.insert(key)
        save()
    }

    /// Remove trust for a directory.
    func revoke(configPath: String) {
        let key = trustKey(for: configPath)
        trustedPaths.remove(key)
        save()
    }

    // MARK: - Private

    private func trustKey(for configPath: String) -> String {
        let dir = (configPath as NSString).deletingLastPathComponent
        // Try to find git repo root for broader trust scope.
        if let repoRoot = gitRepoRoot(at: dir) {
            return repoRoot
        }
        return dir
    }

    private func gitRepoRoot(at path: String) -> String? {
        var current = path
        while !current.isEmpty && current != "/" {
            let gitDir = (current as NSString).appendingPathComponent(".git")
            if FileManager.default.fileExists(atPath: gitDir) {
                return current
            }
            current = (current as NSString).deletingLastPathComponent
        }
        return nil
    }

    private func save() {
        let sorted = trustedPaths.sorted()
        guard let data = try? JSONEncoder().encode(sorted) else { return }
        FileManager.default.createFile(atPath: storePath, contents: data)
    }
}
