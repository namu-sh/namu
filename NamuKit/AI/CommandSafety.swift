import Foundation

// MARK: - CommandSource

enum CommandSource: Sendable {
    case local
    case external(channel: String)
}

// MARK: - SafetyLevel

enum SafetyLevel: Sendable {
    /// Read-only operations with no side effects.
    case safe
    /// Structural changes to workspace, panes, or configuration.
    case normal
    /// Input injection or process execution — can modify running state.
    case dangerous
}

// MARK: - SafetyResult

enum SafetyResult: Sendable {
    case allowed
    case requiresConfirmation(reason: String)
    case rejected(reason: String)
}

// MARK: - CommandSafety

final class CommandSafety: @unchecked Sendable {

    // MARK: Rate limiting state

    private let lock = NSLock()
    private var externalCommandTimestamps: [Date] = []
    private static let rateLimitWindow: TimeInterval = 60
    private static let rateLimitMax = 20

    // MARK: Destructive pattern detection

    private static let destructivePatterns: [String] = [
        "rm -rf",
        "sudo rm",
        "sudo kill",
        "mkfs",
        "dd if=",
        "chmod 777",
        "chmod -r 777",
        "> /dev/sd",
        "shutdown",
        "reboot",
        "kill -9",
        "pkill -9",
        ":(){ :|:& };:",
    ]

    // Patterns that require regex-style matching (pipe-to-shell)
    private static let destructiveRegexPatterns: [String] = [
        "curl.*\\|.*sh",
        "wget.*\\|.*sh",
    ]

    // MARK: - Classification

    /// Determine the safety level for a named command.
    /// Expects the method-only part of the RPC name (after the last ".").
    func safetyLevel(for command: String) -> SafetyLevel {
        switch command {
        // Read-only queries
        case "list", "status", "read_screen", "ping", "version",
             "capabilities", "get_url", "get_title",
             "identify", "current", "read_text", "claude_hook":
            return .safe

        // Structural mutations
        case "create", "delete", "select", "rename", "split", "close",
             "focus", "resize", "back", "forward", "reload", "navigate",
             "clear", "subscribe", "unsubscribe",
             "next", "previous", "last":
            return .normal

        // Input injection / process execution
        case "send_keys", "send_text", "send_key", "execute_js", "message":
            return .dangerous

        default:
            // Unknown commands default to dangerous to err on the side of safety.
            return .dangerous
        }
    }

    // MARK: - Validation

    /// Check whether a command may proceed given its source, and inspect payload
    /// for destructive shell patterns when the command is `send_keys`.
    ///
    /// - Parameters:
    ///   - command: The command name.
    ///   - payload: Optional string payload (e.g. keys to inject).
    ///   - source: Where the command originated.
    /// - Returns: A `SafetyResult` indicating whether to allow, confirm, or reject.
    func validate(command: String, payload: String? = nil, source: CommandSource) -> SafetyResult {
        // Rate-limit external sources first.
        if case .external = source {
            let allowed = checkRateLimit()
            if !allowed {
                let reason = "Rate limit exceeded: max \(Self.rateLimitMax) external commands per minute"
                log(command: command, source: source, level: .dangerous, result: .rejected(reason: reason))
                return .rejected(reason: reason)
            }
        }

        let level = safetyLevel(for: command)

        // Check for destructive shell patterns in any payload.
        if let payload = payload, level == .dangerous || command == "send_keys" {
            // Normalize: strip leading backslash escapes, collapse whitespace, lowercase
            var normalized = payload
            normalized = normalized.replacingOccurrences(of: "\\\\(\\S)", with: "$1",
                options: .regularExpression)
            normalized = normalized.replacingOccurrences(of: "\\s+", with: " ",
                options: .regularExpression)
            normalized = normalized.lowercased()

            for pattern in Self.destructivePatterns {
                if normalized.contains(pattern) {
                    let reason = "Destructive pattern detected: '\(pattern)'"
                    let result: SafetyResult = .requiresConfirmation(reason: reason)
                    log(command: command, source: source, level: level, result: result)
                    return result
                }
            }

            for pattern in Self.destructiveRegexPatterns {
                if normalized.range(of: pattern, options: .regularExpression) != nil {
                    let reason = "Destructive pattern detected: '\(pattern)'"
                    let result: SafetyResult = .requiresConfirmation(reason: reason)
                    log(command: command, source: source, level: level, result: result)
                    return result
                }
            }
        }

        let result: SafetyResult
        switch (source, level) {
        case (_, .safe):
            result = .allowed

        case (_, .normal):
            result = .allowed

        case (.local, .dangerous):
            // Local dangerous commands are allowed but logged.
            result = .allowed

        case (.external, .dangerous):
            result = .requiresConfirmation(reason: "Dangerous command '\(command)' from external source requires confirmation")
        }

        log(command: command, source: source, level: level, result: result)
        return result
    }

    // MARK: - Rate Limiting

    private func checkRateLimit() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let now = Date()
        let cutoff = now.addingTimeInterval(-Self.rateLimitWindow)
        externalCommandTimestamps = externalCommandTimestamps.filter { $0 > cutoff }
        guard externalCommandTimestamps.count < Self.rateLimitMax else { return false }
        externalCommandTimestamps.append(now)
        return true
    }

    // MARK: - Logging

    private func log(command: String, source: CommandSource, level: SafetyLevel, result: SafetyResult) {
        let sourceDesc: String
        switch source {
        case .local: sourceDesc = "local"
        case .external(let channel): sourceDesc = "external(\(channel))"
        }

        let levelDesc: String
        switch level {
        case .safe: levelDesc = "safe"
        case .normal: levelDesc = "normal"
        case .dangerous: levelDesc = "dangerous"
        }

        let resultDesc: String
        switch result {
        case .allowed: resultDesc = "allowed"
        case .requiresConfirmation(let reason): resultDesc = "requires_confirmation(\(reason))"
        case .rejected(let reason): resultDesc = "rejected(\(reason))"
        }

        print("[CommandSafety] command=\(command) source=\(sourceDesc) level=\(levelDesc) result=\(resultDesc)")
    }
}
