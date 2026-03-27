import Foundation
import CryptoKit

// MARK: - Pairing Token

/// A 256-bit random pairing token used to authenticate desktop connections.
public struct PairingToken: Codable, Equatable {
    public let id: UUID
    public let tokenData: Data  // 32 bytes = 256 bits
    public let createdAt: Date
    public var label: String

    public init(label: String = "default") {
        self.id = UUID()
        self.tokenData = GatewayAuth.generateRandomToken()
        self.createdAt = Date()
        self.label = label
    }

    /// Hex-encoded token string for display / transport
    public var hexString: String {
        tokenData.map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - GatewayAuth

/// Manages paired desktop tokens on the Gateway side.
/// Tokens are stored in a JSON file in the Gateway's working directory.
public final class GatewayAuth {
    private let storePath: URL
    private var pairedTokens: [UUID: PairingToken] = [:]
    private let queue = DispatchQueue(label: "com.namu.gateway.auth", attributes: .concurrent)

    public init(storePath: URL? = nil) {
        if let path = storePath {
            self.storePath = path
        } else {
            let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
                .appendingPathComponent("NamuGateway", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            self.storePath = dir.appendingPathComponent("paired_tokens.json")
        }
        loadTokens()
    }

    // MARK: - Token Management

    /// Add a new pairing token (called when a desktop pairs for the first time).
    public func addToken(_ token: PairingToken) {
        queue.async(flags: .barrier) { [weak self] in
            self?.pairedTokens[token.id] = token
            self?.saveTokens()
        }
    }

    /// Validate a token data blob against stored tokens. Returns the matching token if valid.
    public func validate(tokenData: Data) -> PairingToken? {
        queue.sync {
            pairedTokens.values.first { $0.tokenData == tokenData }
        }
    }

    /// Validate a hex-encoded token string.
    public func validate(hexToken: String) -> PairingToken? {
        guard let data = Data(hexString: hexToken) else { return nil }
        return validate(tokenData: data)
    }

    /// Remove a token (revoke pairing).
    public func removeToken(id: UUID) {
        queue.async(flags: .barrier) { [weak self] in
            self?.pairedTokens.removeValue(forKey: id)
            self?.saveTokens()
        }
    }

    /// Rotate a token: replace old with new, preserving label.
    @discardableResult
    public func rotateToken(id: UUID) -> PairingToken? {
        queue.sync(flags: .barrier) { [weak self] () -> PairingToken? in
            guard let self = self, let old = self.pairedTokens[id] else { return nil }
            let new = PairingToken(label: old.label)
            self.pairedTokens.removeValue(forKey: id)
            self.pairedTokens[new.id] = new
            self.saveTokens()
            return new
        }
    }

    public var allTokens: [PairingToken] {
        queue.sync { Array(pairedTokens.values) }
    }

    // MARK: - Persistence

    private func loadTokens() {
        guard let data = try? Data(contentsOf: storePath),
              let tokens = try? JSONDecoder().decode([PairingToken].self, from: data) else {
            return
        }
        pairedTokens = Dictionary(uniqueKeysWithValues: tokens.map { ($0.id, $0) })
    }

    private func saveTokens() {
        let tokens = Array(pairedTokens.values)
        if let data = try? JSONEncoder().encode(tokens) {
            try? data.write(to: storePath, options: .atomic)
        }
    }

    // MARK: - Token Generation

    public static func generateRandomToken() -> Data {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes)
    }
}

// MARK: - Data Hex Helpers

extension Data {
    init?(hexString: String) {
        let hex = hexString
        guard hex.count % 2 == 0 else { return nil }
        var data = Data(capacity: hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            data.append(byte)
            index = next
        }
        self = data
    }
}
