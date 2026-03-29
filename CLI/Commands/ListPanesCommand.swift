import Foundation

struct ListPanesCommand: CLICommand {
    static let name = "list-panes"
    static let aliases = ["lsp"]
    static let help = "List panes in the current window"

    private let client: SocketClient
    private let parsed: TmuxParsedArguments

    init(client: SocketClient, args: [String]) throws {
        self.client = client
        self.parsed = try parseTmuxArguments(args, valueFlags: ["-F", "-t"], boolFlags: [])
    }

    func run() throws {
        let workspaceId = try tmuxResolveWorkspaceTarget(parsed.value("-t"), client: client)
        let payload = try client.sendV2(method: "pane.list", params: ["workspace_id": workspaceId])
        let panes = payload["panes"] as? [[String: Any]] ?? []
        for pane in panes {
            guard let paneId = pane["id"] as? String else { continue }
            let context = try tmuxFormatContext(workspaceId: workspaceId, paneId: paneId, client: client)
            let fallback = context["pane_id"] ?? paneId
            print(tmuxRenderFormat(parsed.value("-F"), context: context, fallback: fallback))
        }
    }
}
