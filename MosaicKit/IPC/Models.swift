import Foundation

// MARK: - JSON-RPC 2.0 Types

struct JSONRPCRequest: Codable, Sendable {
    let jsonrpc: String
    let id: JSONRPCId?
    let method: String
    let params: JSONRPCParams?

    init(id: JSONRPCId? = nil, method: String, params: JSONRPCParams? = nil) {
        self.jsonrpc = "2.0"
        self.id = id
        self.method = method
        self.params = params
    }
}

struct JSONRPCResponse: Codable, Sendable {
    let jsonrpc: String
    let id: JSONRPCId?
    let result: JSONRPCValue?
    let error: JSONRPCError?

    init(id: JSONRPCId?, result: JSONRPCValue) {
        self.jsonrpc = "2.0"
        self.id = id
        self.result = result
        self.error = nil
    }

    init(id: JSONRPCId?, error: JSONRPCError) {
        self.jsonrpc = "2.0"
        self.id = id
        self.result = nil
        self.error = error
    }

    static func success(id: JSONRPCId?, result: JSONRPCValue = .object([:])) -> JSONRPCResponse {
        JSONRPCResponse(id: id, result: result)
    }

    static func failure(id: JSONRPCId?, error: JSONRPCError) -> JSONRPCResponse {
        JSONRPCResponse(id: id, error: error)
    }
}

struct JSONRPCError: Codable, Sendable, Error {
    let code: Int
    let message: String
    let data: JSONRPCValue?

    init(code: Int, message: String, data: JSONRPCValue? = nil) {
        self.code = code
        self.message = message
        self.data = data
    }

    // Standard JSON-RPC error codes
    static let parseError = JSONRPCError(code: -32700, message: "Parse error")
    static let invalidRequest = JSONRPCError(code: -32600, message: "Invalid Request")
    static let methodNotFound = JSONRPCError(code: -32601, message: "Method not found")
    static let invalidParams = JSONRPCError(code: -32602, message: "Invalid params")
    static let internalError = JSONRPCError(code: -32603, message: "Internal error")

    static func methodNotFound(_ method: String) -> JSONRPCError {
        JSONRPCError(code: -32601, message: "Method not found: \(method)")
    }

    static func internalError(_ message: String) -> JSONRPCError {
        JSONRPCError(code: -32603, message: message)
    }

    static func accessDenied(_ reason: String = "Access denied") -> JSONRPCError {
        JSONRPCError(code: -32000, message: reason)
    }
}

// MARK: - JSONRPCId (string or number)

enum JSONRPCId: Codable, Sendable, Hashable {
    case string(String)
    case number(Int)

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let s = try? container.decode(String.self) {
            self = .string(s)
        } else if let n = try? container.decode(Int.self) {
            self = .number(n)
        } else {
            throw DecodingError.typeMismatch(
                JSONRPCId.self,
                .init(codingPath: decoder.codingPath, debugDescription: "id must be string or number")
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let s): try container.encode(s)
        case .number(let n): try container.encode(n)
        }
    }
}

// MARK: - JSONRPCParams (object or array)

enum JSONRPCParams: Codable, Sendable {
    case object([String: JSONRPCValue])
    case array([JSONRPCValue])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let obj = try? container.decode([String: JSONRPCValue].self) {
            self = .object(obj)
        } else if let arr = try? container.decode([JSONRPCValue].self) {
            self = .array(arr)
        } else {
            throw DecodingError.typeMismatch(
                JSONRPCParams.self,
                .init(codingPath: decoder.codingPath, debugDescription: "params must be object or array")
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .object(let obj): try container.encode(obj)
        case .array(let arr): try container.encode(arr)
        }
    }

    var object: [String: JSONRPCValue]? {
        if case .object(let obj) = self { return obj }
        return nil
    }
}

// MARK: - JSONRPCValue (any JSON value)

enum JSONRPCValue: Codable, Sendable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSONRPCValue])
    case object([String: JSONRPCValue])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let b = try? container.decode(Bool.self) {
            self = .bool(b)
        } else if let i = try? container.decode(Int.self) {
            self = .int(i)
        } else if let d = try? container.decode(Double.self) {
            self = .double(d)
        } else if let s = try? container.decode(String.self) {
            self = .string(s)
        } else if let arr = try? container.decode([JSONRPCValue].self) {
            self = .array(arr)
        } else if let obj = try? container.decode([String: JSONRPCValue].self) {
            self = .object(obj)
        } else {
            throw DecodingError.typeMismatch(
                JSONRPCValue.self,
                .init(codingPath: decoder.codingPath, debugDescription: "Unsupported JSON value")
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let b): try container.encode(b)
        case .int(let i): try container.encode(i)
        case .double(let d): try container.encode(d)
        case .string(let s): try container.encode(s)
        case .array(let arr): try container.encode(arr)
        case .object(let obj): try container.encode(obj)
        }
    }
}

// MARK: - JSONRPCNotification (outbound, no id)

struct JSONRPCNotification: Codable, Sendable {
    let jsonrpc: String
    let method: String
    let params: JSONRPCParams?

    init(method: String, params: JSONRPCParams? = nil) {
        self.jsonrpc = "2.0"
        self.method = method
        self.params = params
    }
}
