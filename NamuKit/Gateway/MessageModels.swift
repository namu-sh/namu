import Foundation

// MARK: - Message Source

enum MessageSource: String, Codable, Sendable {
    case telegram
    case local
}

// MARK: - GatewayMessage (base envelope)

/// Top-level envelope for all messages exchanged with the Gateway server.
struct GatewayMessage: Codable, Sendable {
    let type: String
    let id: String
    let timestamp: Date
    let source: MessageSource

    enum CodingKeys: String, CodingKey {
        case type, id, timestamp, source
    }
}

// MARK: - AlertMessage (desktop → gateway)

/// Sent from the desktop client to the Gateway when an AlertEngine rule fires.
struct AlertMessage: Codable, Sendable {
    let id: String
    let ruleName: String
    let event: String
    let summary: String
    let workspaceID: String?
    let firedAt: Date
    let source: MessageSource

    init(
        id: String = UUID().uuidString,
        ruleName: String,
        event: String,
        summary: String,
        workspaceID: String? = nil,
        firedAt: Date = Date(),
        source: MessageSource = .telegram
    ) {
        self.id = id
        self.ruleName = ruleName
        self.event = event
        self.summary = summary
        self.workspaceID = workspaceID
        self.firedAt = firedAt
        self.source = source
    }

    enum CodingKeys: String, CodingKey {
        case id, ruleName = "rule_name", event, summary
        case workspaceID = "workspace_id", firedAt = "fired_at", source
    }
}

// MARK: - InboundMessage (gateway → desktop)

/// A message received from the Gateway server, wrapping a command payload.
struct InboundMessage: Codable, Sendable {
    let id: String
    let type: InboundMessageType
    let payload: InboundPayload
    let source: MessageSource
    let receivedAt: Date

    enum CodingKeys: String, CodingKey {
        case id, type, payload, source, receivedAt = "received_at"
    }
}

enum InboundMessageType: String, Codable, Sendable {
    case command
    case confirmation
    case ping
}

/// Flexible payload that may carry a JSON-RPC-style command.
struct InboundPayload: Codable, Sendable {
    let method: String?
    let params: [String: AnyCodable]?
    let text: String?

    enum CodingKeys: String, CodingKey {
        case method, params, text
    }
}

// MARK: - OutboundMessage (desktop → gateway)

/// A message sent from the desktop to the Gateway server.
struct OutboundMessage: Codable, Sendable {
    let id: String
    let type: OutboundMessageType
    let payload: Data
    let sentAt: Date

    init(
        id: String = UUID().uuidString,
        type: OutboundMessageType,
        payload: Data,
        sentAt: Date = Date()
    ) {
        self.id = id
        self.type = type
        self.payload = payload
        self.sentAt = sentAt
    }

    enum CodingKeys: String, CodingKey {
        case id, type, payload, sentAt = "sent_at"
    }
}

enum OutboundMessageType: String, Codable, Sendable {
    case alert
    case pong
    case commandResult = "command_result"
}

// MARK: - CommandConfirmation (desktop → gateway)

/// Sent in response to a `requiresConfirmation` command received from the Gateway.
struct CommandConfirmation: Codable, Sendable {
    let id: String
    let commandID: String
    let approved: Bool
    let reason: String?
    let source: MessageSource
    let confirmedAt: Date

    init(
        id: String = UUID().uuidString,
        commandID: String,
        approved: Bool,
        reason: String? = nil,
        source: MessageSource = .telegram,
        confirmedAt: Date = Date()
    ) {
        self.id = id
        self.commandID = commandID
        self.approved = approved
        self.reason = reason
        self.source = source
        self.confirmedAt = confirmedAt
    }

    enum CodingKeys: String, CodingKey {
        case id
        case commandID = "command_id"
        case approved, reason, source
        case confirmedAt = "confirmed_at"
    }
}

// MARK: - AnyCodable helper

/// Lightweight type-erased Codable for heterogeneous JSON params.
struct AnyCodable: Codable, Sendable {
    let value: any Sendable

    init(_ value: any Sendable) {
        self.value = value
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            value = Optional<Int>.none as any Sendable
        } else if let b = try? container.decode(Bool.self) {
            value = b
        } else if let i = try? container.decode(Int.self) {
            value = i
        } else if let d = try? container.decode(Double.self) {
            value = d
        } else if let s = try? container.decode(String.self) {
            value = s
        } else {
            value = Optional<Int>.none as any Sendable
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch value {
        case let b as Bool:   try container.encode(b)
        case let i as Int:    try container.encode(i)
        case let d as Double: try container.encode(d)
        case let s as String: try container.encode(s)
        default:              try container.encodeNil()
        }
    }
}
