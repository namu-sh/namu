import Foundation

/// Controls which clients may send commands over the IPC socket.
enum AccessMode: String, Codable, Sendable {
    /// All connections rejected.
    case off
    /// Only processes that are descendants of Namu (checked via PID ancestry).
    case localOnly
    /// Any connection from automation tooling (no password required, but marks
    /// the session as automation-context so the app can behave differently).
    case automation
    /// Challenge-response: client must send a password before commands are accepted.
    case password
    /// Any local connection accepted without checks.
    case allowAll
}

/// Per-connection access state managed by `AccessController`.
enum AccessState: Sendable {
    case pending        // not yet authenticated
    case authenticated  // allowed to send commands
    case denied         // permanently rejected
}

/// Evaluates whether a socket client is permitted to run commands.
final class AccessController: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var mode: AccessMode
    private var storedPassword: String?
    private let myPid: pid_t = getpid()

    init(mode: AccessMode = .localOnly, password: String? = nil) {
        self.mode = mode
        self.storedPassword = password
    }

    // MARK: - Configuration

    func update(mode: AccessMode, password: String? = nil) {
        lock.withLock {
            self.mode = mode
            self.storedPassword = password
        }
    }

    // MARK: - Connection Evaluation

    /// Called when a new client connects. Returns the initial `AccessState`.
    func evaluateNewConnection(clientSocket: Int32) -> AccessState {
        let currentMode = lock.withLock { mode }
        switch currentMode {
        case .off:
            return .denied
        case .allowAll, .automation:
            return .authenticated
        case .password:
            return .pending  // must authenticate with password first
        case .localOnly:
            return evaluateLocalOnly(clientSocket: clientSocket)
        }
    }

    /// For `.password` mode: check the supplied password and return new state.
    func authenticate(password: String) -> AccessState {
        let (currentMode, stored) = lock.withLock { (mode, storedPassword) }
        guard currentMode == .password else {
            // For non-password modes, authentication is not needed.
            return currentMode == .off ? .denied : .authenticated
        }
        guard let stored else { return .denied }
        // Constant-time comparison to prevent timing attacks
        let passwordBytes = Array(password.utf8)
        let storedBytes = Array(stored.utf8)
        guard passwordBytes.count == storedBytes.count else { return .denied }
        var diff: UInt8 = 0
        for (a, b) in zip(passwordBytes, storedBytes) { diff |= a ^ b }
        return diff == 0 ? .authenticated : .denied
    }

    // MARK: - Private

    private func evaluateLocalOnly(clientSocket: Int32) -> AccessState {
        guard let peerPid = getPeerPid(clientSocket) else { return .denied }
        return isDescendant(peerPid) ? .authenticated : .denied
    }

    private func getPeerPid(_ socket: Int32) -> pid_t? {
        var pid: pid_t = 0
        var pidSize = socklen_t(MemoryLayout<pid_t>.size)
        let result = getsockopt(socket, SOL_LOCAL, LOCAL_PEERPID, &pid, &pidSize)
        guard result == 0, pid > 0 else { return nil }
        return pid
    }

    private func isDescendant(_ pid: pid_t) -> Bool {
        var current = pid
        for _ in 0..<128 {
            if current == myPid { return true }
            if current <= 1 { return false }
            let parent = parentPid(of: current)
            if parent == current || parent < 0 { return false }
            current = parent
        }
        return false
    }

    private func parentPid(of pid: pid_t) -> pid_t {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.size
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0 else { return -1 }
        return info.kp_eproc.e_ppid
    }
}