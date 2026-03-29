import Foundation

struct SelectPaneCommand: CLICommand {
    static let name = "select-pane"
    static let aliases = ["selectp"]
    static let help = "Select a pane"

    private let client: SocketClient
    private let parsed: TmuxParsedArguments

    init(client: SocketClient, args: [String]) throws {
        self.client = client
        self.parsed = try parseTmuxArguments(args, valueFlags: ["-P", "-T", "-t"], boolFlags: [])
    }

    func run() throws {
        if parsed.value("-P") != nil || parsed.value("-T") != nil { return }
        let target = try tmuxResolvePaneTarget(parsed.value("-t"), client: client)
        _ = try client.sendV2(method: "pane.focus", params: [
            "workspace_id": target.workspaceId,
            "pane_id": target.paneId
        ])
    }
}
