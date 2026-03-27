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

    var socketPath = "/tmp/namu.sock"
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
    let validNamespaces = ["workspace", "pane", "surface", "notification", "browser", "system", "ai"]
    guard validNamespaces.contains(namespace) else {
        throw CLIError(message: "Unknown namespace '\(namespace)'. Valid namespaces: \(validNamespaces.joined(separator: ", "))")
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

    Namespaces: workspace, pane, surface, notification, browser, system

    Examples:
      namu workspace list
      namu workspace create --title "My Workspace"
      namu pane split --direction horizontal
      namu pane send-keys "ls\\n"
      namu pane read-screen --lines 50
      namu system ping
      namu notification create --title "Build done" --body "Success"

    Flags:
      --socket <path>    Custom socket path (default: /tmp/namu.sock)
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

// MARK: - Entry point

signal(SIGPIPE, SIG_IGN)

if CommandLine.arguments.count < 2 ||
   CommandLine.arguments[1] == "--help" ||
   CommandLine.arguments[1] == "-h" {
    print(usageString())
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
