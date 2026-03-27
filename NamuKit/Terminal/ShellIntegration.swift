import Foundation

/// OSC 133 shell integration parser.
///
/// Parses semantic zone markers emitted by the shell scripts in Resources/shell-integration/.
/// OSC 133 sequences have the form: ESC ] 133 ; <params> ESC \  (or BEL terminator)
///
/// Supported markers:
///   A           — prompt start
///   B           — command start (user is typing)
///   C           — command end / execution start
///   D[;code]    — command finished, optional exit code
///   P;k=v       — property (e.g. pwd, git_branch)
public enum ShellState: Equatable, Codable, Sendable {
    /// Shell is displaying a prompt, waiting for input.
    case prompt
    /// User has started typing a command.
    case commandInput
    /// Command is executing.
    case running(command: String)
    /// Command finished with an exit code.
    case idle(exitCode: Int?)
    /// Unknown / initialising.
    case unknown
}

public protocol ShellIntegrationDelegate: AnyObject {
    /// Called when the shell transitions to a new state.
    func shellIntegration(_ integration: ShellIntegration, didChangeState state: ShellState)
    /// Called when the working directory changes (OSC 133 P;k=cwd).
    func shellIntegration(_ integration: ShellIntegration, didChangePWD pwd: String)
    /// Called when the git branch changes (OSC 133 P;k=git_branch).
    func shellIntegration(_ integration: ShellIntegration, didChangeGitBranch branch: String?)
}

/// Parses OSC 133 byte sequences from terminal output.
///
/// Feed raw bytes via `process(_:)`. The parser accumulates partial sequences
/// across calls, so partial OSC sequences split across chunks are handled correctly.
public final class ShellIntegration {

    // MARK: - Public

    public weak var delegate: ShellIntegrationDelegate?

    /// Most recent shell state.
    public private(set) var state: ShellState = .unknown

    /// Most recent working directory (from OSC 133 P;k=cwd).
    public private(set) var currentPWD: String = ""

    /// Most recent git branch (from OSC 133 P;k=git_branch). Nil when not in a repo.
    public private(set) var gitBranch: String?

    public init() {}

    // MARK: - Feed

    /// Process a chunk of raw terminal output bytes.
    /// The parser looks for OSC 133 sequences and fires delegate callbacks.
    public func process(_ data: Data) {
        // Append to buffer and scan for complete OSC sequences.
        buffer.append(data)
        scanBuffer()
    }

    /// Convenience overload for String input.
    public func process(_ string: String) {
        guard let data = string.data(using: .utf8) else { return }
        process(data)
    }

    // MARK: - Private parsing state

    /// Accumulation buffer for partial OSC sequences.
    private var buffer = Data()

    /// We keep scanning until no more complete sequences are found.
    private func scanBuffer() {
        while let range = findNextOSC133(in: buffer) {
            let payload = extractPayload(from: buffer, oscRange: range)
            if let payload {
                handleOSC133(payload: payload)
            }
            // Remove everything up to and including the terminator.
            buffer.removeSubrange(..<range.upperBound)
        }

        // Prune buffer: keep only the tail that could be the start of an OSC.
        // If buffer is large and has no ESC, nothing useful is in it.
        if buffer.count > 4096 {
            if let escIdx = buffer.firstIndex(of: 0x1B) {
                buffer = buffer[escIdx...]
            } else {
                buffer.removeAll()
            }
        }
    }

    // ESC  ]  1  3  3  ;
    private static let oscPrefix: [UInt8] = [0x1B, 0x5D, 0x31, 0x33, 0x33, 0x3B]
    // ST terminator variants: ESC \ or BEL (0x07)
    private static let stTerminator: [UInt8] = [0x1B, 0x5C]
    private static let belTerminator: UInt8 = 0x07

    /// Returns the byte range of the first complete OSC 133 sequence found in `data`,
    /// including the terminator. Returns nil if no complete sequence is present.
    private func findNextOSC133(in data: Data) -> Range<Data.Index>? {
        let prefix = Self.oscPrefix
        guard data.count >= prefix.count else { return nil }

        var searchStart = data.startIndex
        while searchStart < data.endIndex {
            // Find ESC
            guard let escIdx = data[searchStart...].firstIndex(of: 0x1B) else { return nil }

            // Check for OSC prefix at escIdx
            let prefixEnd = data.index(escIdx, offsetBy: prefix.count, limitedBy: data.endIndex) ?? data.endIndex
            if prefixEnd <= data.endIndex && data[escIdx..<prefixEnd].elementsEqual(prefix) {
                // Found OSC 133 prefix. Now find terminator.
                let payloadStart = prefixEnd
                // Look for BEL or ESC \
                var idx = payloadStart
                while idx < data.endIndex {
                    if data[idx] == Self.belTerminator {
                        return escIdx..<data.index(after: idx)
                    }
                    if data[idx] == 0x1B {
                        let next = data.index(after: idx)
                        if next < data.endIndex && data[next] == 0x5C {
                            return escIdx..<data.index(after: next)
                        }
                    }
                    idx = data.index(after: idx)
                }
                // Incomplete sequence — stop scanning, leave in buffer.
                return nil
            }

            // Not an OSC 133 at this ESC; advance past it and keep looking.
            searchStart = data.index(after: escIdx)
        }
        return nil
    }

    /// Extract the payload string (between the semicolon and terminator) from an OSC 133 range.
    private func extractPayload(from data: Data, oscRange: Range<Data.Index>) -> String? {
        let prefix = Self.oscPrefix
        let payloadStart = data.index(oscRange.lowerBound, offsetBy: prefix.count)
        // Determine end: strip BEL or ESC\
        var payloadEnd = oscRange.upperBound
        // Step back over terminator
        let lastByte = data[data.index(before: payloadEnd)]
        if lastByte == Self.belTerminator {
            payloadEnd = data.index(before: payloadEnd)
        } else {
            // ESC \ — two bytes
            payloadEnd = data.index(payloadEnd, offsetBy: -2)
        }

        guard payloadStart < payloadEnd else { return nil }
        return String(data: data[payloadStart..<payloadEnd], encoding: .utf8)
    }

    // MARK: - OSC 133 semantics

    private func handleOSC133(payload: String) {
        // Payload format: <marker>[;<params>]
        // Split on first semicolon.
        let parts = payload.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false)
        let marker = parts.first.map(String.init) ?? ""
        let params = parts.count > 1 ? String(parts[1]) : ""

        switch marker {
        case "A":
            // Prompt start
            transition(to: .prompt)

        case "B":
            // Command input start
            transition(to: .commandInput)

        case "C":
            // Command execution start; params may carry the command text
            let cmd = params.isEmpty ? "" : params
            transition(to: .running(command: cmd))

        case "D":
            // Command done; optional exit code after semicolon
            let code: Int?
            if params.isEmpty {
                code = nil
            } else {
                code = Int(params)
            }
            transition(to: .idle(exitCode: code))

        case "P":
            // Property: k=v pairs separated by semicolons (already split above, so re-parse full payload)
            handleProperty(params: payload) // pass full payload for multi-pair parsing

        default:
            break
        }
    }

    private func handleProperty(params: String) {
        // Format: P;key=value[;key=value...]
        // The marker "P" was already stripped; `params` here is the full raw payload "P;k=v..."
        // We need to drop the leading "P;" part.
        var raw = params
        if raw.hasPrefix("P;") { raw = String(raw.dropFirst(2)) }

        for pair in raw.split(separator: ";") {
            let kv = pair.split(separator: "=", maxSplits: 1)
            guard kv.count == 2 else { continue }
            let key = String(kv[0])
            let value = String(kv[1])

            switch key {
            case "cwd", "pwd":
                let decoded = value.removingPercentEncoding ?? value
                if decoded != currentPWD {
                    currentPWD = decoded
                    delegate?.shellIntegration(self, didChangePWD: decoded)
                }
            case "git_branch":
                let branch: String? = value.isEmpty ? nil : value
                if branch != gitBranch {
                    gitBranch = branch
                    delegate?.shellIntegration(self, didChangeGitBranch: branch)
                }
            default:
                break
            }
        }
    }

    // MARK: - State transitions

    private func transition(to newState: ShellState) {
        guard newState != state else { return }
        state = newState
        delegate?.shellIntegration(self, didChangeState: newState)
    }
}
