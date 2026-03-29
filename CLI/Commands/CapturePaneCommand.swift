import Foundation

struct CapturePaneCommand: CLICommand {
    static let name = "capture-pane"
    static let aliases = ["capturep"]
    static let help = "Capture the contents of a pane"

    private let client: SocketClient
    private let parsed: TmuxParsedArguments

    init(client: SocketClient, args: [String]) throws {
        self.client = client
        self.parsed = try parseTmuxArguments(
            args,
            valueFlags: ["-E", "-S", "-t"],
            boolFlags: ["-J", "-N", "-p"]
        )
    }

    func run() throws {
        let target = try tmuxResolveSurfaceTarget(parsed.value("-t"), client: client)
        var params: [String: Any] = [
            "workspace_id": target.workspaceId,
            "surface_id": target.surfaceId,
            "scrollback": true
        ]
        if let start = parsed.value("-S"), let lines = Int(start), lines < 0 {
            params["lines"] = abs(lines)
        }
        let payload = try client.sendV2(method: "surface.read_text", params: params)
        let text = (payload["text"] as? String) ?? ""
        if parsed.hasFlag("-p") {
            print(text)
        } else {
            var store = loadTmuxCompatStore()
            store.buffers["default"] = text
            try saveTmuxCompatStore(store)
        }
    }
}
