import Foundation
import Network

// MARK: - CLI Argument Parsing

struct GatewayConfig {
    var port: UInt16 = 8080
    var telegramToken: String = ""
    var tlsCert: String? = nil
    var tlsKey: String? = nil
}

func parseArguments() -> GatewayConfig {
    var config = GatewayConfig()
    let args = CommandLine.arguments.dropFirst()
    var iterator = args.makeIterator()
    while let arg = iterator.next() {
        switch arg {
        case "--port":
            if let val = iterator.next(), let p = UInt16(val) {
                config.port = p
            }
        case "--telegram-token":
            if let val = iterator.next() {
                config.telegramToken = val
            }
        case "--tls-cert":
            if let val = iterator.next() {
                config.tlsCert = val
            }
        case "--tls-key":
            if let val = iterator.next() {
                config.tlsKey = val
            }
        default:
            fputs("Unknown argument: \(arg)\n", stderr)
        }
    }
    return config
}

// MARK: - Main Entry Point

let config = parseArguments()

guard !config.telegramToken.isEmpty else {
    fputs("Error: --telegram-token is required\n", stderr)
    exit(1)
}

print("[Gateway] Starting on port \(config.port)")
print("[Gateway] Telegram token: \(String(config.telegramToken.prefix(8)))...")

let sessionManager = SessionManager()
let auth = GatewayAuth()
let telegramChannel = TelegramChannel(token: config.telegramToken, sessionManager: sessionManager)
let router = WebhookRouter(
    telegramChannel: telegramChannel,
    sessionManager: sessionManager,
    auth: auth
)

// Start HTTP server (handles webhook + health + WebSocket upgrade)
let server = GatewayHTTPServer(port: config.port, router: router)
server.start()

print("[Gateway] Server started. Waiting for connections...")
RunLoop.main.run()
