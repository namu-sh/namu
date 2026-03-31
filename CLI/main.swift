import Foundation
import Darwin
import Security

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

// MARK: - SSH Subcommand

/// Generate a random hex string of `byteCount` random bytes.
private func randomHex(_ byteCount: Int) -> String {
    var bytes = [UInt8](repeating: 0, count: byteCount)
    _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
    return bytes.map { String(format: "%02x", $0) }.joined()
}

/// Find a free TCP port by binding to port 0 on loopback and reading the assigned port.
private func findFreePort() -> Int? {
    let sock = socket(AF_INET, SOCK_STREAM, 0)
    guard sock >= 0 else { return nil }
    defer { close(sock) }
    var addr = sockaddr_in()
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = 0
    addr.sin_addr.s_addr = INADDR_LOOPBACK.bigEndian
    var addrLen = socklen_t(MemoryLayout<sockaddr_in>.size)
    let bindResult = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            bind(sock, $0, addrLen)
        }
    }
    guard bindResult == 0 else { return nil }
    let getsockResult = withUnsafeMutablePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            getsockname(sock, $0, &addrLen)
        }
    }
    guard getsockResult == 0 else { return nil }
    return Int(UInt16(bigEndian: addr.sin_port))
}

/// Use infocmp to get the local xterm-ghostty terminfo source text.
private func localXtermGhosttyTerminfoSource() -> String? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/infocmp")
    process.arguments = ["-0", "-x", "xterm-ghostty"]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    do {
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let source = String(data: data, encoding: .utf8), !source.isEmpty else { return nil }
        return source.trimmingCharacters(in: .whitespacesAndNewlines)
    } catch {
        return nil
    }
}

/// Build per-shell bootstrap script for remote terminals.
/// Sets up PATH, env exports, ZDOTDIR overlay, and optional xterm-ghostty terminfo provisioning.
private func buildInteractiveRemoteShellScript(
    relayPort: Int,
    terminfoSource: String?,
    workspaceID: String
) -> String {
    let shellStateDir = "$HOME/.namu/relay/\(relayPort).shell"

    // Common env lines applied after user dotfiles load
    let commonLines = [
        "export PATH=\"$HOME/.namu/bin:$PATH\"",
        "hash -r >/dev/null 2>&1 || true",
        "rehash >/dev/null 2>&1 || true",
        "if [ -f \"$HOME/.namu/socket_addr\" ]; then",
        "  export NAMU_SOCKET_PATH=\"$(cat \"$HOME/.namu/socket_addr\")\"",
        "fi",
        "export NAMU_WORKSPACE_ID=\"\(workspaceID)\"",
        "export NAMU_SURFACE_ID=\"${NAMU_SURFACE_ID:-}\"",
        "export NAMU_BUNDLED_CLI_PATH=\"$HOME/.namu/bin/namu\"",
        "export COLORTERM=truecolor",
        "export TERM_PROGRAM=Namu",
        "export TERM_PROGRAM_VERSION=1.0",
        "_namu_gsf=\"${GHOSTTY_SHELL_FEATURES:-}\"",
        "case \"$_namu_gsf\" in *ssh-env*) ;; *) _namu_gsf=\"${_namu_gsf:+$_namu_gsf,}ssh-env\" ;; esac",
        "case \"$_namu_gsf\" in *ssh-terminfo*) ;; *) _namu_gsf=\"${_namu_gsf:+$_namu_gsf,}ssh-terminfo\" ;; esac",
        "export GHOSTTY_SHELL_FEATURES=\"$_namu_gsf\"",
    ].joined(separator: "\n")

    // Terminfo provisioning block — use tic to compile from source, fallback to xterm-256color
    var terminfoBlock = ""
    if let source = terminfoSource, !source.isEmpty {
        terminfoBlock = """
namu_term='xterm-256color'
if command -v infocmp >/dev/null 2>&1 && infocmp xterm-ghostty >/dev/null 2>&1; then
  namu_term='xterm-ghostty'
fi
if [ "$namu_term" != 'xterm-ghostty' ]; then
  (
    command -v tic >/dev/null 2>&1 || exit 0
    mkdir -p "$HOME/.terminfo" 2>/dev/null || exit 0
    cat <<'NAMU_TERMINFO' | tic -x - >/dev/null 2>&1
\(source)
NAMU_TERMINFO
  ) >/dev/null 2>&1 &
  if command -v infocmp >/dev/null 2>&1 && infocmp xterm-ghostty >/dev/null 2>&1; then
    namu_term='xterm-ghostty'
  fi
fi
export TERM="$namu_term"
"""
    }

    // Zsh .zshenv lines (chain to real ZDOTDIR .zshenv, then restore our ZDOTDIR)
    let histfileRedirect = "if [ -z \"${HISTFILE:-}\" ] || [ \"$HISTFILE\" = \"\(shellStateDir)/.zsh_history\" ]; then export HISTFILE=\"${NAMU_REAL_ZDOTDIR:-$HOME}/.zsh_history\"; fi"
    let zshEnvLines = [
        "[ -f \"$NAMU_REAL_ZDOTDIR/.zshenv\" ] && source \"$NAMU_REAL_ZDOTDIR/.zshenv\"",
        histfileRedirect,
        "if [ -n \"${ZDOTDIR:-}\" ] && [ \"$ZDOTDIR\" != \"\(shellStateDir)\" ]; then export NAMU_REAL_ZDOTDIR=\"$ZDOTDIR\"; fi",
        "export ZDOTDIR=\"\(shellStateDir)\"",
    ].joined(separator: "\n")

    // Zsh .zprofile lines
    let zshProfileLines = [
        "[ -f \"$NAMU_REAL_ZDOTDIR/.zprofile\" ] && source \"$NAMU_REAL_ZDOTDIR/.zprofile\"",
    ].joined(separator: "\n")

    // Zsh .zshrc lines (chain to real .zshrc, then apply common env)
    let zshRCLines = [
        "[ -f \"$NAMU_REAL_ZDOTDIR/.zshrc\" ] && source \"$NAMU_REAL_ZDOTDIR/.zshrc\"",
        histfileRedirect,
        commonLines,
    ].joined(separator: "\n")

    // Zsh .zlogin lines
    let zshLoginLines = [
        "[ -f \"$NAMU_REAL_ZDOTDIR/.zlogin\" ] && source \"$NAMU_REAL_ZDOTDIR/.zlogin\"",
    ].joined(separator: "\n")

    // Bash .bashrc lines (chain to real dotfiles, then apply common env)
    let bashRCLines = [
        "if [ -f \"$HOME/.bash_profile\" ]; then . \"$HOME/.bash_profile\"; elif [ -f \"$HOME/.bash_login\" ]; then . \"$HOME/.bash_login\"; elif [ -f \"$HOME/.profile\" ]; then . \"$HOME/.profile\"; fi",
        "[ -f \"$HOME/.bashrc\" ] && . \"$HOME/.bashrc\"",
        commonLines,
    ].joined(separator: "\n")

    var outerLines: [String] = []
    if !terminfoBlock.isEmpty {
        outerLines.append(terminfoBlock)
    }
    outerLines += [
        "NAMU_LOGIN_SHELL=\"${SHELL:-/bin/sh}\"",
        "case \"${NAMU_LOGIN_SHELL##*/}\" in",
        "  zsh)",
        "    mkdir -p \"\(shellStateDir)\"",
        "    cat > \"\(shellStateDir)/.zshenv\" <<'NAMUZSHENV'",
        zshEnvLines,
        "NAMUZSHENV",
        "    cat > \"\(shellStateDir)/.zprofile\" <<'NAMUZSHPROFILE'",
        zshProfileLines,
        "NAMUZSHPROFILE",
        "    cat > \"\(shellStateDir)/.zshrc\" <<'NAMUZSHRC'",
        zshRCLines,
        "NAMUZSHRC",
        "    cat > \"\(shellStateDir)/.zlogin\" <<'NAMUZSHLOGIN'",
        zshLoginLines,
        "NAMUZSHLOGIN",
        "    chmod 600 \"\(shellStateDir)/.zshenv\" \"\(shellStateDir)/.zprofile\" \"\(shellStateDir)/.zshrc\" \"\(shellStateDir)/.zlogin\" >/dev/null 2>&1 || true",
        "    export NAMU_REAL_ZDOTDIR=\"${ZDOTDIR:-$HOME}\"",
        "    export ZDOTDIR=\"\(shellStateDir)\"",
        "    exec \"$NAMU_LOGIN_SHELL\" -il",
        "    ;;",
        "  bash)",
        "    mkdir -p \"\(shellStateDir)\"",
        "    cat > \"\(shellStateDir)/.bashrc\" <<'NAMUBASHRC'",
        bashRCLines,
        "NAMUBASHRC",
        "    chmod 600 \"\(shellStateDir)/.bashrc\" >/dev/null 2>&1 || true",
        "    exec \"$NAMU_LOGIN_SHELL\" --rcfile \"\(shellStateDir)/.bashrc\" -i",
        "    ;;",
        "  *)",
        commonLines,
        "    exec \"$NAMU_LOGIN_SHELL\" -i",
        "    ;;",
        "esac",
    ]

    return outerLines.joined(separator: "\n")
}

/// Build SSH startup command that wraps the remote shell with a session-end trap.
private func buildSSHStartupCommand(
    workspaceID: String,
    relayPort: Int,
    bootstrapScript: String
) -> String {
    return """
    _namu_session_ended=0
    _namu_cleanup() {
      [ "$_namu_session_ended" = "1" ] && return
      _namu_session_ended=1
      rm -f "$_namu_tmp" 2>/dev/null
      _namu_surface_arg=""
      [ -n "$NAMU_SURFACE_ID" ] && _namu_surface_arg="--surface $NAMU_SURFACE_ID"
      if [ -n "$NAMU_BUNDLED_CLI_PATH" ] && [ -x "$NAMU_BUNDLED_CLI_PATH" ]; then
        "$NAMU_BUNDLED_CLI_PATH" ssh-session-end --workspace "\(workspaceID)" --relay-port "\(relayPort)" $_namu_surface_arg 2>/dev/null || true
      elif command -v namu >/dev/null 2>&1; then
        namu ssh-session-end --workspace "\(workspaceID)" --relay-port "\(relayPort)" $_namu_surface_arg 2>/dev/null || true
      fi
    }
    _namu_tmp="$(mktemp /tmp/namu-ssh-bootstrap.XXXXXX)"
    cat > "$_namu_tmp" << 'NAMUBOOTSTRAP'
    \(bootstrapScript)
    NAMUBOOTSTRAP
    chmod 700 "$_namu_tmp"
    trap _namu_cleanup EXIT HUP INT TERM
    . "$_namu_tmp"
    _namu_exit_status=$?
    trap - EXIT HUP INT TERM
    _namu_cleanup
    exit $_namu_exit_status
    """
}

/// Handle `namu ssh [options] user@host` — create a remote workspace via IPC.
///
/// Options:
///   --port <port>          SSH port (default: 22)
///   --identity <file>      Path to identity file (private key)
///   -o <ssh-option>        Extra SSH option (repeatable)
///   --workspace <name>     Name for the new workspace
///   --no-focus             Do not focus the new workspace after creation
///   -- <args>              Extra arguments passed as remote command
func handleSSH(_ args: [String]) throws {
    // args[0] = executable, args[1] = "ssh"
    let remaining = Array(args.dropFirst(2))

    guard !remaining.isEmpty else {
        throw CLIError(message: """
        Usage: namu ssh [options] user@host [-- remote-command...]

        Create a new remote workspace connected over SSH.

        Options:
          --port <port>          SSH port (default: 22)
          --identity <file>      Path to identity file (private key)
          -o <ssh-option>        Extra SSH option (repeatable, can appear multiple times)
          --workspace <name>     Name for the new workspace
          --no-focus             Do not focus the workspace after creation

        Examples:
          namu ssh user@remote.example.com
          namu ssh --port 2222 --identity ~/.ssh/id_ed25519 user@remote.example.com
          namu ssh -o StrictHostKeyChecking=no --workspace "Dev Remote" user@remote.example.com
          namu ssh user@remote.example.com -- htop
        """)
    }

    var port: Int? = nil
    var identityFile: String? = nil
    var sshOptions: [String] = []
    var workspaceName: String? = nil
    var destination: String? = nil
    var noFocus = false
    var extraArguments: [String] = []

    var i = 0
    var passthrough = false
    while i < remaining.count {
        let arg = remaining[i]
        if passthrough {
            extraArguments.append(arg)
            i += 1
            continue
        }
        switch arg {
        case "--":
            passthrough = true
        case "--port":
            i += 1
            guard i < remaining.count, let p = Int(remaining[i]) else {
                throw CLIError(message: "--port requires a numeric port number")
            }
            guard (1...65535).contains(p) else {
                throw CLIError(message: "--port must be between 1 and 65535")
            }
            port = p
        case "--identity":
            i += 1
            guard i < remaining.count else {
                throw CLIError(message: "--identity requires a file path")
            }
            identityFile = remaining[i]
        case "-o":
            i += 1
            guard i < remaining.count else {
                throw CLIError(message: "-o requires an SSH option string")
            }
            sshOptions.append(remaining[i])
        case "--workspace":
            i += 1
            guard i < remaining.count else {
                throw CLIError(message: "--workspace requires a name")
            }
            workspaceName = remaining[i]
        case "--no-focus":
            noFocus = true
        default:
            if arg.hasPrefix("-") {
                throw CLIError(message: "Unknown option '\(arg)'. Run 'namu ssh' with no arguments for usage.")
            }
            if destination != nil {
                throw CLIError(message: "Unexpected extra argument '\(arg)'. Only one destination is allowed.")
            }
            destination = arg
        }
        i += 1
    }

    guard let dest = destination else {
        throw CLIError(message: "Missing destination. Usage: namu ssh [options] user@host")
    }

    // Generate relay credentials.
    let relayID = randomHex(16)
    let relayToken = randomHex(32)
    let relayPort = findFreePort() ?? 0
    let localSocketPath = ProcessInfo.processInfo.environment["NAMU_SOCKET"] ?? "/tmp/namu.sock"

    let client = SocketClient(path: localSocketPath)
    defer { client.close() }

    do {
        try client.connect()
    } catch let error as CLIError {
        if error.message.contains("not running") || error.message.contains("No such file") {
            throw CLIError(message: "Namu is not running")
        }
        throw error
    }

    // Step 1: create workspace.
    let createParams: [String: Any] = ["title": workspaceName ?? dest]
    let createResponse = try client.sendRequest(method: "workspace.create", params: createParams, timeout: 15)
    guard let createResult = createResponse["result"] as? [String: Any],
          let wsID = createResult["id"] as? String, !wsID.isEmpty else {
        throw CLIError(message: "workspace.create did not return an id")
    }

    // Build SSH ControlSocket defaults for connection multiplexing.
    var effectiveSSHOptions = sshOptions
    let hasControlMaster = sshOptions.contains { $0.lowercased().hasPrefix("controlmaster") }
    let hasControlPersist = sshOptions.contains { $0.lowercased().hasPrefix("controlpersist") }
    let hasControlPath = sshOptions.contains { $0.lowercased().hasPrefix("controlpath") }
    if !hasControlMaster { effectiveSSHOptions.append("ControlMaster=auto") }
    if !hasControlPersist { effectiveSSHOptions.append("ControlPersist=600") }
    if !hasControlPath {
        let uid = getuid()
        effectiveSSHOptions.append("ControlPath=/tmp/namu-ssh-\(uid)-\(relayPort)-%C")
    }
    // Belt-and-suspenders: set env vars on SSH command line so they're available
    // even before the bootstrap script runs (for AcceptEnv-configured servers).
    effectiveSSHOptions.append("SetEnv COLORTERM=truecolor")
    effectiveSSHOptions.append("SendEnv TERM_PROGRAM TERM_PROGRAM_VERSION")

    // Build bootstrap and startup scripts (now that we have wsID).
    let terminfoSource = localXtermGhosttyTerminfoSource()
    let bootstrapScript = buildInteractiveRemoteShellScript(
        relayPort: relayPort,
        terminfoSource: terminfoSource,
        workspaceID: wsID
    )
    let startupCommand = buildSSHStartupCommand(
        workspaceID: wsID,
        relayPort: relayPort,
        bootstrapScript: bootstrapScript
    )

    // Step 2: configure remote — rollback on failure.
    var configParams: [String: Any] = [
        "workspace_id": wsID,
        "destination": dest,
        "auto_connect": true,
        "relay_port": relayPort,
        "relay_id": relayID,
        "relay_token": relayToken,
        "local_socket_path": localSocketPath,
    ]
    if let p = port { configParams["port"] = p }
    if let id = identityFile { configParams["identity_file"] = id }
    if !effectiveSSHOptions.isEmpty { configParams["ssh_options"] = effectiveSSHOptions }
    if !extraArguments.isEmpty {
        configParams["terminal_startup_command"] = extraArguments.joined(separator: " ")
    } else {
        configParams["terminal_startup_command"] = startupCommand
    }

    let configResponse: [String: Any]
    do {
        configResponse = try client.sendRequest(method: "workspace.remote.configure", params: configParams, timeout: 30)
    } catch {
        // Rollback: close the workspace we just created.
        let _ = try? client.sendRequest(method: "workspace.close", params: ["workspace_id": wsID], timeout: 10)
        throw error
    }

    // Step 3: optionally focus the workspace.
    if !noFocus {
        let _ = try? client.sendRequest(method: "workspace.select", params: ["id": wsID], timeout: 10)
    }

    if let result = configResponse["result"] as? [String: Any] {
        if result.isEmpty {
            print("OK workspace=\(wsID) target=\(dest)")
        } else {
            prettyPrint(result)
        }
    } else {
        var display = configResponse
        display.removeValue(forKey: "jsonrpc")
        display.removeValue(forKey: "id")
        prettyPrint(display)
    }
}

// MARK: - SSH Session End Subcommand

/// Handle `namu ssh-session-end` — notify namu that a remote SSH terminal session has ended.
/// Called automatically by the trap installed in the terminal startup command.
func handleSSHSessionEnd(remaining: [String]) {
    var workspaceID: String?
    var relayPort: Int?
    var surfaceID: String?

    var i = 0
    while i < remaining.count {
        switch remaining[i] {
        case "--workspace":
            i += 1
            guard i < remaining.count else {
                FileHandle.standardError.write(Data("--workspace requires a value\n".utf8))
                exit(1)
            }
            workspaceID = remaining[i]
        case "--relay-port":
            i += 1
            guard i < remaining.count, let p = Int(remaining[i]) else {
                FileHandle.standardError.write(Data("--relay-port requires a number\n".utf8))
                exit(1)
            }
            relayPort = p
        case "--surface":
            i += 1
            guard i < remaining.count else {
                FileHandle.standardError.write(Data("--surface requires a value\n".utf8))
                exit(1)
            }
            surfaceID = remaining[i]
        default:
            break
        }
        i += 1
    }

    guard let wsID = workspaceID else {
        FileHandle.standardError.write(Data("--workspace is required\n".utf8))
        exit(1)
    }

    var params: [String: Any] = ["workspace_id": wsID]
    if let rp = relayPort { params["relay_port"] = rp }
    if let sid = surfaceID { params["surface_id"] = sid }

    // Best effort — don't fail if socket unavailable.
    let socketPath = ProcessInfo.processInfo.environment["NAMU_SOCKET"] ?? "/tmp/namu.sock"
    let client = SocketClient(path: socketPath)
    defer { client.close() }
    if (try? client.connect()) != nil {
        let _ = try? client.sendRequest(
            method: "workspace.remote.terminal_session_end",
            params: params,
            timeout: 5
        )
    }

    // Best-effort ControlMaster cleanup using the known ControlPath template.
    if let rp = relayPort {
        let uid = getuid()
        let controlPathPattern = "/tmp/namu-ssh-\(uid)-\(rp)-*"
        let cleanupProcess = Process()
        cleanupProcess.executableURL = URL(fileURLWithPath: "/bin/sh")
        cleanupProcess.arguments = ["-c", """
            for sock in \(controlPathPattern); do
                [ -S "$sock" ] && ssh -O exit -o ControlPath="$sock" dummy 2>/dev/null || true
            done
        """]
        cleanupProcess.standardOutput = FileHandle.nullDevice
        cleanupProcess.standardError = FileHandle.nullDevice
        try? cleanupProcess.run()
        cleanupProcess.waitUntilExit()
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

// MARK: - Codex Hook

/// Handle Codex CLI hook events. Gracefully no-ops when not running inside Namu.
func handleCodexHook(_ args: [String]) throws {
    guard args.count >= 3 else {
        throw CLIError(message: "Usage: namu codex-hook <session-start|prompt-submit|stop>")
    }
    let event = args[2]

    let socketPath = ProcessInfo.processInfo.environment["NAMU_SOCKET"] ?? "/tmp/namu.sock"
    let surfaceID = ProcessInfo.processInfo.environment["NAMU_SURFACE_ID"] ?? ""

    // Graceful no-op: if not inside namu, exit silently with valid JSON
    guard !surfaceID.isEmpty else {
        print("{}")
        return
    }

    var stdinData = Data()
    while let chunk = try? FileHandle.standardInput.availableData, !chunk.isEmpty {
        stdinData.append(chunk)
        if stdinData.count > 64 * 1024 { break }
    }
    let context = (try? JSONSerialization.jsonObject(with: stdinData)) as? [String: Any] ?? [:]

    let workspaceID = ProcessInfo.processInfo.environment["NAMU_WORKSPACE_ID"] ?? ""

    let client = SocketClient(path: socketPath)
    defer { client.close() }

    do {
        try client.connect()
    } catch {
        // Namu not running — silently ignore hook
        print("{}")
        return
    }

    var params: [String: Any] = [
        "surface_id": surfaceID,
        "workspace_id": workspaceID,
        "event": event,
        "tool": "codex",
    ]

    switch event {
    case "session-start":
        if let sessionID = context["session_id"] as? String {
            params["session_id"] = sessionID
        }
        params["status"] = "running"
        _ = try? client.sendRequest(method: "system.claude_hook", params: params, timeout: 5)

    case "prompt-submit":
        params["status"] = "running"
        _ = try? client.sendRequest(method: "system.claude_hook", params: params, timeout: 5)

    case "stop":
        params["status"] = "idle"
        _ = try? client.sendRequest(method: "system.claude_hook", params: params, timeout: 5)

        let stopTitle = "Codex"
        let stopBody: String = {
            if let msg = context["last_assistant_message"] as? String, !msg.isEmpty { return msg }
            if let result = context["result"] as? String, !result.isEmpty { return result }
            return "Task complete"
        }()
        _ = try? client.sendRequest(method: "notification.create", params: [
            "title": stopTitle,
            "body": stopBody,
            "surface_id": surfaceID,
            "workspace_id": workspaceID,
        ], timeout: 5)

    default:
        break
    }

    print("{}")
}

// MARK: - Codex Install/Uninstall Hooks

/// Handle `namu codex <install-hooks|uninstall-hooks>`.
func handleCodex(_ args: [String]) throws {
    guard args.count >= 3 else {
        print("""
        Usage: namu codex <install-hooks|uninstall-hooks>

        Manage Codex CLI hooks integration.

        Subcommands:
          install-hooks     Install namu hooks into ~/.codex/hooks.json
          uninstall-hooks   Remove namu hooks from ~/.codex/hooks.json
        """)
        return
    }

    let subcommand = args[2]
    switch subcommand {
    case "install-hooks":
        try codexInstallHooks()
    case "uninstall-hooks":
        try codexUninstallHooks()
    default:
        throw CLIError(message: "Unknown codex subcommand '\(subcommand)'. Valid: install-hooks, uninstall-hooks")
    }
}

private func codexHookCommand(_ event: String) -> String {
    "[ -n \"$NAMU_SURFACE_ID\" ] && command -v namu >/dev/null 2>&1 && namu codex-hook \(event) || echo '{}'"
}

private let codexHooksJSON: [String: Any] = [
    "hooks": [
        "SessionStart": [[
            "hooks": [[
                "type": "command",
                "command": codexHookCommand("session-start"),
                "timeout": 10,
            ] as [String: Any]],
        ] as [String: Any]],
        "UserPromptSubmit": [[
            "hooks": [[
                "type": "command",
                "command": codexHookCommand("prompt-submit"),
                "timeout": 10,
            ] as [String: Any]],
        ] as [String: Any]],
        "Stop": [[
            "hooks": [[
                "type": "command",
                "command": codexHookCommand("stop"),
                "timeout": 10,
            ] as [String: Any]],
        ] as [String: Any]],
    ] as [String: Any],
]

private let codexHookCommandMarker = "namu codex-hook"

private func codexInstallHooks() throws {
    let skipConfirm = CommandLine.arguments.contains("--yes") || CommandLine.arguments.contains("-y")
    let codexHome = ProcessInfo.processInfo.environment["CODEX_HOME"]
        ?? NSString(string: "~/.codex").expandingTildeInPath
    let hooksPath = (codexHome as NSString).appendingPathComponent("hooks.json")
    let fm = FileManager.default

    try fm.createDirectory(atPath: codexHome, withIntermediateDirectories: true, attributes: nil)

    let existingContent: String? = fm.fileExists(atPath: hooksPath)
        ? (try? String(contentsOfFile: hooksPath, encoding: .utf8))
        : nil

    var existing: [String: Any] = [:]
    if let existingContent,
       let data = existingContent.data(using: .utf8),
       let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
        existing = parsed
    }

    var hooks = existing["hooks"] as? [String: Any] ?? [:]
    let namuHooks = codexHooksJSON["hooks"] as! [String: Any]
    for (eventName, namuGroups) in namuHooks {
        guard let namuGroupArray = namuGroups as? [[String: Any]] else { continue }
        var eventGroups = hooks[eventName] as? [[String: Any]] ?? []
        eventGroups.removeAll { group in
            guard let groupHooks = group["hooks"] as? [[String: Any]] else { return false }
            return groupHooks.allSatisfy { hook in
                (hook["command"] as? String)?.contains(codexHookCommandMarker) == true
            }
        }
        eventGroups.append(contentsOf: namuGroupArray)
        hooks[eventName] = eventGroups
    }
    existing["hooks"] = hooks

    let newJsonData = try JSONSerialization.data(withJSONObject: existing, options: [.prettyPrinted, .sortedKeys])
    let newContent = String(data: newJsonData, encoding: .utf8) ?? ""

    if existingContent == newContent {
        print("namu hooks are already installed. Nothing to change.")
        return
    }

    print("Will write: \(hooksPath)")
    if existingContent == nil {
        print("  (new file)")
    }

    if !skipConfirm {
        print("Apply these changes? [Y/n] ", terminator: "")
        if let response = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
           !response.isEmpty && response != "y" && response != "yes" {
            print("Aborted.")
            return
        }
    }

    try newJsonData.write(to: URL(fileURLWithPath: hooksPath), options: .atomic)
    print("Installed. Hooks activate inside namu and silently no-op elsewhere.")
    print("To remove: namu codex uninstall-hooks")
}

private func codexUninstallHooks() throws {
    let skipConfirm = CommandLine.arguments.contains("--yes") || CommandLine.arguments.contains("-y")
    let codexHome = ProcessInfo.processInfo.environment["CODEX_HOME"]
        ?? NSString(string: "~/.codex").expandingTildeInPath
    let hooksPath = (codexHome as NSString).appendingPathComponent("hooks.json")
    let fm = FileManager.default

    guard fm.fileExists(atPath: hooksPath),
          let data = try? Data(contentsOf: URL(fileURLWithPath: hooksPath)),
          var parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        print("No hooks.json found at \(hooksPath)")
        return
    }

    guard var hooks = parsed["hooks"] as? [String: Any] else {
        print("No hooks section found in \(hooksPath)")
        return
    }

    var removedCount = 0
    for eventName in hooks.keys {
        guard var eventGroups = hooks[eventName] as? [[String: Any]] else { continue }
        let before = eventGroups.count
        eventGroups.removeAll { group in
            guard let groupHooks = group["hooks"] as? [[String: Any]] else { return false }
            return groupHooks.allSatisfy { hook in
                (hook["command"] as? String)?.contains(codexHookCommandMarker) == true
            }
        }
        removedCount += before - eventGroups.count
        if eventGroups.isEmpty {
            hooks.removeValue(forKey: eventName)
        } else {
            hooks[eventName] = eventGroups
        }
    }

    if removedCount == 0 {
        print("No namu hooks found.")
        return
    }

    parsed["hooks"] = hooks
    let newJsonData = try JSONSerialization.data(withJSONObject: parsed, options: [.prettyPrinted, .sortedKeys])

    print("Will remove \(removedCount) namu hook(s) from \(hooksPath)")

    if !skipConfirm {
        print("Apply these changes? [Y/n] ", terminator: "")
        if let response = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
           !response.isEmpty && response != "y" && response != "yes" {
            print("Aborted.")
            return
        }
    }

    try newJsonData.write(to: URL(fileURLWithPath: hooksPath), options: .atomic)
    print("Removed \(removedCount) namu hook(s).")
}

// MARK: - OpenCode

/// Handle `namu opencode` / `namu omo` — launches opencode via execvp.
func handleOpenCode(_ args: [String]) throws {
    let commandArgs = Array(args.dropFirst(2)) // drop "namu" and "opencode"/"omo"

    // Find opencode on PATH
    let pathEntries = ProcessInfo.processInfo.environment["PATH"]?
        .split(separator: ":").map(String.init) ?? []
    var openCodePath: String? = nil
    for entry in pathEntries where !entry.isEmpty {
        let candidate = URL(fileURLWithPath: entry, isDirectory: true)
            .appendingPathComponent("opencode", isDirectory: false).path
        if FileManager.default.isExecutableFile(atPath: candidate) {
            openCodePath = candidate
            break
        }
    }

    guard openCodePath != nil || (try? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        p.arguments = ["opencode"]
        p.standardOutput = Pipe(); p.standardError = Pipe()
        try p.run(); p.waitUntilExit()
        return p.terminationStatus == 0
    }()) == true else {
        throw CLIError(message: "opencode is not installed. Install it first:\n  npm install -g opencode-ai\n  # or\n  bun install -g opencode-ai\n\nThen run: namu opencode")
    }

    // Set up shadow config directory so we don't mutate the user's ~/.config/opencode/
    let homePath = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
    let shadowConfigDir = URL(fileURLWithPath: homePath, isDirectory: true)
        .appendingPathComponent(".namuterm", isDirectory: true)
        .appendingPathComponent("opencode-config", isDirectory: true)

    try FileManager.default.createDirectory(at: shadowConfigDir, withIntermediateDirectories: true, attributes: nil)

    let userConfigDir = URL(fileURLWithPath: homePath, isDirectory: true)
        .appendingPathComponent(".config", isDirectory: true)
        .appendingPathComponent("opencode", isDirectory: true)

    // Copy/symlink user's opencode.json into shadow dir if present
    let userJsonURL = userConfigDir.appendingPathComponent("opencode.json")
    let shadowJsonURL = shadowConfigDir.appendingPathComponent("opencode.json")
    if FileManager.default.fileExists(atPath: userJsonURL.path),
       !FileManager.default.fileExists(atPath: shadowJsonURL.path) {
        try? FileManager.default.createSymbolicLink(at: shadowJsonURL, withDestinationURL: userJsonURL)
    }

    // Point OpenCode at the shadow config
    setenv("OPENCODE_CONFIG_DIR", shadowConfigDir.path, 1)

    // Also expose the namu socket path
    let socketPath = ProcessInfo.processInfo.environment["NAMU_SOCKET"] ?? "/tmp/namu.sock"
    setenv("NAMU_SOCKET", socketPath, 0) // don't overwrite if already set

    // --- Plugin management: ensure oh-my-openagent plugin config exists ---
    let pluginDir = URL(fileURLWithPath: homePath, isDirectory: true)
        .appendingPathComponent(".namuterm", isDirectory: true)
        .appendingPathComponent("opencode-plugins", isDirectory: true)
        .appendingPathComponent("oh-my-openagent", isDirectory: true)
    try FileManager.default.createDirectory(at: pluginDir, withIntermediateDirectories: true, attributes: nil)
    let pluginConfigURL = pluginDir.appendingPathComponent("config.json")
    if !FileManager.default.fileExists(atPath: pluginConfigURL.path) {
        let namuSocket = ProcessInfo.processInfo.environment["NAMU_SOCKET"] ?? "/tmp/namu.sock"
        let pluginConfig: [String: Any] = [
            "name": "oh-my-openagent",
            "version": "1.0.0",
            "terminalIntegration": [
                "namuSocket": namuSocket,
                "shellIntegration": "namu"
            ]
        ]
        if let data = try? JSONSerialization.data(withJSONObject: pluginConfig, options: .prettyPrinted) {
            try? data.write(to: pluginConfigURL)
        }
    }

    // --- tmux-compat shim: create a fake tmux that delegates to `namu __tmux-compat` ---
    let shimDir = URL(fileURLWithPath: homePath, isDirectory: true)
        .appendingPathComponent(".namuterm", isDirectory: true)
        .appendingPathComponent("opencode-bin", isDirectory: true)
    try FileManager.default.createDirectory(at: shimDir, withIntermediateDirectories: true, attributes: nil)
    let shimPath = shimDir.appendingPathComponent("tmux").path
    // Resolve our own executable for the shim callback
    let selfExec: String = {
        if let p = ProcessInfo.processInfo.environment["NAMU_CLI_PATH"],
           FileManager.default.isExecutableFile(atPath: p) { return p }
        let s = CommandLine.arguments[0]
        if s.contains("/") && FileManager.default.isExecutableFile(atPath: s) { return s }
        return "namu"
    }()
    let shimScript = """
    #!/usr/bin/env bash
    set -euo pipefail
    exec "\(selfExec)" __tmux-compat "$@"
    """
    let existingShim = try? String(contentsOfFile: shimPath, encoding: .utf8)
    if existingShim?.trimmingCharacters(in: .whitespacesAndNewlines)
        != shimScript.trimmingCharacters(in: .whitespacesAndNewlines) {
        try shimScript.write(toFile: shimPath, atomically: true, encoding: .utf8)
        chmod(shimPath, 0o755)
    }

    // Prepend shim dir to PATH so opencode picks up our fake tmux
    let currentPath = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/local/bin:/usr/bin:/bin"
    setenv("PATH", "\(shimDir.path):\(currentPath)", 1)

    // Signal shell integration that we are running inside opencode
    setenv("NAMU_OPENCODE_MODE", "1", 1)

    let launchPath = openCodePath ?? "opencode"
    var argv = ([launchPath] + commandArgs).map { strdup($0) }
    defer { argv.forEach { free($0) } }
    argv.append(nil)

    if openCodePath != nil {
        execv(launchPath, &argv)
    } else {
        execvp("opencode", &argv)
    }
    let code = errno
    throw CLIError(message: "Failed to launch opencode: \(String(cString: strerror(code)))")
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

    case "pipe-pane", "pipep":
        // Acknowledge pipe-pane; actual piping to external commands is not supported.
        let parsed = try parseTmuxArguments(rawArgs, valueFlags: ["-t", "-I", "-O"], boolFlags: ["-o"])
        _ = parsed
        return

    case "swap-pane", "swapp":
        let parsed = try parseTmuxArguments(rawArgs, valueFlags: ["-s", "-t"], boolFlags: ["-D", "-U", "-Z", "-d"])
        let source = try tmuxResolveSurfaceTarget(parsed.value("-s"), client: client)
        let dest   = try tmuxResolveSurfaceTarget(parsed.value("-t"), client: client)
        _ = try client.sendV2(method: "surface.swap", params: [
            "workspace_id": source.workspaceId,
            "source_surface_id": source.surfaceId,
            "dest_surface_id": dest.surfaceId
        ])

    case "break-pane", "breakp":
        let parsed = try parseTmuxArguments(rawArgs, valueFlags: ["-F", "-n", "-t"], boolFlags: ["-P", "-d"])
        let target = try tmuxResolveSurfaceTarget(parsed.value("-t"), client: client)
        let created = try client.sendV2(method: "workspace.create", params: ["focus": !parsed.hasFlag("-d")])
        guard let newWorkspaceId = created["workspace_id"] as? String else {
            throw CLIError(message: "workspace.create did not return workspace_id")
        }
        if let title = parsed.value("-n"),
           !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            _ = try client.sendV2(method: "workspace.rename", params: [
                "workspace_id": newWorkspaceId,
                "title": title
            ])
        }
        _ = try client.sendV2(method: "surface.move", params: [
            "source_workspace_id": target.workspaceId,
            "surface_id": target.surfaceId,
            "dest_workspace_id": newWorkspaceId
        ])
        if parsed.hasFlag("-P") {
            let context = try tmuxFormatContext(workspaceId: newWorkspaceId, client: client)
            print(tmuxRenderFormat(parsed.value("-F"), context: context, fallback: "@\(newWorkspaceId)"))
        }

    case "join-pane", "joinp":
        let parsed = try parseTmuxArguments(
            rawArgs,
            valueFlags: ["-s", "-t", "-l", "-F"],
            boolFlags: ["-b", "-d", "-h", "-v", "-P"]
        )
        let source = try tmuxResolveSurfaceTarget(parsed.value("-s"), client: client)
        let dest   = try tmuxResolveSurfaceTarget(parsed.value("-t"), client: client)
        let direction: String
        if parsed.hasFlag("-h") {
            direction = parsed.hasFlag("-b") ? "left" : "right"
        } else {
            direction = parsed.hasFlag("-b") ? "up" : "down"
        }
        _ = try client.sendV2(method: "surface.move", params: [
            "source_workspace_id": source.workspaceId,
            "surface_id": source.surfaceId,
            "dest_workspace_id": dest.workspaceId,
            "dest_surface_id": dest.surfaceId,
            "direction": direction
        ])

    case "find-window", "findw":
        let parsed = try parseTmuxArguments(rawArgs, valueFlags: ["-t", "-F"], boolFlags: ["-C", "-N", "-r", "-Z"])
        let query = parsed.positional.joined(separator: " ")
        let items = try tmuxWorkspaceItems(client: client)
        for item in items {
            guard let workspaceId = item["id"] as? String else { continue }
            let context = try tmuxFormatContext(workspaceId: workspaceId, client: client)
            let title = context["window_name"] ?? workspaceId
            let matches: Bool
            if parsed.hasFlag("-r") {
                matches = (title.range(of: query, options: .regularExpression) != nil)
            } else {
                matches = title.localizedCaseInsensitiveContains(query)
            }
            if matches {
                let fallback = [context["window_index"] ?? "?", title].joined(separator: " ")
                print(tmuxRenderFormat(parsed.value("-F"), context: context, fallback: fallback))
            }
        }

    case "clear-history", "clearhist":
        let parsed = try parseTmuxArguments(rawArgs, valueFlags: ["-t"], boolFlags: [])
        let target = try tmuxResolveSurfaceTarget(parsed.value("-t"), client: client)
        _ = try client.sendV2(method: "surface.send_text", params: [
            "workspace_id": target.workspaceId,
            "surface_id": target.surfaceId,
            "text": "clear\n"
        ])

    case "respawn-pane", "respawnp":
        let parsed = try parseTmuxArguments(rawArgs, valueFlags: ["-t", "-c"], boolFlags: ["-k"])
        let target = try tmuxResolveSurfaceTarget(parsed.value("-t"), client: client)
        _ = try client.sendV2(method: "surface.respawn", params: [
            "workspace_id": target.workspaceId,
            "surface_id": target.surfaceId
        ])

    case "set-option", "set", "set-window-option", "setw",
         "source-file", "refresh-client", "attach-session", "detach-client", "set-hook":
        return

    case "popup":
        // No-op: popup windows are not supported; return success silently.
        return

    case "bind-key", "bind", "unbind-key", "unbind":
        // No-op: key bindings are managed by Namu natively.
        return

    case "copy-mode":
        // Forward to the active terminal as a no-op pass-through.
        let parsed = try parseTmuxArguments(rawArgs, valueFlags: ["-t"], boolFlags: ["-u", "-e", "-H", "-q"])
        _ = parsed
        return

    case "delete-buffer", "deleteb":
        let parsed = try parseTmuxArguments(rawArgs, valueFlags: ["-b"], boolFlags: [])
        let name = parsed.value("-b") ?? "default"
        var store = loadTmuxCompatStore()
        store.buffers.removeValue(forKey: name)
        try saveTmuxCompatStore(store)

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

if CommandLine.arguments[1] == "ssh" {
    do {
        try handleSSH(CommandLine.arguments)
    } catch let error as CLIError {
        FileHandle.standardError.write(Data("Error: \(error.message)\n".utf8))
        exit(1)
    } catch {
        FileHandle.standardError.write(Data("Error: \(error)\n".utf8))
        exit(1)
    }
    exit(0)
}

if CommandLine.arguments[1] == "ssh-session-end" {
    handleSSHSessionEnd(remaining: Array(CommandLine.arguments.dropFirst(2)))
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

if CommandLine.arguments[1] == "codex-hook" {
    do {
        try handleCodexHook(CommandLine.arguments)
    } catch let error as CLIError {
        FileHandle.standardError.write(Data("Error: \(error.message)\n".utf8))
        exit(1)
    } catch {
        FileHandle.standardError.write(Data("Error: \(error)\n".utf8))
        exit(1)
    }
    exit(0)
}

if CommandLine.arguments[1] == "codex" {
    do {
        try handleCodex(CommandLine.arguments)
    } catch let error as CLIError {
        FileHandle.standardError.write(Data("Error: \(error.message)\n".utf8))
        exit(1)
    } catch {
        FileHandle.standardError.write(Data("Error: \(error)\n".utf8))
        exit(1)
    }
    exit(0)
}

if CommandLine.arguments[1] == "opencode" || CommandLine.arguments[1] == "omo" {
    do {
        try handleOpenCode(CommandLine.arguments)
    } catch let error as CLIError {
        FileHandle.standardError.write(Data("Error: \(error.message)\n".utf8))
        exit(1)
    } catch {
        FileHandle.standardError.write(Data("Error: \(error)\n".utf8))
        exit(1)
    }
    exit(0)
}

// Flat-command aliases: bypass the namespace parser for common operations.
// These map single-word commands to their namespace.command equivalents.
let flatAliases: [String: (namespace: String, command: String)] = [
    "version":          ("system", "version"),
    "list-workspaces":  ("workspace", "list"),
    "new-workspace":    ("workspace", "create"),
    "list-panes":       ("pane", "list"),
    "send":             ("surface", "send_text"),
    "read-screen":      ("pane", "read_screen"),
    "notify":           ("notification", "create"),
]
if let alias = flatAliases[CommandLine.arguments[1]] {
    // Rewrite arguments to namespace form and fall through to run()
    var rewritten = CommandLine.arguments
    rewritten[1] = alias.namespace
    rewritten.insert(alias.command, at: 2)
    // Replace process arguments isn't possible, so just call run() directly with the mapped values
    let socket = ProcessInfo.processInfo.environment["NAMU_SOCKET"] ?? "/tmp/namu.sock"
    let client = SocketClient(path: socket)
    let method = "\(alias.namespace).\(alias.command)"
    var params: [String: Any] = [:]
    if CommandLine.arguments.count > 2 {
        // Pass remaining args as positional
        let remaining = Array(CommandLine.arguments.dropFirst(2))
        if alias.command == "create" && !remaining.isEmpty {
            params["title"] = remaining[0]
            if remaining.count > 1 { params["body"] = remaining[1] }
        } else if alias.command == "send_text" && !remaining.isEmpty {
            params["text"] = remaining.joined(separator: " ")
        }
    }
    do {
        let response = try client.sendRequest(method: method, params: params, timeout: 5.0)
        print(response)
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
