import Foundation

struct SplitWindowCommand: CLICommand {
    static let name = "split-window"
    static let aliases = ["splitw"]
    static let help = "Split the current pane"

    private let client: SocketClient
    private let parsed: TmuxParsedArguments

    init(client: SocketClient, args: [String]) throws {
        self.client = client
        self.parsed = try parseTmuxArguments(
            args,
            valueFlags: ["-c", "-F", "-l", "-t"],
            boolFlags: ["-P", "-b", "-d", "-h", "-v"]
        )
    }

    func run() throws {
        var target = try tmuxResolveSurfaceTarget(parsed.value("-t"), client: client)
        var direction: String
        if parsed.hasFlag("-h") {
            direction = parsed.hasFlag("-b") ? "left" : "right"
        } else {
            direction = parsed.hasFlag("-b") ? "up" : "down"
        }

        // MainVerticalState: route splits into the right column when active.
        if let callerSurface = tmuxCallerSurfaceHandle(),
           let callerWorkspace = tmuxCallerWorkspaceHandle(),
           let wsId = try? tmuxResolveWorkspaceTarget(callerWorkspace, client: client) {
            let store = loadTmuxCompatStore()
            if let mvState = store.mainVerticalLayouts[wsId],
               let lastColumn = mvState.lastColumnSurfaceId {
                target = (wsId, nil, lastColumn)
                direction = "down"
            } else {
                target = (wsId, nil, callerSurface)
                direction = "right"
            }
        }

        let focusNewPane = !parsed.hasFlag("-d")
        let created = try client.sendV2(method: "surface.split", params: [
            "workspace_id": target.workspaceId,
            "surface_id": target.surfaceId,
            "direction": direction,
            "focus": focusNewPane
        ])
        guard let surfaceId = created["surface_id"] as? String else {
            throw CLIError(message: "surface.split did not return surface_id")
        }
        let paneId = created["pane_id"] as? String

        // Track the newly created pane for main-vertical layout.
        do {
            var updatedStore = loadTmuxCompatStore()
            updatedStore.lastSplitSurface[target.workspaceId] = surfaceId
            if updatedStore.mainVerticalLayouts[target.workspaceId] != nil {
                updatedStore.mainVerticalLayouts[target.workspaceId]?.lastColumnSurfaceId = surfaceId
            } else if direction == "right", let callerSurface = tmuxCallerSurfaceHandle() {
                updatedStore.mainVerticalLayouts[target.workspaceId] = MainVerticalState(
                    mainSurfaceId: callerSurface,
                    lastColumnSurfaceId: surfaceId
                )
            }
            try saveTmuxCompatStore(updatedStore)
        }

        if let text = tmuxShellCommandText(commandTokens: parsed.positional, cwd: parsed.value("-c")) {
            _ = try client.sendV2(method: "surface.send_text", params: [
                "workspace_id": target.workspaceId,
                "surface_id": surfaceId,
                "text": text
            ])
        }
        if parsed.hasFlag("-P") {
            let context = try tmuxFormatContext(
                workspaceId: target.workspaceId,
                paneId: paneId,
                surfaceId: surfaceId,
                client: client
            )
            let fallback = context["pane_id"] ?? surfaceId
            print(tmuxRenderFormat(parsed.value("-F"), context: context, fallback: fallback))
        }
    }
}
