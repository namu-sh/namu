import Foundation

// MARK: - Connection & Daemon State

/// High-level connection state for a remote workspace session.
enum RemoteConnectionState: String, Equatable {
    case disconnected
    case connecting
    case connected
    case error
}

/// State of the remote daemon process on the SSH host.
enum RemoteDaemonState: String, Equatable {
    case unavailable
    case bootstrapping
    case ready
    case error
}

/// Detailed daemon status including capabilities and version.
struct RemoteDaemonStatus: Equatable {
    var state: RemoteDaemonState = .unavailable
    var detail: String?
    var version: String?
    var name: String?
    var capabilities: [String] = []
    var remotePath: String?

    func payload() -> [String: Any] {
        [
            "state": state.rawValue,
            "detail": detail ?? NSNull(),
            "version": version ?? NSNull(),
            "name": name ?? NSNull(),
            "capabilities": capabilities,
            "remote_path": remotePath ?? NSNull(),
        ]
    }
}

// MARK: - Configuration

/// All parameters needed to establish a remote workspace connection.
struct RemoteConfiguration: Equatable {
    let destination: String
    let port: Int?
    let identityFile: String?
    let sshOptions: [String]
    let localProxyPort: Int?
    let relayPort: Int?
    let relayID: String?
    let relayToken: String?
    let localSocketPath: String?
    let terminalStartupCommand: String?

    /// Human-readable target, e.g. "user@host" or "user@host:2222".
    /// IPv6 addresses are bracketed: "[::1]:2222".
    var displayTarget: String {
        guard let port else { return destination }
        if destination.contains(":") {
            return "[\(destination)]:\(port)"
        }
        return "\(destination):\(port)"
    }

    /// Stable key for the proxy broker — identical targets with the same SSH
    /// options share a single proxy tunnel.
    var proxyBrokerTransportKey: String {
        let normalizedDestination = destination.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedPort = port.map(String.init) ?? ""
        let normalizedIdentity = identityFile?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let normalizedLocalProxyPort = localProxyPort.map(String.init) ?? ""
        let normalizedOptions = Self.proxyBrokerSSHOptions(sshOptions).joined(separator: "\u{1f}")
        return [normalizedDestination, normalizedPort, normalizedIdentity, normalizedOptions, normalizedLocalProxyPort]
            .joined(separator: "\u{1e}")
    }

    private static func proxyBrokerSSHOptions(_ options: [String]) -> [String] {
        options.compactMap { option in
            let trimmed = option.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            return trimmed
        }.filter { option in
            proxyBrokerSSHOptionKey(option) != "controlpath"
        }
    }

    private static func proxyBrokerSSHOptionKey(_ option: String) -> String? {
        let trimmed = option.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return trimmed
            .split(whereSeparator: { $0 == "=" || $0.isWhitespace })
            .first
            .map(String.init)?
            .lowercased()
    }
}

// MARK: - Daemon Manifest (Binary Distribution)

/// Manifest describing available daemon binaries for each platform.
/// Embedded in Info.plist at build time via `NamuRemoteDaemonManifestJSON`.
struct RemoteDaemonManifest: Decodable, Equatable {
    struct Entry: Decodable, Equatable {
        let goOS: String
        let goArch: String
        let assetName: String
        let downloadURL: String
        let sha256: String
    }

    let schemaVersion: Int
    let appVersion: String
    let releaseTag: String
    let releaseURL: String
    let checksumsAssetName: String
    let checksumsURL: String
    let entries: [Entry]

    func entry(goOS: String, goArch: String) -> Entry? {
        entries.first { $0.goOS == goOS && $0.goArch == goArch }
    }
}

// MARK: - Proxy

/// Local proxy endpoint address used by the browser to reach the remote host.
struct RemoteProxyEndpoint: Equatable {
    let host: String
    let port: Int
}

// MARK: - Errors

enum RemoteDropUploadError: Error {
    case unavailable
    case invalidFileURL
    case uploadFailed(String)
}
