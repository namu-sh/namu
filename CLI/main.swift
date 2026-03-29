import Foundation
import Darwin

// MARK: - Errors

struct CLIError: Error, CustomStringConvertible {
    let message: String
    var description: String { message }
}

// MARK: - Socket Client

final class SocketClient {
    private let path: String
    private var socketFD: Int32 = -1

    init(path: String) {
        self.path = path
    }

    func connect() throws {
        guard socketFD < 0 else { return }

        var st = stat()
        guard stat(path, &st) == 0 else {
            throw CLIError(message: "Namu is not running")
        }
        guard (st.st_mode & mode_t(S_IFMT)) == mode_t(S_IFSOCK) else {
            throw CLIError(message: "Path \(path) is not a Unix socket")
        }

        socketFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard socketFD >= 0 else {
            throw CLIError(message: "Failed to create socket")
        }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let maxLength = MemoryLayout.size(ofValue: addr.sun_path)
        path.withCString { ptr in
            withUnsafeMutablePointer(to: &addr.sun_path) { pathPtr in
                let buf = UnsafeMutableRawPointer(pathPtr).assumingMemoryBound(to: CChar.self)
                strncpy(buf, ptr, maxLength - 1)
            }
        }

        let result = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                Darwin.connect(socketFD, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }

        if result != 0 {
            let connectErrno = errno
            Darwin.close(socketFD)
            socketFD = -1
            if connectErrno == ENOENT || connectErrno == ECONNREFUSED {
                throw CLIError(message: "Namu is not running")
            }
            throw CLIError(message: "Failed to connect to socket at \(path): \(String(cString: strerror(connectErrno)))")
        }
    }

    func close() {
        if socketFD >= 0 {
            Darwin.close(socketFD)
            socketFD = -1
        }
    }

    func configureTimeout(_ timeout: TimeInterval) throws {
        var tv = timeval(
            tv_sec: Int(timeout.rounded(.down)),
            tv_usec: __darwin_suseconds_t((timeout - floor(timeout)) * 1_000_000)
        )
        let result = withUnsafePointer(to: &tv) { ptr in
            setsockopt(socketFD, SOL_SOCKET, SO_RCVTIMEO, ptr, socklen_t(MemoryLayout<timeval>.size))
        }
        guard result == 0 else {
            throw CLIError(message: "Failed to set socket timeout")
        }
    }

    func sendRequest(method: String, params: [String: Any], timeout: TimeInterval) throws -> [String: Any] {
        guard socketFD >= 0 else { throw CLIError(message: "Not connected") }

        let requestId = UUID().uuidString
        let request: [String: Any] = [
            "jsonrpc": "2.0",
            "id": requestId,
            "method": method,
            "params": params
        ]

        guard JSONSerialization.isValidJSONObject(request) else {
            throw CLIError(message: "Failed to encode request")
        }
        let requestData = try JSONSerialization.data(withJSONObject: request)
        guard var requestLine = String(data: requestData, encoding: .utf8) else {
            throw CLIError(message: "Failed to encode request as UTF-8")
        }
        requestLine += "\n"

        try requestLine.withCString { ptr in
            let sent = Darwin.write(socketFD, ptr, strlen(ptr))
            if sent < 0 {
                throw CLIError(message: "Failed to write to socket")
            }
        }

        try configureTimeout(timeout)

        var responseData = Data()
        while true {
            var buffer = [UInt8](repeating: 0, count: 8192)
            let count = Darwin.read(socketFD, &buffer, buffer.count)
            if count < 0 {
                if errno == EINTR { continue }
                if errno == EAGAIN || errno == EWOULDBLOCK {
                    break
                }
                throw CLIError(message: "Failed to read from socket: \(String(cString: strerror(errno)))")
            }
            if count == 0 { break }
            responseData.append(contentsOf: buffer[..<count])
            if responseData.contains(UInt8(ascii: "\n")) { break }
        }

        guard var responseStr = String(data: responseData, encoding: .utf8) else {
            throw CLIError(message: "Invalid UTF-8 response from socket")
        }
        responseStr = responseStr.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !responseStr.isEmpty else {
            throw CLIError(message: "Empty response from socket")
        }

        guard let parsed = try JSONSerialization.jsonObject(with: Data(responseStr.utf8)) as? [String: Any] else {
            throw CLIError(message: "Invalid JSON response: \(responseStr)")
        }

        if let error = parsed["error"] as? [String: Any] {
            let code = error["code"] as? Int ?? -1
            let message = (error["message"] as? String) ?? "Unknown error"
            throw CLIError(message: "RPC error \(code): \(message)")
        }

        return parsed
    }

    /// V2-style send: unwraps result from the response dict.
    func sendV2(method: String, params: [String: Any] = [:]) throws -> [String: Any] {
        let response = try sendRequest(method: method, params: params, timeout: 10)
        if let result = response["result"] as? [String: Any] {
            return result
        }
        return response
    }

    static func waitForFilesystemPath(_ path: String, timeout: TimeInterval) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if FileManager.default.fileExists(atPath: path) { return }
            usleep(100_000) // 100ms
        }
        throw CLIError(message: "Timed out waiting for \(path)")
    }
}

// MARK: - Argument Parsing

struct ParsedArgs {
    let namespace: String
    let command: String
    let params: [String: Any]
    let socketPath: String
    let jsonOutput: Bool
    let timeout: TimeInterval
}

func parseArguments(_ args: [String]) throws -> ParsedArgs {
    let remaining = Array(args.dropFirst()) // drop executable name

    var socketPath = ProcessInfo.processInfo.environment["NAMU_SOCKET"] ?? "/tmp/namu.sock"
    var jsonOutput = false
    var timeout: TimeInterval = 5.0

    // Extract flags before namespace/command
    var i = 0
    var positional: [String] = []
    var paramMap: [String: Any] = [:]

    while i < remaining.count {
        let arg = remaining[i]
        if arg == "--socket" || arg == "-s" {
            i += 1
            guard i < remaining.count else {
                throw CLIError(message: "--socket requires a path argument")
            }
            socketPath = remaining[i]
        } else if arg == "--json" {
            jsonOutput = true
        } else if arg == "--timeout" {
            i += 1
            guard i < remaining.count, let t = TimeInterval(remaining[i]) else {
                throw CLIError(message: "--timeout requires a numeric value in seconds")
            }
            timeout = t
        } else if arg.hasPrefix("--") {
            let key = String(arg.dropFirst(2))
            i += 1
            if i < remaining.count && !remaining[i].hasPrefix("--") {
                let value = remaining[i]
                // Try to parse as number, bool, otherwise string
                if let intVal = Int(value) {
                    paramMap[key] = intVal
                } else if let doubleVal = Double(value) {
                    paramMap[key] = doubleVal
                } else if value.lowercased() == "true" {
                    paramMap[key] = true
                } else if value.lowercased() == "false" {
                    paramMap[key] = false
                } else {
                    paramMap[key] = value
                }
            } else {
                // Flag without value — treat as boolean true
                paramMap[key] = true
                i -= 1 // don't skip next token
            }
        } else {
            positional.append(arg)
        }
        i += 1
    }

    guard positional.count >= 2 else {
        throw CLIError(message: usageString())
    }

    let namespace = positional[0]
    let command = positional[1]

    // Remaining positional args after namespace+command become an "args" array param
    if positional.count > 2 {
        paramMap["args"] = Array(positional.dropFirst(2))
    }

    // Validate namespace
    let validNamespaces = ["workspace", "pane", "surface", "notification", "browser", "system", "ai", "window", "debug"]
    guard validNamespaces.contains(namespace) else {
        throw CLIError(message: "Unknown namespace '\(namespace)'. Valid namespaces: \(validNamespaces.joined(separator: ", "))")
    }

    // Map window.* → workspace.* for user convenience
    if namespace == "window" {
        let windowCommandMap: [String: (String, String)] = [
            "new":   ("workspace", "create"),
            "list":  ("workspace", "list"),
            "focus": ("workspace", "select"),
            "close": ("workspace", "delete")
        ]
        if let (mappedNS, mappedCmd) = windowCommandMap[command] {
            return ParsedArgs(
                namespace: mappedNS,
                command: mappedCmd,
                params: paramMap,
                socketPath: socketPath,
                jsonOutput: jsonOutput,
                timeout: timeout
            )
        }
        throw CLIError(message: "Unknown window command '\(command)'. Valid commands: new, list, focus, close")
    }

    // Map debug.* → system.* + internal debug commands
    if namespace == "debug" {
        if command == "stats" {
            return ParsedArgs(
                namespace: "system",
                command: "status",
                params: paramMap,
                socketPath: socketPath,
                jsonOutput: jsonOutput,
                timeout: timeout
            )
        }
        if command == "capabilities" || command == "caps" {
            return ParsedArgs(
                namespace: "system",
                command: "capabilities",
                params: paramMap,
                socketPath: socketPath,
                jsonOutput: jsonOutput,
                timeout: timeout
            )
        }
        throw CLIError(message: "Unknown debug command '\(command)'. Valid commands: stats, capabilities")
    }

    // browser subcommand aliases
    if namespace == "browser" {
        let browserCommandMap: [String: String] = [
            "eval":       "execute_js",
            "get-text":   "get_text",
            "get-attr":   "get_attribute",
            "back":       "back",
            "forward":    "forward",
            "reload":     "reload",
            "url":        "get_url",
            "title":      "get_title",
            "find":       "find_text",
        ]
        let resolvedCommand = browserCommandMap[command] ?? command

        // eval --code "..." → execute_js with script param
        if command == "eval" {
            if let codeVal = paramMap["code"] {
                paramMap["script"] = codeVal
                paramMap.removeValue(forKey: "code")
            }
        }

        // get-attr --selector "..." --attribute "..." → get_attribute
        // (params already parsed by generic --key value parser, nothing to remap)

        // screenshot: decode base64 and write PNG after receiving response
        if command == "screenshot" {
            return ParsedArgs(
                namespace: namespace,
                command: resolvedCommand,
                params: paramMap,
                socketPath: socketPath,
                jsonOutput: jsonOutput,
                timeout: timeout
            )
        }

        return ParsedArgs(
            namespace: namespace,
            command: resolvedCommand,
            params: paramMap,
            socketPath: socketPath,
            jsonOutput: jsonOutput,
            timeout: timeout
        )
    }

    // Heuristic: long-running commands get a 30s timeout unless user specified
    let longRunningCommands = ["read-screen", "wait", "connect", "execute"]
    if longRunningCommands.contains(command) && timeout == 5.0 {
        timeout = 30.0
    }

    return ParsedArgs(
        namespace: namespace,
        command: command,
        params: paramMap,
        socketPath: socketPath,
        jsonOutput: jsonOutput,
        timeout: timeout
    )
}

func usageString() -> String {
    return """
    Usage: namu <namespace> <command> [--param value ...]

    Namespaces: workspace, pane, surface, notification, browser, system, window, debug, ai

    Workspace commands:
      namu workspace list
      namu workspace create --title "My Workspace"
      namu workspace select --id <uuid>
      namu workspace rename --id <uuid> --title "New Name"
      namu workspace pin --id <uuid>
      namu workspace color --id <uuid> --color "#FF6B6B"
      namu workspace delete --id <uuid>

    Pane commands:
      namu pane split --direction horizontal|vertical
      namu pane send_keys "ls\\n"
      namu pane read_screen
      namu pane close
      namu pane zoom
      namu pane unzoom
      namu pane swap --pane_id <uuid> --target_pane_id <uuid>
      namu pane break
      namu pane join --pane_id <uuid>

    Window commands (aliases for workspace):
      namu window new [--title "Name"]
      namu window list
      namu window focus --id <uuid>
      namu window close --id <uuid>

    Browser commands:
      namu browser open
      namu browser navigate --url "https://example.com"
      namu browser eval --code "document.title"
      namu browser click --selector "#submit"
      namu browser type --selector "#input" --text "hello"
      namu browser hover --selector ".menu-item"
      namu browser get-text --selector "h1"
      namu browser get-attr --selector "a" --attribute "href"
      namu browser screenshot [--path file.png]
      namu browser back
      namu browser forward
      namu browser reload
      namu browser url
      namu browser title
      namu browser find --text "search term"

    Debug commands:
      namu debug stats
      namu debug capabilities

    System commands:
      namu system ping
      namu system version
      namu system status
      namu system capabilities

    Notification commands:
      namu notification create --title "Build done" --body "Success"

    Flags:
      --socket <path>    Custom socket path (default: $NAMU_SOCKET or /tmp/namu.sock)
      --json             Output raw JSON response
      --timeout <secs>   Request timeout in seconds (default: 5, 30 for long-running commands)
    """
}

// MARK: - Output Formatting

func prettyPrint(_ object: Any, indent: Int = 0) {
    let spaces = String(repeating: "  ", count: indent)
    if let dict = object as? [String: Any] {
        let sorted = dict.sorted { $0.key < $1.key }
        for (key, value) in sorted {
            if let nested = value as? [String: Any] {
                print("\(spaces)\(key):")
                prettyPrint(nested, indent: indent + 1)
            } else if let array = value as? [Any] {
                print("\(spaces)\(key):")
                prettyPrint(array, indent: indent + 1)
            } else {
                print("\(spaces)\(key): \(value)")
            }
        }
    } else if let array = object as? [Any] {
        for (idx, item) in array.enumerated() {
            if item is [String: Any] || item is [Any] {
                print("\(spaces)[\(idx)]:")
                prettyPrint(item, indent: indent + 1)
            } else {
                print("\(spaces)- \(item)")
            }
        }
    } else {
        print("\(spaces)\(object)")
    }
}

func jsonString(_ object: Any) -> String {
    guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]),
          let str = String(data: data, encoding: .utf8) else {
        return "{}"
    }
    return str
}

// MARK: - Main

func run() throws {
    let parsed = try parseArguments(CommandLine.arguments)

    let method = "\(parsed.namespace).\(parsed.command)"

    let client = SocketClient(path: parsed.socketPath)
    defer { client.close() }

    do {
        try client.connect()
    } catch let error as CLIError {
        // Normalize socket-not-found errors
        if error.message.contains("not running") || error.message.contains("No such file") || error.message.contains("ENOENT") {
            throw CLIError(message: "Namu is not running")
        }
        throw error
    }

    let response = try client.sendRequest(
        method: method,
        params: parsed.params,
        timeout: parsed.timeout
    )

    // Special handling: browser screenshot → decode base64, write PNG
    if parsed.namespace == "browser" && parsed.command == "screenshot" && !parsed.jsonOutput {
        if let result = response["result"] as? [String: Any],
           let base64 = result["data"] as? String,
           let pngData = Data(base64Encoded: base64) {
            let outputPath: String
            if let pathParam = parsed.params["path"] as? String {
                outputPath = pathParam
            } else {
                outputPath = "screenshot.png"
            }
            let url = URL(fileURLWithPath: outputPath)
            do {
                try pngData.write(to: url)
                print(url.path)
            } catch {
                throw CLIError(message: "Failed to write screenshot to \(outputPath): \(error)")
            }
        } else {
            prettyPrint(response["result"] ?? response)
        }
        return
    }

    if parsed.jsonOutput {
        print(jsonString(response))
    } else {
        // If there's a result key, pretty-print it; otherwise print the whole response
        if let result = response["result"] {
            if let dict = result as? [String: Any], dict.isEmpty {
                print("OK")
            } else {
                prettyPrint(result)
            }
        } else {
            // Filter out jsonrpc/id metadata for cleaner output
            var display = response
            display.removeValue(forKey: "jsonrpc")
            display.removeValue(forKey: "id")
            if display.isEmpty {
                print("OK")
            } else {
                prettyPrint(display)
            }
        }
    }
}

// MARK: - Claude Hook

/// Handle Claude Code hook events fired by the claude wrapper.
/// Reads hook context from stdin, sends appropriate socket commands to Namu.
func handleClaudeHook(_ args: [String]) throws {
    guard args.count >= 3 else {
        throw CLIError(message: "Usage: namu claude-hook <session-start|stop|session-end|notification|prompt-submit|pre-tool-use>")
    }
    let event = args[2]

    // Read stdin (Claude Code sends hook context as JSON).
    var stdinData = Data()
    while let byte = try? FileHandle.standardInput.availableData, !byte.isEmpty {
        stdinData.append(byte)
        if stdinData.count > 64 * 1024 { break }
    }
    let context = (try? JSONSerialization.jsonObject(with: stdinData)) as? [String: Any] ?? [:]

    // Resolve socket path from env or default.
    let socketPath = ProcessInfo.processInfo.environment["NAMU_SOCKET"] ?? "/tmp/namu.sock"
    let surfaceID = ProcessInfo.processInfo.environment["NAMU_SURFACE_ID"] ?? ""
    let workspaceID = ProcessInfo.processInfo.environment["NAMU_WORKSPACE_ID"] ?? ""
    let claudePID = ProcessInfo.processInfo.environment["NAMU_CLAUDE_PID"] ?? ""

    let client = SocketClient(path: socketPath)
    defer { client.close() }

    do {
        try client.connect()
    } catch {
        // Namu not running — silently ignore hook
        return
    }

    var params: [String: Any] = [
        "surface_id": surfaceID,
        "workspace_id": workspaceID,
        "claude_pid": claudePID,
        "event": event,
    ]

    switch event {
    case "session-start":
        if let sessionID = context["session_id"] as? String {
            params["session_id"] = sessionID
        }
        params["status"] = "running"
        _ = try? client.sendRequest(method: "system.claude_hook", params: params, timeout: 5)

    case "stop":
        params["status"] = "idle"
        _ = try? client.sendRequest(method: "system.claude_hook", params: params, timeout: 5)

        // Create a completion notification so the pane rings.
        let stopTitle = (context["title"] as? String) ?? "Claude Code"
        let stopBody: String = {
            if let transcript = context["transcript_summary"] as? String, !transcript.isEmpty { return transcript }
            if let result = context["result"] as? String, !result.isEmpty { return result }
            return "Task complete"
        }()
        var notifParams: [String: Any] = [
            "title": stopTitle,
            "body": stopBody,
            "surface_id": surfaceID,
            "workspace_id": workspaceID,
        ]
        _ = try? client.sendRequest(method: "notification.create", params: notifParams, timeout: 5)

    case "session-end":
        params["status"] = "ended"
        _ = try? client.sendRequest(method: "system.claude_hook", params: params, timeout: 1)

    case "notification":
        let notifTitle = (context["title"] as? String) ?? "Claude Code"
        let notifBody = (context["body"] as? String) ?? ""
        var notifParams: [String: Any] = [
            "title": notifTitle,
            "body": notifBody,
            "surface_id": surfaceID,
            "workspace_id": workspaceID,
        ]
        _ = try? client.sendRequest(method: "notification.create", params: notifParams, timeout: 5)

    case "prompt-submit":
        params["status"] = "running"
        _ = try? client.sendRequest(method: "system.claude_hook", params: params, timeout: 5)

    case "pre-tool-use":
        params["status"] = "running"
        _ = try? client.sendRequest(method: "system.claude_hook", params: params, timeout: 3)

    case "permission-request":
        // Claude is asking for permission — ring to get user's attention.
        let permTitle = "Claude Code"
        let permBody = (context["tool_name"] as? String).map { "Needs permission: \($0)" } ?? "Needs your permission"
        _ = try? client.sendRequest(method: "notification.create", params: [
            "title": permTitle,
            "body": permBody,
            "surface_id": surfaceID,
            "workspace_id": workspaceID,
        ], timeout: 5)

    case "subagent-stop":
        // A subagent finished — notify so user knows an agent completed.
        let agentName = (context["agent_name"] as? String) ?? "Agent"
        _ = try? client.sendRequest(method: "notification.create", params: [
            "title": "Claude Code",
            "body": "\(agentName) finished",
            "surface_id": surfaceID,
            "workspace_id": workspaceID,
        ], timeout: 5)

    case "task-completed":
        let taskSubject = (context["subject"] as? String) ?? "Task"
        _ = try? client.sendRequest(method: "notification.create", params: [
            "title": "Claude Code",
            "body": "\(taskSubject) completed",
            "surface_id": surfaceID,
            "workspace_id": workspaceID,
        ], timeout: 5)

    case "teammate-idle":
        let teammateName = (context["teammate_name"] as? String) ?? "Teammate"
        _ = try? client.sendRequest(method: "notification.create", params: [
            "title": "Claude Code",
            "body": "\(teammateName) is idle",
            "surface_id": surfaceID,
            "workspace_id": workspaceID,
        ], timeout: 5)

    default:
        break
    }
}

// MARK: - Claude Teams

// MARK: Tmux compat helpers

private func isUUID(_ value: String) -> Bool {
    UUID(uuidString: value) != nil
}

private func intFromAny(_ value: Any?) -> Int? {
    if let i = value as? Int { return i }
    if let n = value as? NSNumber { return n.intValue }
    if let s = value as? String { return Int(s) }
    return nil
}

private func isHandleRef(_ value: String) -> Bool {
    let pieces = value.split(separator: ":", omittingEmptySubsequences: false)
    guard pieces.count == 2 else { return false }
    let kind = String(pieces[0]).lowercased()
    guard ["workspace", "pane", "surface"].contains(kind) else { return false }
    return Int(String(pieces[1])) != nil
}

private func resolvePath(_ path: String) -> String {
    let expanded = NSString(string: path).expandingTildeInPath
    if expanded.hasPrefix("/") { return expanded }
    let cwd = FileManager.default.currentDirectoryPath
    return (cwd as NSString).appendingPathComponent(expanded)
}

// MARK: Tmux argument parsing

struct TmuxParsedArguments {
    var flags: Set<String> = []
    var options: [String: [String]] = [:]
    var positional: [String] = []

    func hasFlag(_ flag: String) -> Bool {
        flags.contains(flag)
    }

    func value(_ flag: String) -> String? {
        options[flag]?.last
    }
}

func parseTmuxArguments(
    _ args: [String],
    valueFlags: Set<String>,
    boolFlags: Set<String>
) throws -> TmuxParsedArguments {
    var parsed = TmuxParsedArguments()
    var index = 0
    var pastTerminator = false

    while index < args.count {
        let arg = args[index]
        if pastTerminator {
            parsed.positional.append(arg)
            index += 1
            continue
        }
        if arg == "--" {
            pastTerminator = true
            index += 1
            continue
        }
        if !arg.hasPrefix("-") || arg == "-" {
            parsed.positional.append(arg)
            index += 1
            continue
        }
        if arg.hasPrefix("--") {
            parsed.positional.append(arg)
            index += 1
            continue
        }

        let cluster = Array(arg.dropFirst())
        var cursor = 0
        var recognizedArgument = false
        while cursor < cluster.count {
            let flag = "-" + String(cluster[cursor])
            if boolFlags.contains(flag) {
                parsed.flags.insert(flag)
                cursor += 1
                recognizedArgument = true
                continue
            }
            if valueFlags.contains(flag) {
                let remainder = String(cluster.dropFirst(cursor + 1))
                let value: String
                if !remainder.isEmpty {
                    value = remainder
                } else {
                    guard index + 1 < args.count else {
                        throw CLIError(message: "\(flag) requires a value")
                    }
                    index += 1
                    value = args[index]
                }
                parsed.options[flag, default: []].append(value)
                recognizedArgument = true
                cursor = cluster.count
                continue
            }
            recognizedArgument = false
            break
        }

        if !recognizedArgument {
            parsed.positional.append(arg)
        }
        index += 1
    }

    return parsed
}

private func splitTmuxCommand(_ args: [String]) throws -> (command: String, args: [String]) {
    var index = 0
    let globalValueFlags: Set<String> = ["-L", "-S", "-f"]

    while index < args.count {
        let arg = args[index]
        if !arg.hasPrefix("-") || arg == "-" {
            return (arg.lowercased(), Array(args.dropFirst(index + 1)))
        }
        if arg == "--" { break }
        if let flag = globalValueFlags.first(where: { arg == $0 || arg.hasPrefix($0) }) {
            if arg == flag { index += 1 }
        }
        index += 1
    }

    throw CLIError(message: "tmux shim requires a command")
}

// MARK: Tmux target resolution helpers

private func normalizedTmuxTarget(_ raw: String?) -> String? {
    guard let raw else { return nil }
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
}

private func tmuxWindowSelector(from raw: String?) -> String? {
    guard let trimmed = normalizedTmuxTarget(raw) else { return nil }
    if trimmed.hasPrefix("%") || trimmed.hasPrefix("pane:") { return nil }
    if let dot = trimmed.lastIndex(of: ".") {
        return String(trimmed[..<dot])
    }
    return trimmed
}

private func tmuxPaneSelector(from raw: String?) -> String? {
    guard let trimmed = normalizedTmuxTarget(raw) else { return nil }
    if trimmed.hasPrefix("%") { return String(trimmed.dropFirst()) }
    if trimmed.hasPrefix("pane:") { return trimmed }
    if let dot = trimmed.lastIndex(of: ".") {
        return String(trimmed[trimmed.index(after: dot)...])
    }
    return nil
}

func tmuxCallerWorkspaceHandle() -> String? {
    normalizedTmuxTarget(ProcessInfo.processInfo.environment["NAMU_WORKSPACE_ID"])
}

private func tmuxCallerPaneHandle() -> String? {
    guard let pane = normalizedTmuxTarget(ProcessInfo.processInfo.environment["TMUX_PANE"])
        ?? normalizedTmuxTarget(ProcessInfo.processInfo.environment["NAMU_PANE_ID"]) else {
        return nil
    }
    return pane.hasPrefix("%") ? String(pane.dropFirst()) : pane
}

func tmuxCallerSurfaceHandle() -> String? {
    normalizedTmuxTarget(ProcessInfo.processInfo.environment["NAMU_SURFACE_ID"])
}

private func tmuxWorkspaceItems(client: SocketClient) throws -> [[String: Any]] {
    let payload = try client.sendV2(method: "workspace.list")
    return payload["workspaces"] as? [[String: Any]] ?? []
}

private func resolveWorkspaceId(_ raw: String?, client: SocketClient) throws -> String {
    if let raw, isUUID(raw) { return raw }
    // Query focused workspace
    let payload = try client.sendV2(method: "system.identify")
    let focused = payload["focused"] as? [String: Any] ?? [:]
    if let wsId = focused["workspace_id"] as? String { return wsId }
    throw CLIError(message: "No workspace selected")
}

private func resolveSurfaceId(_ raw: String?, workspaceId: String, client: SocketClient) throws -> String {
    if let raw, isUUID(raw) { return raw }
    let payload = try client.sendV2(method: "surface.current", params: ["workspace_id": workspaceId])
    if let sfId = payload["surface_id"] as? String { return sfId }
    throw CLIError(message: "No surface selected in workspace \(workspaceId)")
}

private func tmuxCanonicalPaneId(_ handle: String, workspaceId: String, client: SocketClient) throws -> String {
    if isUUID(handle) { return handle }
    let payload = try client.sendV2(method: "pane.list", params: ["workspace_id": workspaceId])
    let panes = payload["panes"] as? [[String: Any]] ?? []
    for pane in panes {
        if (pane["ref"] as? String) == handle || (pane["id"] as? String) == handle {
            if let id = pane["id"] as? String { return id }
        }
    }
    if let index = Int(handle) {
        for pane in panes where intFromAny(pane["index"]) == index {
            if let id = pane["id"] as? String { return id }
        }
    }
    throw CLIError(message: "Pane target not found")
}

private func tmuxCanonicalSurfaceId(_ handle: String, workspaceId: String, client: SocketClient) throws -> String {
    if isUUID(handle) { return handle }
    let payload = try client.sendV2(method: "surface.list", params: ["workspace_id": workspaceId])
    let surfaces = payload["surfaces"] as? [[String: Any]] ?? []
    for surface in surfaces {
        if (surface["ref"] as? String) == handle || (surface["id"] as? String) == handle {
            if let id = surface["id"] as? String { return id }
        }
    }
    if let index = Int(handle) {
        for surface in surfaces where intFromAny(surface["index"]) == index {
            if let id = surface["id"] as? String { return id }
        }
    }
    throw CLIError(message: "Surface target not found")
}

private func tmuxWorkspaceIdForPaneHandle(_ handle: String, client: SocketClient) throws -> String? {
    guard isUUID(handle) || isHandleRef(handle) else { return nil }
    let workspaces = try tmuxWorkspaceItems(client: client)
    for workspace in workspaces {
        guard let workspaceId = workspace["id"] as? String else { continue }
        let payload = try client.sendV2(method: "pane.list", params: ["workspace_id": workspaceId])
        let panes = payload["panes"] as? [[String: Any]] ?? []
        if panes.contains(where: { ($0["id"] as? String) == handle || ($0["ref"] as? String) == handle }) {
            return workspaceId
        }
    }
    return nil
}

private func tmuxFocusedPaneId(workspaceId: String, client: SocketClient) throws -> String {
    let payload = try client.sendV2(method: "surface.current", params: ["workspace_id": workspaceId])
    if let paneId = payload["pane_id"] as? String { return paneId }
    if let paneRef = payload["pane_ref"] as? String {
        return try tmuxCanonicalPaneId(paneRef, workspaceId: workspaceId, client: client)
    }
    throw CLIError(message: "Pane target not found")
}

private func tmuxSelectedSurfaceId(workspaceId: String, paneId: String, client: SocketClient) throws -> String {
    let payload = try client.sendV2(method: "pane.surfaces", params: ["workspace_id": workspaceId, "pane_id": paneId])
    let surfaces = payload["surfaces"] as? [[String: Any]] ?? []
    if let selected = surfaces.first(where: { ($0["selected"] as? Bool) == true }),
       let id = selected["id"] as? String {
        return id
    }
    if let first = surfaces.first?["id"] as? String { return first }
    throw CLIError(message: "Pane has no surface to target")
}

func tmuxResolveWorkspaceTarget(_ raw: String?, client: SocketClient) throws -> String {
    guard var token = normalizedTmuxTarget(raw) else {
        if let callerWorkspace = tmuxCallerWorkspaceHandle() {
            return try resolveWorkspaceId(callerWorkspace, client: client)
        }
        return try resolveWorkspaceId(nil, client: client)
    }

    if token == "!" || token == "^" || token == "-" {
        let payload = try client.sendV2(method: "workspace.last")
        if let workspaceId = payload["workspace_id"] as? String { return workspaceId }
        throw CLIError(message: "Previous workspace not found")
    }

    if let dot = token.lastIndex(of: ".") {
        token = String(token[..<dot])
    }
    if let colon = token.lastIndex(of: ":") {
        let suffix = token[token.index(after: colon)...]
        token = suffix.isEmpty ? String(token[..<colon]) : String(suffix)
    }
    if token.hasPrefix("@") {
        token = String(token.dropFirst())
    }

    if isUUID(token) {
        return token
    }

    let needle = token.trimmingCharacters(in: .whitespacesAndNewlines)
    let items = try tmuxWorkspaceItems(client: client)
    if let match = items.first(where: {
        (($0["title"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines) == needle
    }), let id = match["id"] as? String {
        return id
    }

    throw CLIError(message: "Workspace target not found: \(token)")
}

func tmuxResolvePaneTarget(_ raw: String?, client: SocketClient) throws -> (workspaceId: String, paneId: String) {
    let paneSelector = tmuxPaneSelector(from: raw)
    let workspaceSelector = tmuxWindowSelector(from: raw)
    let workspaceId: String = {
        if let workspaceSelector {
            return (try? tmuxResolveWorkspaceTarget(workspaceSelector, client: client)) ?? ""
        }
        if let paneSelector,
           let wsId = (try? tmuxWorkspaceIdForPaneHandle(paneSelector, client: client)).flatMap({ $0 }) {
            return wsId
        }
        return (try? tmuxResolveWorkspaceTarget(nil, client: client)) ?? ""
    }()
    guard !workspaceId.isEmpty else {
        throw CLIError(message: "Workspace target not found")
    }
    let paneId: String
    if let paneSelector {
        paneId = try tmuxCanonicalPaneId(paneSelector, workspaceId: workspaceId, client: client)
    } else if tmuxCallerWorkspaceHandle() == workspaceId,
              let callerPane = tmuxCallerPaneHandle(),
              let callerPaneId = try? tmuxCanonicalPaneId(callerPane, workspaceId: workspaceId, client: client) {
        paneId = callerPaneId
    } else {
        paneId = try tmuxFocusedPaneId(workspaceId: workspaceId, client: client)
    }
    return (workspaceId, paneId)
}

func tmuxResolveSurfaceTarget(
    _ raw: String?,
    client: SocketClient
) throws -> (workspaceId: String, paneId: String?, surfaceId: String) {
    if tmuxPaneSelector(from: raw) != nil {
        let resolved = try tmuxResolvePaneTarget(raw, client: client)
        let surfaceId = try tmuxSelectedSurfaceId(
            workspaceId: resolved.workspaceId,
            paneId: resolved.paneId,
            client: client
        )
        return (resolved.workspaceId, resolved.paneId, surfaceId)
    }

    let workspaceId = try tmuxResolveWorkspaceTarget(tmuxWindowSelector(from: raw), client: client)
    if tmuxWindowSelector(from: raw) == nil,
       tmuxCallerWorkspaceHandle() == workspaceId,
       let callerSurface = tmuxCallerSurfaceHandle(),
       let surfaceId = try? tmuxCanonicalSurfaceId(callerSurface, workspaceId: workspaceId, client: client) {
        return (workspaceId, nil, surfaceId)
    }
    let surfaceId = try resolveSurfaceId(nil, workspaceId: workspaceId, client: client)
    return (workspaceId, nil, surfaceId)
}

// MARK: Tmux format rendering

func tmuxRenderFormat(_ format: String?, context: [String: String], fallback: String) -> String {
    guard let format, !format.isEmpty else { return fallback }
    var rendered = format
    for (key, value) in context {
        rendered = rendered.replacingOccurrences(of: "#{\(key)}", with: value)
    }
    rendered = rendered.replacingOccurrences(
        of: "#\\{[^}]+\\}",
        with: "",
        options: .regularExpression
    )
    let trimmed = rendered.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? fallback : trimmed
}

func tmuxFormatContext(
    workspaceId: String,
    paneId: String? = nil,
    surfaceId: String? = nil,
    client: SocketClient
) throws -> [String: String] {
    let canonicalWorkspaceId: String
    if isUUID(workspaceId) {
        canonicalWorkspaceId = workspaceId
    } else {
        canonicalWorkspaceId = try resolveWorkspaceId(workspaceId, client: client)
    }

    var context: [String: String] = [
        "session_name": "namu",
        "window_id": "@\(canonicalWorkspaceId)",
        "window_uuid": canonicalWorkspaceId
    ]

    let workspaceItems = try tmuxWorkspaceItems(client: client)
    if let workspace = workspaceItems.first(where: { ($0["id"] as? String) == canonicalWorkspaceId }) {
        if let index = intFromAny(workspace["index"]) {
            context["window_index"] = String(index)
        }
        let title = ((workspace["title"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !title.isEmpty {
            context["window_name"] = title
        }
    }

    let currentPayload = try client.sendV2(method: "surface.current", params: ["workspace_id": canonicalWorkspaceId])
    let resolvedPaneId: String? = try {
        if let paneId {
            return try tmuxCanonicalPaneId(paneId, workspaceId: canonicalWorkspaceId, client: client)
        }
        if let currentPaneId = currentPayload["pane_id"] as? String { return currentPaneId }
        if let currentPaneRef = currentPayload["pane_ref"] as? String {
            return try tmuxCanonicalPaneId(currentPaneRef, workspaceId: canonicalWorkspaceId, client: client)
        }
        return nil
    }()

    let resolvedSurfaceId: String? = try {
        if let surfaceId { return try tmuxCanonicalSurfaceId(surfaceId, workspaceId: canonicalWorkspaceId, client: client) }
        if let resolvedPaneId {
            return try tmuxSelectedSurfaceId(workspaceId: canonicalWorkspaceId, paneId: resolvedPaneId, client: client)
        }
        return currentPayload["surface_id"] as? String
    }()

    if let resolvedPaneId {
        context["pane_id"] = "%\(resolvedPaneId)"
        context["pane_uuid"] = resolvedPaneId
        let panePayload = try client.sendV2(method: "pane.list", params: ["workspace_id": canonicalWorkspaceId])
        let panes = panePayload["panes"] as? [[String: Any]] ?? []
        if let pane = panes.first(where: { ($0["id"] as? String) == resolvedPaneId }),
           let index = intFromAny(pane["index"]) {
            context["pane_index"] = String(index)
        }
    }

    if let resolvedSurfaceId {
        context["surface_id"] = resolvedSurfaceId
        let surfacePayload = try client.sendV2(method: "surface.list", params: ["workspace_id": canonicalWorkspaceId])
        let surfaces = surfacePayload["surfaces"] as? [[String: Any]] ?? []
        if let surface = surfaces.first(where: { ($0["id"] as? String) == resolvedSurfaceId }) {
            let title = ((surface["title"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !title.isEmpty {
                context["pane_title"] = title
                context["window_name"] = context["window_name"] ?? title
            }
        }
    }

    return context
}

// MARK: Tmux send-keys helpers

private func tmuxShellQuote(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
}

func tmuxShellCommandText(commandTokens: [String], cwd: String?) -> String? {
    let trimmedCwd = cwd?.trimmingCharacters(in: .whitespacesAndNewlines)
    let commandText = commandTokens.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    guard (trimmedCwd?.isEmpty == false) || !commandText.isEmpty else { return nil }
    var pieces: [String] = []
    if let trimmedCwd, !trimmedCwd.isEmpty {
        pieces.append("cd -- \(tmuxShellQuote(resolvePath(trimmedCwd)))")
    }
    if !commandText.isEmpty {
        pieces.append(commandText)
    }
    return pieces.joined(separator: " && ") + "\r"
}

private func tmuxSpecialKeyText(_ token: String) -> String? {
    switch token.lowercased() {
    case "enter", "c-m", "kpenter":
        return "\r"
    case "tab", "c-i":
        return "\t"
    case "space":
        return " "
    case "bspace", "backspace":
        return "\u{7f}"
    case "escape", "esc", "c-[":
        return "\u{1b}"
    case "c-c":
        return "\u{03}"
    case "c-d":
        return "\u{04}"
    case "c-z":
        return "\u{1a}"
    case "c-l":
        return "\u{0c}"
    case "dc":      // Delete
        return "\u{1b}[3~"
    case "ic":      // Insert
        return "\u{1b}[2~"
    default:
        // Handle C-<letter> patterns generically
        if token.count == 3,
           token.hasPrefix("C-") || token.hasPrefix("c-"),
           let ch = token.last,
           ch.isLetter {
            let ascii = ch.lowercased().unicodeScalars.first!.value
            if ascii >= 97 && ascii <= 122 {
                return String(UnicodeScalar(ascii - 96)!)
            }
        }
        return nil
    }
}

private func tmuxSendKeysText(from tokens: [String], literal: Bool) -> String {
    if literal { return tokens.joined(separator: " ") }
    var result = ""
    var pendingSpace = false
    for token in tokens {
        if let special = tmuxSpecialKeyText(token) {
            result += special
            pendingSpace = false
            continue
        }
        if pendingSpace { result += " " }
        result += token
        pendingSpace = true
    }
    return result
}

// MARK: Tmux compat store (buffer system)

struct MainVerticalState: Codable {
    var mainSurfaceId: String
    var lastColumnSurfaceId: String?
}

struct TmuxCompatStore: Codable {
    var buffers: [String: String] = [:]
    var mainVerticalLayouts: [String: MainVerticalState] = [:]
    var lastSplitSurface: [String: String] = [:]

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        buffers = try container.decodeIfPresent([String: String].self, forKey: .buffers) ?? [:]
        mainVerticalLayouts = try container.decodeIfPresent([String: MainVerticalState].self, forKey: .mainVerticalLayouts) ?? [:]
        lastSplitSurface = try container.decodeIfPresent([String: String].self, forKey: .lastSplitSurface) ?? [:]
    }
}

private func tmuxCompatStoreURL() -> URL {
    let root = NSString(string: "~/.namu").expandingTildeInPath
    return URL(fileURLWithPath: root).appendingPathComponent("tmux-compat-store.json")
}

func loadTmuxCompatStore() -> TmuxCompatStore {
    let url = tmuxCompatStoreURL()
    guard let data = try? Data(contentsOf: url),
          let decoded = try? JSONDecoder().decode(TmuxCompatStore.self, from: data) else {
        return TmuxCompatStore()
    }
    return decoded
}

func saveTmuxCompatStore(_ store: TmuxCompatStore) throws {
    let url = tmuxCompatStoreURL()
    let parent = url.deletingLastPathComponent()
    try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true, attributes: nil)
    let data = try JSONEncoder().encode(store)
    try data.write(to: url, options: .atomic)
}

private func tmuxWaitForSignalURL(name: String) -> URL {
    let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
    let sanitized = name.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" }
    return URL(fileURLWithPath: "/tmp/namu-wait-for-\(String(sanitized)).sig")
}

// MARK: Focused context for claude-teams

private struct NamuTeamsFocusedContext {
    let workspaceId: String
    let paneHandle: String
    let paneId: String?
    let surfaceId: String?
}

private func claudeTeamsFocusedContext(socketPath: String) -> NamuTeamsFocusedContext? {
    let client = SocketClient(path: socketPath)
    do {
        try client.connect()
        defer { client.close() }
        let payload = try client.sendV2(method: "system.identify")
        let focused = payload["focused"] as? [String: Any] ?? [:]
        guard let workspaceId = (focused["workspace_id"] as? String) ?? (focused["workspace_ref"] as? String),
              let paneId = (focused["pane_id"] as? String) ?? (focused["pane_ref"] as? String) else {
            return nil
        }
        let paneHandle = paneId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !paneHandle.isEmpty else { return nil }
        let surfaceId = (focused["surface_id"] as? String) ?? (focused["surface_ref"] as? String)
        return NamuTeamsFocusedContext(
            workspaceId: workspaceId,
            paneHandle: paneHandle,
            paneId: focused["pane_id"] as? String,
            surfaceId: surfaceId
        )
    } catch {
        client.close()
        return nil
    }
}

/// Launch Claude Code with agent teams enabled, using a fake tmux shim
/// that translates tmux commands into Namu socket operations.
func handleClaudeTeams(_ args: [String]) throws {
    let env = ProcessInfo.processInfo.environment
    let socketPath = env["NAMU_SOCKET"] ?? "/tmp/namu.sock"

    // Create shim directory with a fake tmux binary.
    let homeDir = env["HOME"] ?? NSHomeDirectory()
    let shimDir = "\(homeDir)/.namu/claude-teams-bin"
    try FileManager.default.createDirectory(
        atPath: shimDir,
        withIntermediateDirectories: true
    )

    // Write the tmux shim script.
    let shimPath = "\(shimDir)/tmux"
    let shimScript = """
    #!/usr/bin/env bash
    set -euo pipefail
    exec "${NAMU_CLAUDE_TEAMS_BIN:-namu}" __tmux-compat "$@"
    """
    let existing = try? String(contentsOfFile: shimPath, encoding: .utf8)
    if existing?.trimmingCharacters(in: .whitespacesAndNewlines) != shimScript.trimmingCharacters(in: .whitespacesAndNewlines) {
        try shimScript.write(toFile: shimPath, atomically: true, encoding: .utf8)
        chmod(shimPath, 0o755)
    }

    // Resolve our own executable path for the shim callback.
    let execPath: String = {
        if let p = env["NAMU_CLI_PATH"], FileManager.default.isExecutableFile(atPath: p) { return p }
        let selfPath = CommandLine.arguments[0]
        if selfPath.contains("/") && FileManager.default.isExecutableFile(atPath: selfPath) { return selfPath }
        return "namu"
    }()

    // Query focused context from the socket so TMUX env contains real IDs.
    let focusedContext = claudeTeamsFocusedContext(socketPath: socketPath)

    // Build fake TMUX env so Claude Code thinks it's inside tmux.
    let fakeTmux: String = {
        if let ctx = focusedContext {
            return "/tmp/namu-claude-teams/\(ctx.workspaceId),\(ctx.workspaceId),\(ctx.paneHandle)"
        }
        return env["TMUX"] ?? "/tmp/namu-claude-teams/default,0,0"
    }()
    let fakeTmuxPane: String = {
        if let ctx = focusedContext { return "%\(ctx.paneHandle)" }
        return env["TMUX_PANE"] ?? "%1"
    }()

    // Set environment.
    setenv("CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS", "1", 1)
    setenv("NAMU_CLAUDE_TEAMS_BIN", execPath, 1)
    // Prepend shim dir without duplicating existing PATH entries
    let existingPath = env["PATH"] ?? "/usr/bin:/bin"
    let pathParts = ([shimDir] + existingPath.split(separator: ":").map(String.init)).reduce(into: ([String](), Set<String>())) { acc, entry in
        if !entry.isEmpty && acc.1.insert(entry).inserted { acc.0.append(entry) }
    }.0
    setenv("PATH", pathParts.joined(separator: ":"), 1)
    setenv("TMUX", fakeTmux, 1)
    setenv("TMUX_PANE", fakeTmuxPane, 1)
    setenv("TERM", env["TERM"] ?? "screen-256color", 1)
    setenv("NAMU_SOCKET", socketPath, 1)
    unsetenv("TERM_PROGRAM")
    if let ctx = focusedContext {
        setenv("NAMU_WORKSPACE_ID", ctx.workspaceId, 1)
        if let surfaceId = ctx.surfaceId, !surfaceId.isEmpty {
            setenv("NAMU_SURFACE_ID", surfaceId, 1)
        }
    }

    // Find the real claude binary (skip our shim dir).
    let claudePath: String = {
        let pathDirs = (env["PATH"] ?? "").split(separator: ":").map(String.init)
        for dir in pathDirs {
            if dir == shimDir { continue }
            if dir.hasSuffix("Resources/bin") { continue }
            let candidate = "\(dir)/claude"
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return "claude"
    }()

    // Forward remaining args to claude.
    let claudeArgs = Array(args.dropFirst(2)) // drop "namu" and "claude-teams"
    var argv = ([claudePath] + claudeArgs).map { strdup($0) }
    defer { argv.forEach { free($0) } }
    argv.append(nil)

    execv(claudePath, &argv)
    execvp("claude", &argv)
    let code = errno
    throw CLIError(message: "Failed to launch claude: \(String(cString: strerror(code)))")
}

// MARK: - Tmux Compat (full implementation)

/// Translate tmux commands into Namu socket operations.
/// Called by the fake tmux shim when Claude Code spawns teammates.
func handleTmuxCompat(_ args: [String]) throws {
    // args: ["namu", "__tmux-compat", <tmux-command>, <tmux-args...>]
    guard args.count >= 3 else {
        throw CLIError(message: "Usage: namu __tmux-compat <tmux-command> [args...]")
    }

    let env = ProcessInfo.processInfo.environment
    let socketPath = env["NAMU_SOCKET"] ?? "/tmp/namu.sock"
    let commandArgs = Array(args.dropFirst(2))

    let client = SocketClient(path: socketPath)
    defer { client.close() }
    try client.connect()

    let (command, rawArgs) = try splitTmuxCommand(commandArgs)

    // Plugin dispatch: resolve from registry before falling through to switch
    if let commandType = tmuxCommandRegistry.resolve(command) {
        let cmd = try commandType.init(client: client, args: rawArgs)
        try cmd.run()
        return
    }

    switch command {
    case "new-session", "new":
        let parsed = try parseTmuxArguments(
            rawArgs,
            valueFlags: ["-c", "-F", "-n", "-s"],
            boolFlags: ["-A", "-d", "-P"]
        )
        if parsed.hasFlag("-A") {
            throw CLIError(message: "new-session -A is not supported in namu claude-teams mode")
        }
        var params: [String: Any] = ["focus": false]
        if let cwd = parsed.value("-c") { params["cwd"] = resolvePath(cwd) }
        let created = try client.sendV2(method: "workspace.create", params: params)
        guard let workspaceId = created["workspace_id"] as? String else {
            throw CLIError(message: "workspace.create did not return workspace_id")
        }
        if let title = parsed.value("-n") ?? parsed.value("-s"),
           !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            _ = try client.sendV2(method: "workspace.rename", params: [
                "workspace_id": workspaceId,
                "title": title
            ])
        }
        if let text = tmuxShellCommandText(commandTokens: parsed.positional, cwd: parsed.value("-c")) {
            let surfaceId = try resolveSurfaceId(nil, workspaceId: workspaceId, client: client)
            _ = try client.sendV2(method: "surface.send_text", params: [
                "workspace_id": workspaceId,
                "surface_id": surfaceId,
                "text": text
            ])
        }
        if parsed.hasFlag("-P") {
            let context = try tmuxFormatContext(workspaceId: workspaceId, client: client)
            print(tmuxRenderFormat(parsed.value("-F"), context: context, fallback: "@\(workspaceId)"))
        }

    case "new-window", "neww":
        let parsed = try parseTmuxArguments(
            rawArgs,
            valueFlags: ["-c", "-F", "-n", "-t"],
            boolFlags: ["-d", "-P"]
        )
        var params: [String: Any] = ["focus": false]
        if let cwd = parsed.value("-c") { params["cwd"] = resolvePath(cwd) }
        let created = try client.sendV2(method: "workspace.create", params: params)
        guard let workspaceId = created["workspace_id"] as? String else {
            throw CLIError(message: "workspace.create did not return workspace_id")
        }
        if let title = parsed.value("-n"),
           !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            _ = try client.sendV2(method: "workspace.rename", params: [
                "workspace_id": workspaceId,
                "title": title
            ])
        }
        if let text = tmuxShellCommandText(commandTokens: parsed.positional, cwd: parsed.value("-c")) {
            let surfaceId = try resolveSurfaceId(nil, workspaceId: workspaceId, client: client)
            _ = try client.sendV2(method: "surface.send_text", params: [
                "workspace_id": workspaceId,
                "surface_id": surfaceId,
                "text": text
            ])
        }
        if parsed.hasFlag("-P") {
            let context = try tmuxFormatContext(workspaceId: workspaceId, client: client)
            print(tmuxRenderFormat(parsed.value("-F"), context: context, fallback: "@\(workspaceId)"))
        }

    case "select-window", "selectw":
        let parsed = try parseTmuxArguments(rawArgs, valueFlags: ["-t"], boolFlags: [])
        let workspaceId = try tmuxResolveWorkspaceTarget(parsed.value("-t"), client: client)
        _ = try client.sendV2(method: "workspace.select", params: ["workspace_id": workspaceId])

    case "kill-window", "killw":
        let parsed = try parseTmuxArguments(rawArgs, valueFlags: ["-t"], boolFlags: [])
        let workspaceId = try tmuxResolveWorkspaceTarget(parsed.value("-t"), client: client)
        _ = try client.sendV2(method: "workspace.close", params: ["workspace_id": workspaceId])

    case "kill-pane", "killp":
        let parsed = try parseTmuxArguments(rawArgs, valueFlags: ["-t"], boolFlags: [])
        let target = try tmuxResolveSurfaceTarget(parsed.value("-t"), client: client)
        _ = try client.sendV2(method: "surface.close", params: [
            "workspace_id": target.workspaceId,
            "surface_id": target.surfaceId
        ])

    case "send-keys", "send":
        let parsed = try parseTmuxArguments(rawArgs, valueFlags: ["-t"], boolFlags: ["-l"])
        let target = try tmuxResolveSurfaceTarget(parsed.value("-t"), client: client)
        let text = tmuxSendKeysText(from: parsed.positional, literal: parsed.hasFlag("-l"))
        if !text.isEmpty {
            _ = try client.sendV2(method: "surface.send_text", params: [
                "workspace_id": target.workspaceId,
                "surface_id": target.surfaceId,
                "text": text
            ])
        }

    case "display-message", "display", "displayp":
        let parsed = try parseTmuxArguments(rawArgs, valueFlags: ["-F", "-t"], boolFlags: ["-p"])
        let target = try tmuxResolveSurfaceTarget(parsed.value("-t"), client: client)
        let context = try tmuxFormatContext(
            workspaceId: target.workspaceId,
            paneId: target.paneId,
            surfaceId: target.surfaceId,
            client: client
        )
        let format = parsed.positional.isEmpty ? parsed.value("-F") : parsed.positional.joined(separator: " ")
        let rendered = tmuxRenderFormat(format, context: context, fallback: "")
        if parsed.hasFlag("-p") || !rendered.isEmpty {
            print(rendered)
        }

    case "list-windows", "lsw":
        let parsed = try parseTmuxArguments(rawArgs, valueFlags: ["-F", "-t"], boolFlags: [])
        let items = try tmuxWorkspaceItems(client: client)
        for item in items {
            guard let workspaceId = item["id"] as? String else { continue }
            let context = try tmuxFormatContext(workspaceId: workspaceId, client: client)
            let fallback = [
                context["window_index"] ?? "?",
                context["window_name"] ?? workspaceId
            ].joined(separator: " ")
            print(tmuxRenderFormat(parsed.value("-F"), context: context, fallback: fallback))
        }

    case "rename-window", "renamew":
        let parsed = try parseTmuxArguments(rawArgs, valueFlags: ["-t"], boolFlags: [])
        let title = parsed.positional.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else {
            throw CLIError(message: "rename-window requires a title")
        }
        let workspaceId = try tmuxResolveWorkspaceTarget(parsed.value("-t"), client: client)
        _ = try client.sendV2(method: "workspace.rename", params: [
            "workspace_id": workspaceId,
            "title": title
        ])

    case "resize-pane", "resizep":
        let parsed = try parseTmuxArguments(
            rawArgs,
            valueFlags: ["-t", "-x", "-y"],
            boolFlags: ["-D", "-L", "-R", "-U", "-Z"]
        )
        if parsed.hasFlag("-Z") {
            // zoom toggle — silently accept
            return
        }
        let hasDirectionalFlags = parsed.hasFlag("-L") || parsed.hasFlag("-R")
            || parsed.hasFlag("-U") || parsed.hasFlag("-D")
        if !hasDirectionalFlags { return }
        let target = try tmuxResolvePaneTarget(parsed.value("-t"), client: client)
        let direction: String
        if parsed.hasFlag("-L") { direction = "left" }
        else if parsed.hasFlag("-U") { direction = "up" }
        else if parsed.hasFlag("-D") { direction = "down" }
        else { direction = "right" }
        let rawAmount = (parsed.value("-x") ?? parsed.value("-y") ?? "5")
            .replacingOccurrences(of: "%", with: "")
        let amount = Int(rawAmount) ?? 5
        _ = try client.sendV2(method: "pane.resize", params: [
            "workspace_id": target.workspaceId,
            "pane_id": target.paneId,
            "direction": direction,
            "amount": max(1, amount)
        ])

    case "last-pane":
        let parsed = try parseTmuxArguments(rawArgs, valueFlags: ["-t"], boolFlags: [])
        let workspaceId = try tmuxResolveWorkspaceTarget(parsed.value("-t"), client: client)
        _ = try client.sendV2(method: "pane.last", params: ["workspace_id": workspaceId])

    case "last-window":
        let parsed = try parseTmuxArguments(rawArgs, valueFlags: ["-t"], boolFlags: [])
        _ = parsed // accept silently — no direct mapping
        return

    case "next-window", "next":
        let parsed = try parseTmuxArguments(rawArgs, valueFlags: ["-t"], boolFlags: [])
        _ = parsed
        return

    case "previous-window", "prev":
        let parsed = try parseTmuxArguments(rawArgs, valueFlags: ["-t"], boolFlags: [])
        _ = parsed
        return

    case "show-buffer", "showb":
        let parsed = try parseTmuxArguments(rawArgs, valueFlags: ["-b"], boolFlags: [])
        let name = parsed.value("-b") ?? "default"
        let store = loadTmuxCompatStore()
        if let buffer = store.buffers[name] { print(buffer) }

    case "set-buffer", "setb":
        let parsed = try parseTmuxArguments(rawArgs, valueFlags: ["-b", "-n"], boolFlags: ["-a"])
        let name = parsed.value("-b") ?? parsed.value("-n") ?? "default"
        let content = parsed.positional.joined(separator: " ")
        guard !content.isEmpty else {
            throw CLIError(message: "set-buffer requires text")
        }
        var store = loadTmuxCompatStore()
        if parsed.hasFlag("-a"), let existing = store.buffers[name] {
            store.buffers[name] = existing + content
        } else {
            store.buffers[name] = content
        }
        try saveTmuxCompatStore(store)

    case "paste-buffer", "pasteb":
        let parsed = try parseTmuxArguments(rawArgs, valueFlags: ["-b", "-t"], boolFlags: ["-d", "-p", "-r"])
        let name = parsed.value("-b") ?? "default"
        let store = loadTmuxCompatStore()
        guard let buffer = store.buffers[name] else {
            throw CLIError(message: "Buffer not found: \(name)")
        }
        if parsed.hasFlag("-p") {
            print(buffer)
        } else {
            let target = try tmuxResolveSurfaceTarget(parsed.value("-t"), client: client)
            _ = try client.sendV2(method: "surface.send_text", params: [
                "workspace_id": target.workspaceId,
                "surface_id": target.surfaceId,
                "text": buffer
            ])
        }

    case "list-buffers", "lsb":
        let store = loadTmuxCompatStore()
        for (name, content) in store.buffers.sorted(by: { $0.key < $1.key }) {
            print("\(name): \(content.count) bytes")
        }

    case "wait-for":
        let signal = rawArgs.contains("-S") || rawArgs.contains("--signal")
        let name = rawArgs.first(where: { !$0.hasPrefix("-") }) ?? ""
        guard !name.isEmpty else {
            throw CLIError(message: "wait-for requires a name")
        }
        let signalURL = tmuxWaitForSignalURL(name: name)
        if signal {
            FileManager.default.createFile(atPath: signalURL.path, contents: Data())
            return
        }
        let timeout: TimeInterval = 30.0
        do {
            try SocketClient.waitForFilesystemPath(signalURL.path, timeout: timeout)
            try? FileManager.default.removeItem(at: signalURL)
        } catch {
            if FileManager.default.fileExists(atPath: signalURL.path) {
                try? FileManager.default.removeItem(at: signalURL)
                return
            }
            throw CLIError(message: "wait-for timed out waiting for '\(name)'")
        }

    case "has-session", "has":
        let parsed = try parseTmuxArguments(rawArgs, valueFlags: ["-t"], boolFlags: [])
        _ = try tmuxResolveWorkspaceTarget(parsed.value("-t"), client: client)

    case "select-layout":
        let parsed = try parseTmuxArguments(rawArgs, valueFlags: ["-t"], boolFlags: [])
        let layoutName = parsed.positional.first ?? ""
        let workspaceId: String = {
            if let target = parsed.value("-t") {
                return (try? tmuxResolveWorkspaceTarget(target, client: client)) ?? ""
            }
            return (try? tmuxResolveWorkspaceTarget(nil, client: client)) ?? ""
        }()
        guard !workspaceId.isEmpty else { fputs("Error: could not resolve workspace\n", stderr); return }

        if layoutName == "main-vertical" {
            if let callerSurface = tmuxCallerSurfaceHandle() {
                var store = loadTmuxCompatStore()
                let existingColumn = store.mainVerticalLayouts[workspaceId]?.lastColumnSurfaceId
                let seedColumn = existingColumn ?? store.lastSplitSurface[workspaceId]
                store.mainVerticalLayouts[workspaceId] = MainVerticalState(
                    mainSurfaceId: callerSurface,
                    lastColumnSurfaceId: seedColumn
                )
                try saveTmuxCompatStore(store)
            }
        } else if !layoutName.isEmpty {
            var store = loadTmuxCompatStore()
            let removedLayout = store.mainVerticalLayouts.removeValue(forKey: workspaceId) != nil
            let removedSplit = store.lastSplitSurface.removeValue(forKey: workspaceId) != nil
            if removedLayout || removedSplit {
                try saveTmuxCompatStore(store)
            }
        }

    case "set-option", "set", "set-window-option", "setw",
         "source-file", "refresh-client", "attach-session", "detach-client", "set-hook":
        return

    default:
        FileHandle.standardError.write(Data("namu: unsupported tmux command: \(command)\n".utf8))
    }
}

// MARK: - Config Commands

/// Handle `namu config` subcommands — reads namu.json locally and executes via socket.
func handleConfig(_ args: [String]) throws {
    // args: ["namu", "config", <subcommand>, ...]
    guard args.count >= 3 else {
        print("""
        Usage: namu config <subcommand>

        Subcommands:
          list                     List all commands from namu.json
          run <name>               Run a command by name
          path                     Show config file paths

        Config files:
          ./namu.json              Project-local (higher priority)
          ~/.config/namu/namu.json Global
        """)
        return
    }

    let subcommand = args[2]

    switch subcommand {
    case "list":
        let commands = loadConfigCommands()
        if commands.isEmpty {
            print("No commands found. Create a namu.json in your project or ~/.config/namu/")
            return
        }
        for cmd in commands {
            let desc = cmd.description.map { " — \($0)" } ?? ""
            let type = cmd.workspace != nil ? "[workspace]" : "[shell]"
            print("  \(cmd.name) \(type)\(desc)")
        }

    case "run":
        guard args.count >= 4 else {
            throw CLIError(message: "Usage: namu config run <command-name>")
        }
        let name = args[3...].joined(separator: " ")
        let commands = loadConfigCommands()
        guard let cmd = commands.first(where: { $0.name.lowercased() == name.lowercased() }) else {
            throw CLIError(message: "Command '\(name)' not found in namu.json")
        }

        guard let shellCmd = cmd.command else {
            throw CLIError(message: "Command '\(name)' is a workspace command — run it from the command palette")
        }

        // Send the command to the focused terminal via socket.
        let env = ProcessInfo.processInfo.environment
        let socketPath = env["NAMU_SOCKET"] ?? "/tmp/namu.sock"
        let client = SocketClient(path: socketPath)
        defer { client.close() }
        try client.connect()
        let response = try client.sendRequest(
            method: "pane.send_keys",
            params: ["text": shellCmd + "\n"],
            timeout: 5
        )
        print("OK")

    case "path":
        let cwd = FileManager.default.currentDirectoryPath
        let localPath = "\(cwd)/namu.json"
        let globalPath = homeDir() + "/.config/namu/namu.json"
        let localExists = FileManager.default.fileExists(atPath: localPath)
        let globalExists = FileManager.default.fileExists(atPath: globalPath)
        print("Local:  \(localPath) \(localExists ? "(found)" : "(not found)")")
        print("Global: \(globalPath) \(globalExists ? "(found)" : "(not found)")")

    default:
        throw CLIError(message: "Unknown config subcommand '\(subcommand)'. Use: list, run, path")
    }
}

/// Load commands from project-local and global namu.json files.
private func loadConfigCommands() -> [ConfigCommandEntry] {
    var commands: [ConfigCommandEntry] = []
    let cwd = FileManager.default.currentDirectoryPath

    // Global config.
    let globalPath = homeDir() + "/.config/namu/namu.json"
    if let cmds = loadConfigFile(at: globalPath) {
        commands.append(contentsOf: cmds.map { ConfigCommandEntry(definition: $0, source: "global") })
    }

    // Project-local config (overrides global by name).
    let localPath = "\(cwd)/namu.json"
    if let cmds = loadConfigFile(at: localPath) {
        let globalNames = Set(commands.map(\.name))
        for cmd in cmds {
            if globalNames.contains(cmd.name) {
                commands.removeAll { $0.name == cmd.name }
            }
            commands.append(ConfigCommandEntry(definition: cmd, source: "local"))
        }
    }

    return commands
}

private func loadConfigFile(at path: String) -> [CLICommandDefinition]? {
    guard FileManager.default.fileExists(atPath: path),
          let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return nil }
    struct ConfigFile: Codable { var commands: [CLICommandDefinition] }
    return (try? JSONDecoder().decode(ConfigFile.self, from: data))?.commands
}

private func homeDir() -> String {
    ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
}

/// Lightweight command definition for CLI (no NamuKit dependency).
private struct CLICommandDefinition: Codable {
    let name: String
    var description: String?
    var keywords: [String]?
    var command: String?
    var workspace: CLIWorkspaceDefinition?
    var confirm: Bool?
}

private struct CLIWorkspaceDefinition: Codable {
    var name: String?
}

private struct ConfigCommandEntry {
    let definition: CLICommandDefinition
    let source: String // "local" or "global"
    var name: String { definition.name }
    var description: String? { definition.description }
    var command: String? { definition.command }
    var workspace: CLIWorkspaceDefinition? { definition.workspace }
}

// MARK: - Entry point

signal(SIGPIPE, SIG_IGN)

if CommandLine.arguments.count < 2 ||
   CommandLine.arguments[1] == "--help" ||
   CommandLine.arguments[1] == "-h" {
    print(usageString())
    exit(0)
}

// Intercept special commands before normal dispatch.
if CommandLine.arguments[1] == "config" {
    do {
        try handleConfig(CommandLine.arguments)
    } catch let error as CLIError {
        FileHandle.standardError.write(Data("Error: \(error.message)\n".utf8))
        exit(1)
    } catch {
        FileHandle.standardError.write(Data("Error: \(error)\n".utf8))
        exit(1)
    }
    exit(0)
}

if CommandLine.arguments[1] == "claude-teams" {
    do {
        try handleClaudeTeams(CommandLine.arguments)
    } catch let error as CLIError {
        FileHandle.standardError.write(Data("Error: \(error.message)\n".utf8))
        exit(1)
    } catch {
        FileHandle.standardError.write(Data("Error: \(error)\n".utf8))
        exit(1)
    }
    exit(0)
}

if CommandLine.arguments[1] == "__tmux-compat" {
    do {
        try handleTmuxCompat(CommandLine.arguments)
    } catch let error as CLIError {
        FileHandle.standardError.write(Data("Error: \(error.message)\n".utf8))
        exit(1)
    } catch {
        FileHandle.standardError.write(Data("Error: \(error)\n".utf8))
        exit(1)
    }
    exit(0)
}

if CommandLine.arguments[1] == "claude-hook" {
    do {
        try handleClaudeHook(CommandLine.arguments)
    } catch let error as CLIError {
        FileHandle.standardError.write(Data("Error: \(error.message)\n".utf8))
        exit(1)
    } catch {
        FileHandle.standardError.write(Data("Error: \(error)\n".utf8))
        exit(1)
    }
    exit(0)
}

do {
    try run()
} catch let error as CLIError {
    FileHandle.standardError.write(Data("Error: \(error.message)\n".utf8))
    exit(1)
} catch {
    FileHandle.standardError.write(Data("Error: \(error)\n".utf8))
    exit(1)
}
