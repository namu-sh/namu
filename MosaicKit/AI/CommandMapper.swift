import Foundation

// MARK: - CommandMapper

/// Builds the system prompt and LLM tool definitions from the socket command set.
/// Each registered socket command is mapped to exactly one LLM Tool.
struct CommandMapper: Sendable {

    // MARK: - System Prompt

    /// Build the system prompt, injecting the current context snapshot.
    static func systemPrompt(context: ContextSnapshot) -> String {
        """
        You are Mosaic AI, a terminal control assistant built into the Mosaic terminal multiplexer.
        Your job is to interpret natural language instructions from the user and translate them into
        precise socket commands that control workspaces, panes, and terminal sessions.

        Rules:
        - Always use the tool calls provided to execute actions. Do not describe actions — perform them.
        - For ambiguous requests (e.g. "check the logs" when multiple panes exist), ask a clarifying question before acting.
        - For batch operations (e.g. "split pane and run npm test"), emit multiple sequential tool calls.
        - For read-only queries (e.g. "show me all workspaces"), use list/status tools and summarize the result.
        - Never guess pane or workspace IDs — always derive them from the context below.
        - If a command fails, report the error clearly and suggest next steps.

        Current workspace state:
        \(context.compactDescription())
        """
    }

    // MARK: - Tool Definitions

    /// The full set of LLM tools corresponding to socket commands.
    static var allTools: [Tool] {
        workspaceTools + paneTools + surfaceTools + systemTools
    }

    // MARK: Workspace tools

    private static var workspaceTools: [Tool] {
        [
            Tool(
                name: "workspace_list",
                description: "List all workspaces with their IDs, titles, and selection state.",
                inputSchema: ["type": "object", "properties": [:] as [String: Any], "required": [] as [String]]
            ),
            Tool(
                name: "workspace_create",
                description: "Create a new workspace with an optional title.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "title": ["type": "string", "description": "Workspace title"] as [String: Any]
                    ] as [String: Any],
                    "required": [] as [String]
                ]
            ),
            Tool(
                name: "workspace_delete",
                description: "Delete a workspace by ID. Requires at least one other workspace to remain.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "id": ["type": "string", "description": "UUID of the workspace to delete"] as [String: Any]
                    ] as [String: Any],
                    "required": ["id"]
                ]
            ),
            Tool(
                name: "workspace_select",
                description: "Switch to (select) a workspace by ID.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "id": ["type": "string", "description": "UUID of the workspace to select"] as [String: Any]
                    ] as [String: Any],
                    "required": ["id"]
                ]
            ),
            Tool(
                name: "workspace_rename",
                description: "Rename a workspace.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "id": ["type": "string", "description": "UUID of the workspace"] as [String: Any],
                        "title": ["type": "string", "description": "New title"] as [String: Any]
                    ] as [String: Any],
                    "required": ["id", "title"]
                ]
            ),
        ]
    }

    // MARK: Pane tools

    private static var paneTools: [Tool] {
        [
            Tool(
                name: "pane_split",
                description: "Split an existing pane into two, adding a new terminal pane as a sibling.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "pane_id": ["type": "string", "description": "UUID of the pane to split"] as [String: Any],
                        "direction": ["type": "string", "enum": ["horizontal", "vertical"], "description": "Split direction"] as [String: Any]
                    ] as [String: Any],
                    "required": ["pane_id", "direction"]
                ]
            ),
            Tool(
                name: "pane_close",
                description: "Close a pane by ID.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "pane_id": ["type": "string", "description": "UUID of the pane to close"] as [String: Any]
                    ] as [String: Any],
                    "required": ["pane_id"]
                ]
            ),
            Tool(
                name: "pane_focus",
                description: "Give keyboard focus to a specific pane.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "pane_id": ["type": "string", "description": "UUID of the pane to focus"] as [String: Any]
                    ] as [String: Any],
                    "required": ["pane_id"]
                ]
            ),
            Tool(
                name: "pane_send_keys",
                description: "Send a string of keystrokes to a pane (as if the user typed them). Use '\\n' for Enter.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "pane_id": ["type": "string", "description": "UUID of the target pane"] as [String: Any],
                        "keys": ["type": "string", "description": "Text/keystrokes to send"] as [String: Any]
                    ] as [String: Any],
                    "required": ["pane_id", "keys"]
                ]
            ),
            Tool(
                name: "pane_read_screen",
                description: "Read the last N lines of terminal output from a pane.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "pane_id": ["type": "string", "description": "UUID of the target pane"] as [String: Any],
                        "lines": ["type": "integer", "description": "Number of lines to return (default 50)", "default": 50] as [String: Any]
                    ] as [String: Any],
                    "required": ["pane_id"]
                ]
            ),
        ]
    }

    // MARK: Surface tools

    private static var surfaceTools: [Tool] {
        [
            Tool(
                name: "surface_send_text",
                description: "Send raw text to a surface (pane) without pressing Enter.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "surface_id": ["type": "string", "description": "UUID of the target surface/pane"] as [String: Any],
                        "text": ["type": "string", "description": "Text to send"] as [String: Any]
                    ] as [String: Any],
                    "required": ["surface_id", "text"]
                ]
            ),
            Tool(
                name: "surface_list",
                description: "List all surfaces (panes) across all workspaces with their IDs and states.",
                inputSchema: ["type": "object", "properties": [:] as [String: Any], "required": [] as [String]]
            ),
        ]
    }

    // MARK: System tools

    private static var systemTools: [Tool] {
        [
            Tool(
                name: "system_status",
                description: "Get the current status of Mosaic (version, uptime, connected clients).",
                inputSchema: ["type": "object", "properties": [:] as [String: Any], "required": [] as [String]]
            ),
        ]
    }

    // MARK: - Tool → JSON-RPC method mapping

    /// Map an LLM tool name to the corresponding JSON-RPC method string.
    static func rpcMethod(for toolName: String) -> String? {
        let mapping: [String: String] = [
            "workspace_list":    "workspace.list",
            "workspace_create":  "workspace.create",
            "workspace_delete":  "workspace.delete",
            "workspace_select":  "workspace.select",
            "workspace_rename":  "workspace.rename",
            "pane_split":        "pane.split",
            "pane_close":        "pane.close",
            "pane_focus":        "pane.focus",
            "pane_send_keys":    "pane.send_keys",
            "pane_read_screen":  "pane.read_screen",
            "surface_send_text": "surface.send_text",
            "surface_list":      "surface.list",
            "system_status":     "system.status",
        ]
        return mapping[toolName]
    }

    /// Convert tool input `[String: Any]` to `JSONRPCParams`.
    static func params(from input: [String: Any]) -> JSONRPCParams {
        let values = input.mapValues { JSONRPCValue(anyValue: $0) }
        return .object(values)
    }
}

// MARK: - JSONRPCValue convenience init

private extension JSONRPCValue {
    init(anyValue: Any) {
        switch anyValue {
        case let b as Bool:   self = .bool(b)
        case let i as Int:    self = .int(i)
        case let d as Double: self = .double(d)
        case let s as String: self = .string(s)
        case let arr as [Any]:
            self = .array(arr.map { JSONRPCValue(anyValue: $0) })
        case let obj as [String: Any]:
            self = .object(obj.mapValues { JSONRPCValue(anyValue: $0) })
        default:
            self = .string("\(anyValue)")
        }
    }
}
