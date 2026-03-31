import Foundation
import Network

// MARK: - HTTP Request Rewriter

/// Rewrites HTTP request headers so that requests targeting the loopback alias host
/// are redirected to `localhost` before being forwarded.
///
/// Note: This rewriter only modifies HTTP headers (up to \r\n\r\n), not the message body.
/// Content-Length describes the body size and is not affected by header byte count changes.
enum RemoteLoopbackHTTPRequestRewriter {
    private static let headerDelimiter = Data([0x0d, 0x0a, 0x0d, 0x0a])
    private static let canonicalLoopbackHost = "localhost"
    private static let requestLineMethods = ["GET", "POST", "PUT", "PATCH", "DELETE", "HEAD", "OPTIONS", "TRACE", "PRI"]

    static func rewriteIfNeeded(data: Data, aliasHost: String) -> Data {
        rewriteIfNeeded(data: data, aliasHost: aliasHost, allowIncompleteHeadersAtEOF: false)
    }

    static func rewriteIfNeeded(data: Data, aliasHost: String, allowIncompleteHeadersAtEOF: Bool) -> Data {
        let headerData: Data
        let remainder: Data

        if let headerRange = data.range(of: headerDelimiter) {
            headerData = Data(data[..<headerRange.upperBound])
            remainder = Data(data[headerRange.upperBound...])
        } else if allowIncompleteHeadersAtEOF {
            headerData = data
            remainder = Data()
        } else {
            return data
        }

        guard let headerText = String(data: headerData, encoding: .utf8) else { return data }

        var lines = headerText.components(separatedBy: "\r\n")
        guard !lines.isEmpty else { return data }
        guard let requestLineIndex = lines.firstIndex(where: { !$0.isEmpty }) else { return data }
        guard requestLineLooksHTTP(lines[requestLineIndex]) else { return data }

        let rewrittenRequestLine = rewriteRequestLine(lines[requestLineIndex], aliasHost: aliasHost)
        if rewrittenRequestLine != lines[requestLineIndex] {
            lines[requestLineIndex] = rewrittenRequestLine
        }

        for index in (requestLineIndex + 1)..<lines.count where !lines[index].isEmpty {
            lines[index] = rewriteHeaderLine(lines[index], aliasHost: aliasHost)
        }

        let rewrittenHeaderText = lines.joined(separator: "\r\n")
        guard rewrittenHeaderText != headerText else { return data }
        return Data(rewrittenHeaderText.utf8) + remainder
    }

    private static func requestLineLooksHTTP(_ requestLine: String) -> Bool {
        let trimmed = requestLine.trimmingCharacters(in: .whitespacesAndNewlines)
        let method = trimmed.split(separator: " ", maxSplits: 1).first.map(String.init)?.uppercased() ?? ""
        return requestLineMethods.contains(method)
    }

    private static func rewriteRequestLine(_ requestLine: String, aliasHost: String) -> String {
        let trimmed = requestLine.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.split(separator: " ", omittingEmptySubsequences: false)
        guard parts.count >= 3 else { return requestLine }

        var components = URLComponents(string: String(parts[1]))
        guard let host = components?.host,
              normalizeHost(host) == normalizeHost(aliasHost) else {
            return requestLine
        }
        components?.host = canonicalLoopbackHost
        guard let rewrittenURL = components?.string else { return requestLine }

        var rewritten = parts
        rewritten[1] = Substring(rewrittenURL)
        let leadingTrivia = requestLine.prefix { $0.isWhitespace || $0.isNewline }
        let trailingTrivia = String(requestLine.reversed().prefix { $0.isWhitespace || $0.isNewline }.reversed())
        return String(leadingTrivia) + rewritten.joined(separator: " ") + trailingTrivia
    }

    private static func rewriteHeaderLine(_ line: String, aliasHost: String) -> String {
        guard let colonIndex = line.firstIndex(of: ":") else { return line }
        let name = line[..<colonIndex].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let valueStart = line.index(after: colonIndex)
        let rawValue = line[valueStart...].trimmingCharacters(in: .whitespacesAndNewlines)

        switch name {
        case "host":
            guard let rewrittenHost = rewriteHostValue(rawValue, aliasHost: aliasHost) else { return line }
            return "\(line[..<valueStart]) \(rewrittenHost)"
        case "origin", "referer":
            guard let rewrittenURL = rewriteURLValue(rawValue, aliasHost: aliasHost) else { return line }
            return "\(line[..<valueStart]) \(rewrittenURL)"
        default:
            return line
        }
    }

    private static func rewriteHostValue(_ value: String, aliasHost: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if trimmed.hasPrefix("["),
           let closing = trimmed.firstIndex(of: "]") {
            let host = String(trimmed[trimmed.index(after: trimmed.startIndex)..<closing])
            guard normalizeHost(host) == normalizeHost(aliasHost) else { return nil }
            let remainder = String(trimmed[closing...].dropFirst())
            return canonicalLoopbackHost + remainder
        }

        if let colonIndex = trimmed.lastIndex(of: ":"), !trimmed[..<colonIndex].contains(":") {
            let host = String(trimmed[..<colonIndex])
            guard normalizeHost(host) == normalizeHost(aliasHost) else { return nil }
            return canonicalLoopbackHost + trimmed[colonIndex...]
        }

        guard normalizeHost(trimmed) == normalizeHost(aliasHost) else { return nil }
        return canonicalLoopbackHost
    }

    private static func rewriteURLValue(_ value: String, aliasHost: String) -> String? {
        var components = URLComponents(string: value)
        guard let host = components?.host,
              normalizeHost(host) == normalizeHost(aliasHost) else {
            return nil
        }
        components?.host = canonicalLoopbackHost
        return components?.string
    }

    /// Lowercases the host and strips trailing dots.
    static func normalizeHost(_ host: String) -> String {
        host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
    }
}

// MARK: - HTTP Request Stream Rewriter

struct RemoteLoopbackHTTPRequestStreamRewriter {
    private static let maxHeaderBytes = 64 * 1024
    private static let headerDelimiter = Data([0x0D, 0x0A, 0x0D, 0x0A])

    private let aliasHost: String
    private var pendingHeaderBytes = Data()
    private var hasForwardedHeaders = false

    init(aliasHost: String) {
        self.aliasHost = aliasHost
    }

    mutating func rewriteNextChunk(_ data: Data, eof: Bool) -> Data {
        guard !hasForwardedHeaders else { return data }

        pendingHeaderBytes.append(data)
        if pendingHeaderBytes.count > Self.maxHeaderBytes {
            hasForwardedHeaders = true
            let payload = pendingHeaderBytes
            pendingHeaderBytes = Data()
            return RemoteLoopbackHTTPRequestRewriter.rewriteIfNeeded(
                data: payload,
                aliasHost: aliasHost,
                allowIncompleteHeadersAtEOF: true
            )
        }

        guard pendingHeaderBytes.range(of: Self.headerDelimiter) != nil else {
            guard eof else { return Data() }
            hasForwardedHeaders = true
            let payload = pendingHeaderBytes
            pendingHeaderBytes = Data()
            return RemoteLoopbackHTTPRequestRewriter.rewriteIfNeeded(
                data: payload,
                aliasHost: aliasHost,
                allowIncompleteHeadersAtEOF: true
            )
        }

        hasForwardedHeaders = true
        let payload = pendingHeaderBytes
        pendingHeaderBytes = Data()
        return RemoteLoopbackHTTPRequestRewriter.rewriteIfNeeded(
            data: payload,
            aliasHost: aliasHost
        )
    }
}

// MARK: - HTTP Response Rewriter

enum RemoteLoopbackHTTPResponseRewriter {
    private static let headerDelimiter = Data([0x0d, 0x0a, 0x0d, 0x0a])
    private static let canonicalLoopbackHost = "localhost"

    static func rewriteIfNeeded(data: Data, aliasHost: String) -> Data {
        guard let headerRange = data.range(of: headerDelimiter) else { return data }
        let headerData = Data(data[..<headerRange.upperBound])
        guard let headerText = String(data: headerData, encoding: .utf8) else { return data }

        var lines = headerText.components(separatedBy: "\r\n")
        guard let statusLineIndex = lines.firstIndex(where: { !$0.isEmpty }) else { return data }
        guard lines[statusLineIndex].uppercased().hasPrefix("HTTP/") else { return data }

        for index in (statusLineIndex + 1)..<lines.count where !lines[index].isEmpty {
            lines[index] = rewriteHeaderLine(lines[index], aliasHost: aliasHost)
        }

        let rewrittenHeaderText = lines.joined(separator: "\r\n")
        guard rewrittenHeaderText != headerText else { return data }
        return Data(rewrittenHeaderText.utf8) + data[headerRange.upperBound...]
    }

    private static func rewriteHeaderLine(_ line: String, aliasHost: String) -> String {
        guard let colonIndex = line.firstIndex(of: ":") else { return line }
        let name = line[..<colonIndex].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let valueStart = line.index(after: colonIndex)
        let rawValue = line[valueStart...].trimmingCharacters(in: .whitespacesAndNewlines)

        switch name {
        case "location", "content-location", "origin", "referer", "access-control-allow-origin":
            guard let rewrittenURL = rewriteURLValue(rawValue, aliasHost: aliasHost) else { return line }
            return "\(line[..<valueStart]) \(rewrittenURL)"
        case "set-cookie":
            guard let rewrittenCookie = rewriteCookieValue(rawValue, aliasHost: aliasHost) else { return line }
            return "\(line[..<valueStart]) \(rewrittenCookie)"
        default:
            return line
        }
    }

    private static func rewriteURLValue(_ value: String, aliasHost: String) -> String? {
        var components = URLComponents(string: value)
        guard let host = components?.host,
              RemoteLoopbackHTTPRequestRewriter.normalizeHost(host)
                == RemoteLoopbackHTTPRequestRewriter.normalizeHost(canonicalLoopbackHost) else {
            return nil
        }
        components?.host = aliasHost
        return components?.string
    }

    private static func rewriteCookieValue(_ value: String, aliasHost: String) -> String? {
        let parts = value.split(separator: ";", omittingEmptySubsequences: false).map(String.init)
        guard !parts.isEmpty else { return nil }

        var didRewrite = false
        let rewrittenParts = parts.map { part -> String in
            let trimmed = part.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.lowercased().hasPrefix("domain=") else { return part }
            let domainValue = String(trimmed.dropFirst("domain=".count))
            guard RemoteLoopbackHTTPRequestRewriter.normalizeHost(domainValue)
                    == RemoteLoopbackHTTPRequestRewriter.normalizeHost(canonicalLoopbackHost) else {
                return part
            }
            didRewrite = true
            let leadingWhitespace = part.prefix { $0.isWhitespace }
            return "\(leadingWhitespace)Domain=\(aliasHost)"
        }

        return didRewrite ? rewrittenParts.joined(separator: ";") : nil
    }
}

// MARK: - Proxy Tunnel

final class RemoteDaemonProxyTunnel {

    // MARK: - ProxySession

    private final class ProxySession {
        private static let maxHandshakeBytes = 64 * 1024
        private static let remoteLoopbackProxyAliasHost = "namu-loopback.localtest.me"

        private enum HandshakeProtocol {
            case undecided
            case socks5
            case connect
        }

        private enum SocksStage {
            case greeting
            case request
        }

        private struct SocksRequest {
            let host: String
            let port: Int
            let command: UInt8
            let consumedBytes: Int
        }

        let id = UUID()

        private let connection: NWConnection
        private let rpcClient: RemoteDaemonRPCClient
        private let queue: DispatchQueue
        private let onClose: (UUID) -> Void

        private var isClosed = false
        private var protocolKind: HandshakeProtocol = .undecided
        private var socksStage: SocksStage = .greeting
        private var handshakeBuffer = Data()
        private var streamID: String?
        private var localInputEOF = false
        private var rewritesLoopbackHTTPHeaders = false
        private var loopbackRequestHeaderRewriter: RemoteLoopbackHTTPRequestStreamRewriter?
        private var pendingRemoteHTTPHeaderBytes = Data()
        private var hasForwardedRemoteHTTPHeaders = false

        init(
            connection: NWConnection,
            rpcClient: RemoteDaemonRPCClient,
            queue: DispatchQueue,
            onClose: @escaping (UUID) -> Void
        ) {
            self.connection = connection
            self.rpcClient = rpcClient
            self.queue = queue
            self.onClose = onClose
        }

        func start() {
            connection.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .failed(let error):
                    self.close(reason: "proxy client connection failed: \(error)")
                case .cancelled:
                    self.close(reason: nil)
                default:
                    break
                }
            }
            connection.start(queue: queue)
            receiveNext()

            // M1: Handshake timeout — if the session has not established a remote
            // stream within 30 seconds, close it to prevent slow-loris style hangs.
            queue.asyncAfter(deadline: .now() + 30.0) { [weak self] in
                guard let self, !self.isClosed, self.streamID == nil else { return }
                self.close(reason: "proxy handshake timed out")
            }
        }

        func stop() {
            close(reason: nil)
        }

        private func receiveNext() {
            guard !isClosed else { return }
            connection.receive(minimumIncompleteLength: 1, maximumLength: 32768) { [weak self] data, _, isComplete, error in
                guard let self, !self.isClosed else { return }

                if let data, !data.isEmpty {
                    if self.streamID == nil {
                        if self.handshakeBuffer.count + data.count > Self.maxHandshakeBytes {
                            self.close(reason: "proxy handshake exceeded \(Self.maxHandshakeBytes) bytes")
                            return
                        }
                        self.handshakeBuffer.append(data)
                        self.processHandshakeBuffer()
                    } else {
                        self.forwardToRemote(data, eof: isComplete)
                    }
                }

                if isComplete {
                    // Treat local EOF as a half-close: keep remote read loop alive so we can
                    // drain upstream response bytes (for example curl closing write-side after
                    // sending an HTTP request through SOCKS/CONNECT).
                    self.localInputEOF = true
                    if self.streamID != nil, data?.isEmpty ?? true {
                        self.forwardToRemote(Data(), eof: true, allowAfterEOF: true)
                    }
                    if self.streamID == nil {
                        self.close(reason: nil)
                    }
                    return
                }
                if let error {
                    self.close(reason: "proxy client receive error: \(error)")
                    return
                }

                self.receiveNext()
            }
        }

        private func processHandshakeBuffer() {
            guard !isClosed else { return }
            while streamID == nil {
                switch protocolKind {
                case .undecided:
                    guard let first = handshakeBuffer.first else { return }
                    protocolKind = (first == 0x05) ? .socks5 : .connect
                case .socks5:
                    if !processSocksHandshakeStep() { return }
                case .connect:
                    if !processConnectHandshakeStep() { return }
                }
            }
        }

        private func processSocksHandshakeStep() -> Bool {
            switch socksStage {
            case .greeting:
                guard handshakeBuffer.count >= 2 else { return false }
                let methodCount = Int(handshakeBuffer[1])
                let total = 2 + methodCount
                guard handshakeBuffer.count >= total else { return false }

                let methods = [UInt8](handshakeBuffer[2..<total])
                handshakeBuffer = Data(handshakeBuffer.dropFirst(total))
                socksStage = .request

                if !methods.contains(0x00) {
                    sendAndClose(Data([0x05, 0xFF]))
                    return false
                }
                // M9: SOCKS5 authentication: method 0x00 (NO AUTHENTICATION REQUIRED).
                // This is safe because the listener is bound exclusively to 127.0.0.1,
                // so only local processes can connect. Adding username/password auth
                // (RFC 1929, method 0x02) would provide defense-in-depth but is not
                // required for the current threat model.
                sendLocal(Data([0x05, 0x00]))
                return true

            case .request:
                let request: SocksRequest
                do {
                    guard let parsed = try parseSocksRequest(from: handshakeBuffer) else { return false }
                    request = parsed
                } catch {
                    sendAndClose(Data([0x05, 0x01, 0x00, 0x01, 0, 0, 0, 0, 0, 0]))
                    return false
                }

                let pending = handshakeBuffer.count > request.consumedBytes
                    ? Data(handshakeBuffer[request.consumedBytes...])
                    : Data()
                handshakeBuffer = Data()
                guard request.command == 0x01 else {
                    sendAndClose(Data([0x05, 0x07, 0x00, 0x01, 0, 0, 0, 0, 0, 0]))
                    return false
                }

                openRemoteStream(
                    host: request.host,
                    port: request.port,
                    successResponse: Data([0x05, 0x00, 0x00, 0x01, 0, 0, 0, 0, 0, 0]),
                    failureResponse: Data([0x05, 0x05, 0x00, 0x01, 0, 0, 0, 0, 0, 0]),
                    pendingPayload: pending
                )
                return false
            }
        }

        private func parseSocksRequest(from data: Data) throws -> SocksRequest? {
            let bytes = [UInt8](data)
            guard bytes.count >= 4 else { return nil }
            guard bytes[0] == 0x05 else {
                throw NSError(domain: "namu.remote.proxy", code: 1, userInfo: [NSLocalizedDescriptionKey: "invalid SOCKS version"])
            }

            let command = bytes[1]
            let addressType = bytes[3]
            var cursor = 4
            let host: String

            switch addressType {
            case 0x01:
                guard bytes.count >= cursor + 4 + 2 else { return nil }
                let octets = bytes[cursor..<(cursor + 4)].map { String($0) }
                host = octets.joined(separator: ".")
                cursor += 4

            case 0x03:
                guard bytes.count >= cursor + 1 else { return nil }
                let length = Int(bytes[cursor])
                cursor += 1
                guard bytes.count >= cursor + length + 2 else { return nil }
                let hostData = Data(bytes[cursor..<(cursor + length)])
                host = String(data: hostData, encoding: .utf8) ?? ""
                cursor += length

            case 0x04:
                guard bytes.count >= cursor + 16 + 2 else { return nil }
                var address = in6_addr()
                withUnsafeMutableBytes(of: &address) { target in
                    for i in 0..<16 {
                        target[i] = bytes[cursor + i]
                    }
                }
                var text = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
                let pointer = withUnsafePointer(to: &address) {
                    inet_ntop(AF_INET6, UnsafeRawPointer($0), &text, socklen_t(INET6_ADDRSTRLEN))
                }
                host = pointer != nil ? String(cString: text) : ""
                cursor += 16

            default:
                throw NSError(domain: "namu.remote.proxy", code: 2, userInfo: [NSLocalizedDescriptionKey: "invalid SOCKS address type"])
            }

            guard !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw NSError(domain: "namu.remote.proxy", code: 3, userInfo: [NSLocalizedDescriptionKey: "empty SOCKS host"])
            }
            guard bytes.count >= cursor + 2 else { return nil }
            let port = Int(UInt16(bytes[cursor]) << 8 | UInt16(bytes[cursor + 1]))
            cursor += 2

            guard port > 0 && port <= 65535 else {
                throw NSError(domain: "namu.remote.proxy", code: 4, userInfo: [NSLocalizedDescriptionKey: "invalid SOCKS port"])
            }

            return SocksRequest(host: host, port: port, command: command, consumedBytes: cursor)
        }

        private func processConnectHandshakeStep() -> Bool {
            let marker = Data([0x0D, 0x0A, 0x0D, 0x0A])
            guard let headerRange = handshakeBuffer.range(of: marker) else { return false }

            let headerData = Data(handshakeBuffer[..<headerRange.upperBound])
            let pending = headerRange.upperBound < handshakeBuffer.count
                ? Data(handshakeBuffer[headerRange.upperBound...])
                : Data()
            handshakeBuffer = Data()
            guard let headerText = String(data: headerData, encoding: .utf8) else {
                sendAndClose(Self.httpResponse(status: "400 Bad Request"))
                return false
            }

            let firstLine = headerText.components(separatedBy: "\r\n").first ?? ""
            let parts = firstLine.split(whereSeparator: \.isWhitespace).map(String.init)
            guard parts.count >= 2, parts[0].uppercased() == "CONNECT" else {
                sendAndClose(Self.httpResponse(status: "400 Bad Request"))
                return false
            }

            guard let (host, port) = Self.parseConnectAuthority(parts[1]) else {
                sendAndClose(Self.httpResponse(status: "400 Bad Request"))
                return false
            }

            openRemoteStream(
                host: host,
                port: port,
                successResponse: Self.httpResponse(status: "200 Connection Established", closeAfterResponse: false),
                failureResponse: Self.httpResponse(status: "502 Bad Gateway", closeAfterResponse: true),
                pendingPayload: pending
            )
            return false
        }

        private static let blockedHosts: Set<String> = [
            "169.254.169.254",  // AWS/GCP/Azure metadata
            "100.100.100.200",  // Alibaba metadata
            "fd00:ec2::254",    // AWS IPv6 metadata
        ]

        private func isBlockedTarget(host: String) -> Bool {
            let normalized = host.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            return Self.blockedHosts.contains(normalized)
        }

        private func openRemoteStream(
            host: String,
            port: Int,
            successResponse: Data,
            failureResponse: Data,
            pendingPayload: Data
        ) {
            guard !isClosed else { return }
            guard !isBlockedTarget(host: host) else {
                sendAndClose(failureResponse)
                return
            }
            do {
                rewritesLoopbackHTTPHeaders =
                    RemoteLoopbackHTTPRequestRewriter.normalizeHost(host)
                    == RemoteLoopbackHTTPRequestRewriter.normalizeHost(Self.remoteLoopbackProxyAliasHost)
                loopbackRequestHeaderRewriter = rewritesLoopbackHTTPHeaders
                    ? RemoteLoopbackHTTPRequestStreamRewriter(aliasHost: Self.remoteLoopbackProxyAliasHost)
                    : nil
                pendingRemoteHTTPHeaderBytes = Data()
                hasForwardedRemoteHTTPHeaders = false
                let targetHost = Self.normalizedProxyTargetHost(host)
                let streamID = try rpcClient.openStream(host: targetHost, port: port)
                self.streamID = streamID
                try rpcClient.attachStream(streamID: streamID, queue: queue) { [weak self] event in
                    self?.handleRemoteStreamEvent(streamID: streamID, event: event)
                }
                connection.send(content: successResponse, completion: .contentProcessed { [weak self] error in
                    guard let self else { return }
                    if let error {
                        self.close(reason: "proxy client send error: \(error)")
                        return
                    }
                    if !pendingPayload.isEmpty {
                        self.forwardToRemote(pendingPayload, allowAfterEOF: true)
                    }
                })
            } catch {
                sendAndClose(failureResponse)
            }
        }

        private func forwardToRemote(_ data: Data, eof: Bool = false, allowAfterEOF: Bool = false) {
            guard !isClosed else { return }
            guard !localInputEOF || allowAfterEOF else { return }
            guard let streamID else { return }
            do {
                let outgoingData: Data
                if rewritesLoopbackHTTPHeaders {
                    outgoingData = loopbackRequestHeaderRewriter?.rewriteNextChunk(data, eof: eof) ?? data
                } else {
                    outgoingData = data
                }
                guard !outgoingData.isEmpty else { return }
                try rpcClient.writeStream(streamID: streamID, data: outgoingData)
            } catch {
                close(reason: "proxy.write failed: \(error.localizedDescription)")
            }
        }

        private func handleRemoteStreamEvent(
            streamID: String,
            event: RemoteDaemonRPCClient.StreamEvent
        ) {
            guard !isClosed else { return }
            guard self.streamID == streamID else { return }

            switch event {
            case .data(let data):
                forwardRemotePayloadToLocal(data, eof: false)
            case .eof(let data):
                forwardRemotePayloadToLocal(data, eof: true)
            case .error(let detail):
                close(reason: "proxy.stream failed: \(detail)")
            }
        }

        private func forwardRemotePayloadToLocal(_ data: Data, eof: Bool) {
            let localData = rewriteRemoteResponseIfNeeded(data, eof: eof)
            if !localData.isEmpty {
                connection.send(content: localData, completion: .contentProcessed { [weak self] error in
                    guard let self else { return }
                    if let error {
                        self.close(reason: "proxy client send error: \(error)")
                        return
                    }
                    if eof {
                        self.close(reason: nil)
                    }
                })
                return
            }

            if eof {
                close(reason: nil)
            }
        }

        // M2: Cap matching the request-side rewriter to prevent unbounded buffering.
        private static let maxResponseHeaderBytes = 64 * 1024

        private func rewriteRemoteResponseIfNeeded(_ data: Data, eof: Bool) -> Data {
            guard rewritesLoopbackHTTPHeaders else { return data }
            guard !data.isEmpty else { return data }
            guard !hasForwardedRemoteHTTPHeaders else { return data }

            pendingRemoteHTTPHeaderBytes.append(data)

            // M2: If the buffer exceeds the cap, forward as-is without rewriting.
            if pendingRemoteHTTPHeaderBytes.count > Self.maxResponseHeaderBytes {
                hasForwardedRemoteHTTPHeaders = true
                let payload = pendingRemoteHTTPHeaderBytes
                pendingRemoteHTTPHeaderBytes = Data()
                return payload
            }

            let marker = Data([0x0D, 0x0A, 0x0D, 0x0A])
            guard pendingRemoteHTTPHeaderBytes.range(of: marker) != nil else {
                guard eof else { return Data() }
                hasForwardedRemoteHTTPHeaders = true
                let payload = pendingRemoteHTTPHeaderBytes
                pendingRemoteHTTPHeaderBytes = Data()
                return payload
            }

            hasForwardedRemoteHTTPHeaders = true
            let payload = pendingRemoteHTTPHeaderBytes
            pendingRemoteHTTPHeaderBytes = Data()
            return RemoteLoopbackHTTPResponseRewriter.rewriteIfNeeded(
                data: payload,
                aliasHost: Self.remoteLoopbackProxyAliasHost
            )
        }

        private func close(reason: String?) {
            guard !isClosed else { return }
            isClosed = true

            let streamID = self.streamID
            self.streamID = nil

            if let streamID {
                rpcClient.closeStream(streamID: streamID)
            }
            connection.cancel()
            onClose(id)
        }

        private func sendLocal(_ data: Data) {
            guard !isClosed else { return }
            connection.send(content: data, completion: .contentProcessed { [weak self] error in
                guard let self else { return }
                if let error {
                    self.close(reason: "proxy client send error: \(error)")
                }
            })
        }

        private func sendAndClose(_ data: Data) {
            guard !isClosed else { return }
            connection.send(content: data, completion: .contentProcessed { [weak self] _ in
                self?.close(reason: nil)
            })
        }

        private static func parseConnectAuthority(_ authority: String) -> (host: String, port: Int)? {
            let trimmed = authority.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }

            if trimmed.hasPrefix("[") {
                guard let closing = trimmed.firstIndex(of: "]") else { return nil }
                let host = String(trimmed[trimmed.index(after: trimmed.startIndex)..<closing])
                let portStart = trimmed.index(after: closing)
                guard portStart < trimmed.endIndex, trimmed[portStart] == ":" else { return nil }
                let portString = String(trimmed[trimmed.index(after: portStart)...])
                guard let port = Int(portString), port > 0, port <= 65535 else { return nil }
                return (host, port)
            }

            guard let colon = trimmed.lastIndex(of: ":") else { return nil }
            let host = String(trimmed[..<colon])
            let portString = String(trimmed[trimmed.index(after: colon)...])
            guard !host.isEmpty else { return nil }
            guard let port = Int(portString), port > 0, port <= 65535 else { return nil }
            return (host, port)
        }

        private static func normalizedProxyTargetHost(_ host: String) -> String {
            let normalized = RemoteLoopbackHTTPRequestRewriter.normalizeHost(host)
            // Resolve the loopback alias back to true loopback before dialing from the remote daemon.
            if normalized == remoteLoopbackProxyAliasHost {
                return "127.0.0.1"
            }
            return host
        }

        private static func httpResponse(status: String, closeAfterResponse: Bool = true) -> Data {
            let sanitizedStatus = status
                .replacingOccurrences(of: "\r", with: "")
                .replacingOccurrences(of: "\n", with: "")
            var text = "HTTP/1.1 \(sanitizedStatus)\r\nProxy-Agent: namu\r\n"
            if closeAfterResponse {
                text += "Connection: close\r\n"
            }
            text += "\r\n"
            return Data(text.utf8)
        }
    }

    // MARK: - RemoteDaemonProxyTunnel properties

    private let rpcClient: RemoteDaemonRPCClient
    private let aliasHost: String
    private let localPort: Int
    private let queue = DispatchQueue(
        label: "com.namu.remote-ssh.daemon-tunnel.\(UUID().uuidString)",
        qos: .utility
    )

    private var listener: NWListener?
    private var sessions: [UUID: ProxySession] = [:]
    private var isStopped = false

    /// The port the listener is bound to, or nil if the tunnel is not running.
    var port: Int? {
        queue.sync {
            guard let listener, !isStopped else { return nil }
            guard case .ready = listener.state else { return nil }
            return listener.port.map { Int($0.rawValue) }
        }
    }

    // MARK: - Init

    init(
        rpcClient: RemoteDaemonRPCClient,
        aliasHost: String = "namu-loopback.localtest.me",
        port: Int = 0
    ) {
        self.rpcClient = rpcClient
        self.aliasHost = aliasHost
        self.localPort = port
    }

    // MARK: - Lifecycle

    /// Start the listener and return the allocated port.
    @discardableResult
    func start() throws -> Int {
        var setupError: Error?
        var listener: NWListener?

        queue.sync {
            guard !isStopped else {
                setupError = NSError(domain: "namu.remote.proxy", code: 20, userInfo: [
                    NSLocalizedDescriptionKey: "proxy tunnel already stopped",
                ])
                return
            }
            do {
                listener = try Self.makeLoopbackListener(port: localPort)
            } catch {
                setupError = error
            }
        }

        if let setupError {
            throw setupError
        }

        guard let listener else {
            throw NSError(domain: "namu.remote.proxy", code: 20, userInfo: [
                NSLocalizedDescriptionKey: "proxy tunnel already stopped",
            ])
        }

        let sema = DispatchSemaphore(value: 0)
        let stateLock = NSLock()
        var listenerPort: NWEndpoint.Port?
        var listenerError: Error?

        listener.newConnectionHandler = { [weak self] connection in
            self?.queue.async {
                self?.acceptConnectionLocked(connection)
            }
        }
        listener.stateUpdateHandler = { [weak self] state in
            // Signal the semaphore for terminal states before routing to the queue.
            switch state {
            case .ready:
                stateLock.lock()
                listenerPort = listener.port
                stateLock.unlock()
                sema.signal()
            case .failed(let error):
                stateLock.lock()
                listenerError = error
                stateLock.unlock()
                sema.signal()
            case .cancelled:
                sema.signal()
            default:
                break
            }
            self?.queue.async {
                self?.handleListenerStateLocked(state)
            }
        }

        queue.sync {
            self.listener = listener
            listener.start(queue: queue)
        }

        // Wait outside any queue to avoid blocking the dispatch queue the
        // listener's stateUpdateHandler fires on.
        _ = sema.wait(timeout: .now() + 5.0)

        stateLock.lock()
        let capturedPort = listenerPort
        let capturedError = listenerError
        stateLock.unlock()

        if let capturedError {
            queue.sync { stopLocked() }
            throw capturedError
        }

        guard let capturedPort else {
            queue.sync { stopLocked() }
            throw NSError(domain: "namu.remote.proxy", code: 22, userInfo: [
                NSLocalizedDescriptionKey: "proxy listener failed to become ready",
            ])
        }

        return Int(capturedPort.rawValue)
    }

    /// Stop the tunnel and cancel all active sessions.
    func stop() {
        queue.sync {
            stopLocked()
        }
    }

    // MARK: - Private

    private func handleListenerStateLocked(_ state: NWListener.State) {
        guard !isStopped else { return }
        switch state {
        case .failed(let error):
            stopLocked()
            _ = error  // logged by caller if needed
        default:
            break
        }
    }

    private func acceptConnectionLocked(_ connection: NWConnection) {
        guard !isStopped else {
            connection.cancel()
            return
        }

        let session = ProxySession(
            connection: connection,
            rpcClient: rpcClient,
            queue: queue
        ) { [weak self] id in
            self?.queue.async {
                self?.sessions.removeValue(forKey: id)
            }
        }
        sessions[session.id] = session
        session.start()
    }

    private func stopLocked() {
        guard !isStopped else { return }
        isStopped = true

        listener?.stateUpdateHandler = nil
        listener?.newConnectionHandler = nil
        listener?.cancel()
        listener = nil

        let activeSessions = sessions.values
        sessions.removeAll()
        for session in activeSessions {
            session.stop()
        }
    }

    private static func makeLoopbackListener(port: Int) throws -> NWListener {
        guard port >= 0 && port <= 65535 else {
            throw NSError(domain: "namu.remote.proxy", code: 21, userInfo: [
                NSLocalizedDescriptionKey: "invalid local proxy port \(port)",
            ])
        }
        let nwPort = NWEndpoint.Port(rawValue: UInt16(port)) ?? .any
        let tcpOptions = NWProtocolTCP.Options()
        tcpOptions.noDelay = true
        let parameters = NWParameters(tls: nil, tcp: tcpOptions)
        parameters.allowLocalEndpointReuse = true
        parameters.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host("127.0.0.1"), port: nwPort)
        return try NWListener(using: parameters)
    }
}
