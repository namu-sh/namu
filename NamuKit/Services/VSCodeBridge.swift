import Foundation

// MARK: - VSCodeBridge

/// Provides socket-based communication between Namu and a VS Code extension.
///
/// The VS Code extension connects to the Namu IPC socket and uses standard
/// JSON-RPC commands. This bridge supplements that with VS Code-specific
/// helpers: detecting running VS Code instances, resolving the workspace path
/// for the frontmost editor, and sending file-open requests.
///
/// Usage:
///   let bridge = VSCodeBridge()
///   bridge.openFile(path: "/path/to/file.swift", line: 42)
final class VSCodeBridge {

    // MARK: - Constants

    /// Environment variable name that VS Code injects into child shells.
    static let vscodeEnvKey = "VSCODE_IPC_HOOK_CLI"

    // MARK: - Detection

    /// Returns true if VS Code is currently running (has an IPC hook available).
    func isVSCodeRunning() -> Bool {
        ipcHookPath() != nil
    }

    /// The path to the VS Code CLI IPC socket, if available.
    func ipcHookPath() -> String? {
        // VS Code sets VSCODE_IPC_HOOK_CLI in shells it spawns.
        if let path = ProcessInfo.processInfo.environment[Self.vscodeEnvKey],
           FileManager.default.fileExists(atPath: path) {
            return path
        }
        // Fall back to scanning /tmp for vscode-ipc-*.sock
        return Self.findVSCodeSocket()
    }

    // MARK: - File Operations

    /// Ask VS Code to open a file, optionally at a specific line and column.
    /// - Parameters:
    ///   - path: Absolute path to the file.
    ///   - line: 1-based line number (optional).
    ///   - column: 1-based column number (optional).
    func openFile(path: String, line: Int? = nil, column: Int? = nil) {
        var target = path
        if let line {
            target += ":\(line)"
            if let column { target += ":\(column)" }
        }
        launchCode(args: [target])
    }

    /// Reveal a file in VS Code's Explorer sidebar without opening it in an editor.
    func revealInExplorer(path: String) {
        launchCode(args: ["--reveal", path])
    }

    /// Open a folder as a VS Code workspace.
    func openFolder(path: String) {
        launchCode(args: [path])
    }

    // MARK: - Running VS Code workspace detection

    /// Returns the workspace root path of the frontmost VS Code window,
    /// by scanning the argv of running Code processes.
    func frontmostWorkspacePath() -> String? {
        guard let output = shell("/bin/ps", args: ["-A", "-o", "comm=,args="]) else { return nil }
        for line in output.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            let parts = trimmed.components(separatedBy: .whitespaces)
            guard let comm = parts.first,
                  comm.hasSuffix("/Electron") || comm.hasSuffix("/Code") || comm.contains("Visual Studio Code") else { continue }
            // Look for a directory argument that exists on disk
            for arg in parts.dropFirst() where !arg.hasPrefix("-") {
                var isDir: ObjCBool = false
                if FileManager.default.fileExists(atPath: arg, isDirectory: &isDir), isDir.boolValue {
                    return arg
                }
            }
        }
        return nil
    }

    // MARK: - Private helpers

    private func launchCode(args: [String]) {
        // Try `code` CLI first (requires VS Code shell command to be installed).
        let codePaths = [
            "/usr/local/bin/code",
            "/opt/homebrew/bin/code",
            "\(NSHomeDirectory())/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code",
            "/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code"
        ]
        for codePath in codePaths where FileManager.default.fileExists(atPath: codePath) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: codePath)
            process.arguments = args
            try? process.run()
            return
        }
        // Fall back to `open -a "Visual Studio Code"`
        var openArgs = ["-a", "Visual Studio Code"]
        openArgs.append(contentsOf: args)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = openArgs
        try? process.run()
    }

    private static func findVSCodeSocket() -> String? {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: tmp, includingPropertiesForKeys: nil
        ) else { return nil }
        let sock = contents.first {
            $0.lastPathComponent.hasPrefix("vscode-ipc-") && $0.pathExtension == "sock"
        }
        return sock?.path
    }

    private func shell(_ executable: String, args: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
        } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)
    }
}
