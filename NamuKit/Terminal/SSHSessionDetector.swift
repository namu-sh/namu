import Foundation
import Darwin

// MARK: - DetectedSSHSession

/// Parsed details of an active SSH connection in the foreground of a terminal.
struct DetectedSSHSession: Equatable {
    let destination: String
    let port: Int?
    let identityFile: String?
    let configFile: String?
    let jumpHost: String?
    let controlPath: String?
    let useIPv4: Bool
    let useIPv6: Bool
    let forwardAgent: Bool
    let compressionEnabled: Bool
    let sshOptions: [String]

    /// Build scp arguments forwarding all SSH options to scp.
    func scpArguments(localPath: String, remotePath: String) -> [String] {
        var args: [String] = [
            "-q",
            "-o", "ConnectTimeout=6",
            "-o", "ServerAliveInterval=20",
            "-o", "ServerAliveCountMax=2",
            "-o", "BatchMode=yes",
            "-o", "ControlMaster=no",
        ]

        if useIPv4 {
            args.append("-4")
        } else if useIPv6 {
            args.append("-6")
        }
        if forwardAgent {
            args.append("-A")
        }
        if compressionEnabled {
            args.append("-C")
        }
        if let configFile, !configFile.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            args += ["-F", configFile]
        }
        if let jumpHost, !jumpHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            args += ["-J", jumpHost]
        }
        if let port {
            args += ["-P", String(port)]
        }
        if let identityFile, !identityFile.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            args += ["-i", identityFile]
        }
        if let controlPath,
           !controlPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           !TerminalSSHSessionDetector.hasSSHOptionKey(sshOptions, key: "ControlPath") {
            args += ["-o", "ControlPath=\(controlPath)"]
        }
        if !TerminalSSHSessionDetector.hasSSHOptionKey(sshOptions, key: "StrictHostKeyChecking") {
            args += ["-o", "StrictHostKeyChecking=accept-new"]
        }
        for option in sshOptions {
            args += ["-o", option]
        }

        args += [localPath, "\(TerminalSSHSessionDetector.scpRemoteDestination(destination)):\(remotePath)"]
        return args
    }

    private func sshArguments(command: String) -> [String] {
        var args: [String] = [
            "-T",
            "-o", "ConnectTimeout=6",
            "-o", "ServerAliveInterval=20",
            "-o", "ServerAliveCountMax=2",
            "-o", "BatchMode=yes",
            "-o", "ControlMaster=no",
        ]

        if useIPv4 {
            args.append("-4")
        } else if useIPv6 {
            args.append("-6")
        }
        if forwardAgent {
            args.append("-A")
        }
        if compressionEnabled {
            args.append("-C")
        }
        if let configFile, !configFile.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            args += ["-F", configFile]
        }
        if let jumpHost, !jumpHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            args += ["-J", jumpHost]
        }
        if let port {
            args += ["-p", String(port)]
        }
        if let identityFile, !identityFile.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            args += ["-i", identityFile]
        }
        if let controlPath,
           !controlPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           !TerminalSSHSessionDetector.hasSSHOptionKey(sshOptions, key: "ControlPath") {
            args += ["-o", "ControlPath=\(controlPath)"]
        }
        if !TerminalSSHSessionDetector.hasSSHOptionKey(sshOptions, key: "StrictHostKeyChecking") {
            args += ["-o", "StrictHostKeyChecking=accept-new"]
        }
        for option in sshOptions {
            args += ["-o", option]
        }

        args += [destination, command]
        return args
    }
}

// MARK: - SSHConfigParser

/// Parses an OpenSSH-style `~/.ssh/config` file and resolves configuration
/// for a given hostname by matching Host patterns (including wildcards).
struct SSHConfigParser {

    // MARK: - Types

    struct HostEntry {
        /// The raw patterns from the Host line (may contain * and ? wildcards).
        let patterns: [String]
        var hostname: String?
        var port: Int?
        var user: String?
        var identityFile: String?
        var proxyJump: String?

        /// Returns true if `hostname` matches any of this entry's patterns.
        func matches(_ hostname: String) -> Bool {
            patterns.contains { patternMatches($0, hostname: hostname) }
        }

        private func patternMatches(_ pattern: String, hostname: String) -> Bool {
            if pattern == "*" { return true }
            return globMatch(pattern: pattern.lowercased(), string: hostname.lowercased())
        }

        private func globMatch(pattern: String, string: String) -> Bool {
            var patternChars = Array(pattern)
            var stringChars = Array(string)
            return globMatchHelper(&patternChars, 0, &stringChars, 0)
        }

        private func globMatchHelper(
            _ pattern: inout [Character], _ pi: Int,
            _ string: inout [Character], _ si: Int
        ) -> Bool {
            var pi = pi
            var si = si
            while pi < pattern.count {
                let p = pattern[pi]
                if p == "*" {
                    var npi = pi + 1
                    while npi < pattern.count && pattern[npi] == "*" { npi += 1 }
                    if npi == pattern.count { return true }
                    for i in si...string.count {
                        if globMatchHelper(&pattern, npi, &string, i) { return true }
                    }
                    return false
                } else if p == "?" {
                    if si >= string.count { return false }
                    pi += 1; si += 1
                } else {
                    if si >= string.count || string[si] != p { return false }
                    pi += 1; si += 1
                }
            }
            return si == string.count
        }
    }

    // MARK: - Properties

    let entries: [HostEntry]

    // MARK: - Init

    init(path: String = "~/.ssh/config") {
        let expandedPath = path.hasPrefix("~")
            ? (FileManager.default.homeDirectoryForCurrentUser.path + path.dropFirst())
            : path
        guard let contents = try? String(contentsOfFile: expandedPath, encoding: .utf8) else {
            self.entries = []
            return
        }
        self.entries = SSHConfigParser.parse(contents)
    }

    init(contents: String) {
        self.entries = SSHConfigParser.parse(contents)
    }

    // MARK: - Resolution

    func resolveConfig(hostname: String) -> HostEntry {
        var result = HostEntry(patterns: [hostname])
        for entry in entries where entry.matches(hostname) {
            if result.hostname == nil, let v = entry.hostname { result.hostname = v }
            if result.port == nil, let v = entry.port { result.port = v }
            if result.user == nil, let v = entry.user { result.user = v }
            if result.identityFile == nil, let v = entry.identityFile { result.identityFile = v }
            if result.proxyJump == nil, let v = entry.proxyJump { result.proxyJump = v }
        }
        return result
    }

    // MARK: - Parsing

    private static func parse(_ contents: String) -> [HostEntry] {
        var entries: [HostEntry] = []
        var currentEntry: HostEntry?

        for rawLine in contents.components(separatedBy: "\n") {
            let commentStripped: String
            if let hashIdx = rawLine.firstIndex(of: "#") {
                commentStripped = String(rawLine[rawLine.startIndex..<hashIdx])
            } else {
                commentStripped = rawLine
            }
            let line = commentStripped.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }

            let (key, value) = splitKeyValue(line)
            let keyLower = key.lowercased()

            switch keyLower {
            case "host":
                if let entry = currentEntry { entries.append(entry) }
                let patterns = value.components(separatedBy: .whitespaces)
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
                currentEntry = HostEntry(patterns: patterns)
            case "hostname":
                currentEntry?.hostname = value
            case "port":
                if let p = Int(value) { currentEntry?.port = p }
            case "user":
                currentEntry?.user = value
            case "identityfile":
                let expanded = value.hasPrefix("~")
                    ? (FileManager.default.homeDirectoryForCurrentUser.path + value.dropFirst())
                    : value
                currentEntry?.identityFile = expanded
            case "proxyjump":
                currentEntry?.proxyJump = value
            default:
                break
            }
        }

        if let entry = currentEntry { entries.append(entry) }
        return entries
    }

    private static func splitKeyValue(_ line: String) -> (String, String) {
        for (i, ch) in line.enumerated() {
            if ch == "=" || ch.isWhitespace {
                let key = String(line.prefix(i)).trimmingCharacters(in: .whitespaces)
                var rest = String(line.dropFirst(i + 1))
                if ch == "=" {
                    rest = rest.trimmingCharacters(in: .whitespaces)
                } else {
                    rest = rest.trimmingCharacters(in: .whitespaces)
                    if rest.hasPrefix("=") {
                        rest = String(rest.dropFirst()).trimmingCharacters(in: .whitespaces)
                    }
                }
                if rest.hasPrefix("\"") && rest.hasSuffix("\"") && rest.count >= 2 {
                    rest = String(rest.dropFirst().dropLast())
                }
                return (key, rest)
            }
        }
        return (line, "")
    }
}

// MARK: - TerminalSSHSessionDetector

/// Detects whether an SSH process is running in the foreground of a given TTY.
///
/// Uses KERN_PROCARGS2 sysctl for exact argv (no ps truncation), and filters
/// to only foreground processes (pgid == tpgid).
enum TerminalSSHSessionDetector {
    struct ProcessSnapshot: Equatable {
        let pid: Int32
        let pgid: Int32
        let tpgid: Int32
        let tty: String
        let executableName: String
    }

    static func detect(forTTY ttyName: String) -> DetectedSSHSession? {
        let normalizedTTY = normalizeTTYName(ttyName)
        guard !normalizedTTY.isEmpty else { return nil }
        let processes = processSnapshots(forTTY: normalizedTTY)
        guard !processes.isEmpty else { return nil }

        var argumentsByPID: [Int32: [String]] = [:]
        for process in processes where isForegroundSSHProcess(process, ttyName: normalizedTTY) {
            if let args = commandLineArguments(forPID: process.pid) {
                argumentsByPID[process.pid] = args
            }
        }

        return detectForTesting(
            ttyName: normalizedTTY,
            processes: processes,
            argumentsByPID: argumentsByPID
        )
    }

    static func detectForTesting(
        ttyName: String,
        processes: [ProcessSnapshot],
        argumentsByPID: [Int32: [String]]
    ) -> DetectedSSHSession? {
        let normalizedTTY = normalizeTTYName(ttyName)
        guard !normalizedTTY.isEmpty else { return nil }

        let candidates = processes
            .filter { isForegroundSSHProcess($0, ttyName: normalizedTTY) }
            .sorted { lhs, rhs in
                if lhs.pid != rhs.pid { return lhs.pid > rhs.pid }
                return lhs.pgid > rhs.pgid
            }

        for candidate in candidates {
            guard let arguments = argumentsByPID[candidate.pid],
                  let session = parseSSHCommandLine(arguments) else {
                continue
            }
            return session
        }

        return nil
    }

    private static let psPath = "/bin/ps"
    private static let noArgumentFlags = Set("46AaCfGgKkMNnqsTtVvXxYy")
    private static let valueArgumentFlags = Set("BbcDEeFIiJLlmOopQRSWw")
    private static let filteredSSHOptionKeys: Set<String> = [
        "batchmode",
        "controlmaster",
        "controlpersist",
        "forkafterauthentication",
        "localcommand",
        "permitlocalcommand",
        "remotecommand",
        "requesttty",
        "sendenv",
        "sessiontype",
        "setenv",
        "stdioforward",
    ]

    private static func normalizeTTYName(_ ttyName: String) -> String {
        let trimmed = ttyName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        if let lastComponent = trimmed.split(separator: "/").last {
            return String(lastComponent)
        }
        return trimmed
    }

    private static func isForegroundSSHProcess(_ process: ProcessSnapshot, ttyName: String) -> Bool {
        normalizeTTYName(process.tty) == normalizeTTYName(ttyName) &&
            process.executableName == "ssh" &&
            process.pgid > 0 &&
            process.tpgid > 0 &&
            process.pgid == process.tpgid
    }

    private static func processSnapshots(forTTY ttyName: String) -> [ProcessSnapshot] {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: psPath)
        process.arguments = ["-ww", "-t", ttyName, "-o", "pid=,pgid=,tpgid=,tty=,ucomm="]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return []
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0,
              let output = String(data: data, encoding: .utf8) else {
            return []
        }

        return output
            .split(separator: "\n")
            .compactMap(parseProcessSnapshot)
    }

    private static func parseProcessSnapshot(_ line: Substring) -> ProcessSnapshot? {
        let parts = line.split(maxSplits: 4, whereSeparator: \.isWhitespace)
        guard parts.count == 5,
              let pid = Int32(parts[0]),
              let pgid = Int32(parts[1]),
              let tpgid = Int32(parts[2]) else {
            return nil
        }

        return ProcessSnapshot(
            pid: pid,
            pgid: pgid,
            tpgid: tpgid,
            tty: String(parts[3]),
            executableName: String(parts[4]).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        )
    }

    // MARK: - KERN_PROCARGS2

    static func commandLineArguments(forPID pid: Int32) -> [String]? {
        var mib = [CTL_KERN, KERN_PROCARGS2, pid]
        var size: size_t = 0
        guard sysctl(&mib, u_int(mib.count), nil, &size, nil, 0) == 0, size > 4 else {
            return nil
        }

        var buffer = [UInt8](repeating: 0, count: size)
        let success = buffer.withUnsafeMutableBytes { rawBuffer in
            sysctl(&mib, u_int(mib.count), rawBuffer.baseAddress, &size, nil, 0) == 0
        }
        guard success else { return nil }

        return parseKernProcArgs(Array(buffer.prefix(Int(size))))
    }

    private static func parseKernProcArgs(_ bytes: [UInt8]) -> [String]? {
        guard bytes.count > 4 else { return nil }

        var argcRaw: Int32 = 0
        withUnsafeMutableBytes(of: &argcRaw) { rawBuffer in
            rawBuffer.copyBytes(from: bytes.prefix(4))
        }
        let argc = Int(Int32(littleEndian: argcRaw))
        guard argc > 0 else { return nil }

        // Skip executable path (null-terminated), then skip null padding
        var index = 4
        while index < bytes.count, bytes[index] != 0 {
            index += 1
        }
        while index < bytes.count, bytes[index] == 0 {
            index += 1
        }

        var arguments: [String] = []
        while index < bytes.count, arguments.count < argc {
            let start = index
            while index < bytes.count, bytes[index] != 0 {
                index += 1
            }
            guard let argument = String(bytes: bytes[start..<index], encoding: .utf8) else {
                return nil
            }
            arguments.append(argument)
            while index < bytes.count, bytes[index] == 0 {
                index += 1
            }
        }

        return arguments.count == argc ? arguments : nil
    }

    // MARK: - SSH Command-Line Parsing

    private static func parseSSHCommandLine(_ arguments: [String]) -> DetectedSSHSession? {
        guard !arguments.isEmpty else { return nil }

        var index = 0
        if let executable = arguments.first?.split(separator: "/").last,
           executable == "ssh" {
            index = 1
        }

        var destination: String?
        var port: Int?
        var identityFile: String?
        var configFile: String?
        var jumpHost: String?
        var controlPath: String?
        var loginName: String?
        var useIPv4 = false
        var useIPv6 = false
        var forwardAgent = false
        var compressionEnabled = false
        var sshOptions: [String] = []

        func consumeValue(_ value: String, for option: Character) -> Bool {
            let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedValue.isEmpty else { return false }

            switch option {
            case "p":
                guard let parsedPort = Int(trimmedValue) else { return false }
                port = parsedPort
                return true
            case "i":
                identityFile = trimmedValue
                return true
            case "F":
                configFile = trimmedValue
                return true
            case "J":
                jumpHost = trimmedValue
                return true
            case "S":
                controlPath = trimmedValue
                return true
            case "l":
                loginName = trimmedValue
                return true
            case "o":
                return consumeSSHOption(
                    trimmedValue,
                    port: &port,
                    identityFile: &identityFile,
                    controlPath: &controlPath,
                    jumpHost: &jumpHost,
                    loginName: &loginName,
                    sshOptions: &sshOptions
                )
            default:
                return valueArgumentFlags.contains(option)
            }
        }

        while index < arguments.count {
            let argument = arguments[index]
            if argument == "--" {
                index += 1
                if index < arguments.count {
                    destination = arguments[index]
                }
                break
            }
            if !argument.hasPrefix("-") || argument == "-" {
                destination = argument
                break
            }

            if argument.count > 2,
               let option = argument.dropFirst().first,
               valueArgumentFlags.contains(option) {
                guard consumeValue(String(argument.dropFirst(2)), for: option) else { return nil }
                index += 1
                continue
            }

            if argument.count == 2,
               let optionCharacter = argument.dropFirst().first,
               valueArgumentFlags.contains(optionCharacter) {
                let nextIndex = index + 1
                guard nextIndex < arguments.count,
                      consumeValue(arguments[nextIndex], for: optionCharacter) else {
                    return nil
                }
                index += 2
                continue
            }

            let flags = Array(argument.dropFirst())
            guard !flags.isEmpty, flags.allSatisfy({ noArgumentFlags.contains($0) }) else {
                return nil
            }
            for flag in flags {
                switch flag {
                case "4":
                    useIPv4 = true
                    useIPv6 = false
                case "6":
                    useIPv6 = true
                    useIPv4 = false
                case "A":
                    forwardAgent = true
                case "C":
                    compressionEnabled = true
                default:
                    break
                }
            }
            index += 1
        }

        guard let destination else { return nil }
        let finalDestination = resolveDestination(destination, loginName: loginName)
        guard !finalDestination.isEmpty else { return nil }

        return DetectedSSHSession(
            destination: finalDestination,
            port: port,
            identityFile: identityFile,
            configFile: configFile,
            jumpHost: jumpHost,
            controlPath: controlPath,
            useIPv4: useIPv4,
            useIPv6: useIPv6,
            forwardAgent: forwardAgent,
            compressionEnabled: compressionEnabled,
            sshOptions: sshOptions
        )
    }

    private static func consumeSSHOption(
        _ option: String,
        port: inout Int?,
        identityFile: inout String?,
        controlPath: inout String?,
        jumpHost: inout String?,
        loginName: inout String?,
        sshOptions: inout [String]
    ) -> Bool {
        let trimmed = option.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let key = sshOptionKey(trimmed)
        let value = sshOptionValue(trimmed)

        switch key {
        case "port":
            if let value, let parsedPort = Int(value) {
                port = parsedPort
                return true
            }
            return false
        case "identityfile":
            if let value, !value.isEmpty {
                identityFile = value
                return true
            }
            return false
        case "controlpath":
            if let value, !value.isEmpty {
                controlPath = value
                return true
            }
            return false
        case "proxyjump":
            if let value, !value.isEmpty {
                jumpHost = value
                return true
            }
            return false
        case "user":
            if let value, !value.isEmpty {
                loginName = value
                return true
            }
            return false
        case let key? where filteredSSHOptionKeys.contains(key):
            return true
        case .some, .none:
            sshOptions.append(trimmed)
            return true
        }
    }

    private static func resolveDestination(_ destination: String, loginName: String?) -> String {
        let trimmedDestination = destination.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedDestination.isEmpty else { return "" }
        guard let loginName = loginName?.trimmingCharacters(in: .whitespacesAndNewlines),
              !loginName.isEmpty,
              !trimmedDestination.contains("@") else {
            return trimmedDestination
        }
        return "\(loginName)@\(trimmedDestination)"
    }

    // MARK: - SSH Option Helpers (internal for DetectedSSHSession)

    static func hasSSHOptionKey(_ options: [String], key: String) -> Bool {
        let loweredKey = key.lowercased()
        return options.contains { optionKey($0) == loweredKey }
    }

    static func scpRemoteDestination(_ destination: String) -> String {
        let trimmedDestination = destination.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedDestination.isEmpty else { return destination }

        let parts = trimmedDestination.split(separator: "@", maxSplits: 1, omittingEmptySubsequences: false)
        let userPart: String?
        let hostPart: String
        if parts.count == 2 {
            userPart = String(parts[0])
            hostPart = String(parts[1])
        } else {
            userPart = nil
            hostPart = trimmedDestination
        }

        guard shouldBracketIPv6Literal(hostPart) else {
            return trimmedDestination
        }

        let bracketedHost = "[\(hostPart)]"
        if let userPart {
            return "\(userPart)@\(bracketedHost)"
        }
        return bracketedHost
    }

    private static func optionKey(_ option: String) -> String? {
        let trimmed = option.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return trimmed
            .split(whereSeparator: { $0 == "=" || $0.isWhitespace })
            .first
            .map(String.init)?
            .lowercased()
    }

    private static func sshOptionKey(_ option: String) -> String? {
        let trimmed = option.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return trimmed
            .split(whereSeparator: { $0 == "=" || $0.isWhitespace })
            .first
            .map(String.init)?
            .lowercased()
    }

    private static func sshOptionValue(_ option: String) -> String? {
        let trimmed = option.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let equalIndex = trimmed.firstIndex(of: "=") {
            let value = trimmed[trimmed.index(after: equalIndex)...].trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? nil : value
        }

        let parts = trimmed.split(maxSplits: 1, whereSeparator: \.isWhitespace)
        guard parts.count == 2 else { return nil }
        let value = String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private static func shouldBracketIPv6Literal(_ host: String) -> Bool {
        let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmedHost.isEmpty &&
            trimmedHost.contains(":") &&
            !trimmedHost.hasPrefix("[") &&
            !trimmedHost.hasSuffix("]")
    }
}

// MARK: - TerminalSession Extension

extension TerminalSession {
    /// The TTY device path for this session's shell process, if detectable.
    var ttyPath: String? {
        return _ttyPath
    }

    /// Set by shell integration via the NAMU_TTY env variable or direct assignment.
    var _ttyPath: String? {
        get { environmentVariables["NAMU_TTY"] }
    }

    /// Detect the current SSH session for this terminal, if any.
    func detectSSHSession() -> DetectedSSHSession? {
        guard let tty = ttyPath else { return nil }
        let normalizedTTY: String
        if tty.hasPrefix("/dev/") {
            normalizedTTY = String(tty.dropFirst("/dev/".count))
        } else {
            normalizedTTY = tty
        }
        return TerminalSSHSessionDetector.detect(forTTY: normalizedTTY)
    }
}
