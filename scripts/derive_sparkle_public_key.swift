#!/usr/bin/env swift
// Derives the Ed25519 public key from a Sparkle private key (base64-encoded).
// Usage: swift derive_sparkle_public_key.swift <base64-private-key>

import Foundation
import CryptoKit

guard CommandLine.arguments.count > 1 else {
    fputs("Usage: derive_sparkle_public_key.swift <base64-private-key>\n", stderr)
    exit(1)
}

let base64Key = CommandLine.arguments[1]
guard let keyData = Data(base64Encoded: base64Key) else {
    fputs("Error: invalid base64 input\n", stderr)
    exit(1)
}

let privateKey = try Curve25519.Signing.PrivateKey(rawRepresentation: keyData)
let publicKey = privateKey.publicKey
print(publicKey.rawRepresentation.base64EncodedString())
