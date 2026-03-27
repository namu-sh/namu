import Foundation
import CryptoKit

// MARK: - MessageSigning

/// HMAC-SHA256 signing and verification for Gateway <-> Desktop messages.
/// The pairing token (256-bit) is used as the HMAC key.
public enum MessageSigning {

    // MARK: - Sign

    /// Sign a message body using the pairing token as HMAC-SHA256 key.
    /// Returns a base64-encoded signature string.
    public static func sign(messageData: Data, tokenData: Data) -> String {
        let key = SymmetricKey(data: tokenData)
        let mac = HMAC<SHA256>.authenticationCode(for: messageData, using: key)
        return Data(mac).base64EncodedString()
    }

    /// Sign a UTF-8 string message.
    public static func sign(message: String, tokenData: Data) -> String? {
        guard let data = message.data(using: .utf8) else { return nil }
        return sign(messageData: data, tokenData: tokenData)
    }

    // MARK: - Verify

    /// Verify a base64-encoded HMAC-SHA256 signature against message data.
    public static func verify(messageData: Data, signature: String, tokenData: Data) -> Bool {
        guard let sigData = Data(base64Encoded: signature) else { return false }
        let key = SymmetricKey(data: tokenData)
        let mac = HMAC<SHA256>.authenticationCode(for: messageData, using: key)
        // Constant-time comparison via CryptoKit
        return HMAC<SHA256>.isValidAuthenticationCode(
            sigData,
            authenticating: messageData,
            using: key
        )
    }

    /// Verify using a UTF-8 string message.
    public static func verify(message: String, signature: String, tokenData: Data) -> Bool {
        guard let data = message.data(using: .utf8) else { return false }
        return verify(messageData: data, signature: signature, tokenData: tokenData)
    }
}

// MARK: - Signed Message Envelope

/// A message envelope carrying a payload and its HMAC signature.
public struct SignedMessage: Codable {
    public let payload: Data
    public let signature: String
    public let timestamp: TimeInterval  // Unix epoch, used for replay protection

    public init(payload: Data, tokenData: Data) {
        let ts = Date().timeIntervalSince1970
        self.payload = payload
        self.timestamp = ts
        // Sign payload + timestamp together to prevent replay attacks
        var combined = payload
        withUnsafeBytes(of: ts) { combined.append(contentsOf: $0) }
        self.signature = MessageSigning.sign(messageData: combined, tokenData: tokenData)
    }

    /// Verify this envelope. Rejects messages older than `maxAge` seconds (default 30s).
    public func verify(tokenData: Data, maxAge: TimeInterval = 30) -> Bool {
        let age = Date().timeIntervalSince1970 - timestamp
        guard age >= 0, age <= maxAge else { return false }
        var combined = payload
        withUnsafeBytes(of: timestamp) { combined.append(contentsOf: $0) }
        return MessageSigning.verify(messageData: combined, signature: signature, tokenData: tokenData)
    }

    /// Decode and verify in one step. Returns nil if verification fails.
    public func verifiedPayload(tokenData: Data, maxAge: TimeInterval = 30) -> Data? {
        verify(tokenData: tokenData, maxAge: maxAge) ? payload : nil
    }
}
