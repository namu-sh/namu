# Mosaic

**Terminal multiplexer for the agent era.**

Mosaic is a native macOS terminal built on [Ghostty](https://ghostty.org/) that organizes work into workspaces with split panes, exposes everything via a JSON-RPC socket API, and provides a built-in natural language control plane (Mosaic AI) accessible through Telegram.

<!-- screenshot placeholder -->
<!-- ![Mosaic screenshot](docs/assets/screenshot.png) -->

## Features

- **GPU-accelerated terminal** -- Ghostty-powered Metal rendering with sub-5ms typing latency
- **Workspaces and splits** -- Tabbed workspaces with arbitrary horizontal/vertical split nesting
- **Keyboard-driven** -- Full keyboard navigation, command palette, vim-style copy mode
- **Shell integration** -- Tracks working directory, git branch, ports, and command exit codes
- **Session persistence** -- Quit and relaunch restores layout, splits, and scrollback
- **Socket API** -- JSON-RPC 2.0 over Unix socket for full programmatic control
- **CLI tool** -- `mosaic` command-line interface for scripting and automation
- **Mosaic AI** -- Natural language control plane that maps intent to socket commands
- **LLM-swappable** -- Claude (default) or OpenAI as the AI backend
- **Command safety** -- Three-tier safety classification with destructive pattern detection
- **Telegram gateway** -- Send commands and receive alerts from your phone
- **Alert engine** -- Rule-based detection for build failures, crashes, and idle sessions

## Quick Start

### Prerequisites

- macOS 14.0+
- Xcode 16.0+
- [zig](https://ziglang.org/) 0.15.2 (`brew install zig`)
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`)

### Setup

```bash
git clone --recursive https://github.com/manaflow-ai/mosaic.git
cd mosaic
./Scripts/setup.sh       # builds GhosttyKit xcframework
xcodegen generate        # generates Mosaic.xcodeproj
open Mosaic.xcodeproj
```

Build and run the `Mosaic` scheme in Xcode (Cmd+R).

## Architecture

Mosaic is organized into four modules:

```
MosaicKit/       Core logic (no UI imports). Terminal, domain, IPC, AI, services.
MosaicUI/        SwiftUI + AppKit views. App entry point, sidebar, workspace, terminal.
MosaicGateway/   Standalone Hummingbird server. Telegram webhook, WebSocket bridge.
CLI/             Command-line tool. Sends JSON-RPC to the Unix socket.
```

### Module Breakdown

| Module | Directory | Purpose |
|--------|-----------|---------|
| **Domain** | `MosaicKit/Domain/` | Value types: Workspace, Panel, PaneTree, SessionSnapshot, SidebarMetadata |
| **Terminal** | `MosaicKit/Terminal/` | Ghostty C FFI: GhosttyBridge, GhosttyConfig, GhosttyKeyboard, TerminalSession, ShellIntegration |
| **IPC** | `MosaicKit/IPC/` | SocketServer, CommandRegistry, CommandDispatcher, AccessControl, EventBus, command handlers |
| **Services** | `MosaicKit/Services/` | WorkspaceManager, PanelManager, SessionPersistence, NotificationService, PortScanner |
| **AI** | `MosaicKit/AI/` | MosaicAI, LLMProvider, CommandSafety, AlertEngine, ConversationManager, ContextCollector |
| **Gateway** | `MosaicKit/Gateway/` | GatewayClient, MessageModels (desktop-side gateway connection) |
| **Views** | `MosaicUI/` | App, Sidebar, Workspace, Terminal, CommandPalette, Settings, AI preferences |
| **Gateway Server** | `MosaicGateway/` | Telegram channel, auth, session management, webhook routing |
| **CLI** | `CLI/` | `mosaic` command-line tool |

### Data Flow

```
SwiftUI Views --> @MainActor Managers --> Domain Value Types --> Ghostty C FFI
                         |
                   SocketServer <-- CLI / External clients
                         |
                    MosaicAI --> LLM Provider --> CommandSafety --> CommandRegistry
                         |
                   GatewayClient <--> MosaicGateway <--> Telegram
```

## Building

### With Ghostty (full build)

```bash
./Scripts/setup.sh          # init submodules, build GhosttyKit
xcodegen generate
xcodebuild -scheme Mosaic -configuration Debug build
```

### Without Ghostty (stub build for CI/development)

The project includes stub headers in `ghostty-stubs/` that allow compilation without the full Ghostty xcframework:

```bash
xcodegen generate
xcodebuild -scheme Mosaic -configuration Debug build
```

### Running Tests

```bash
xcodebuild -scheme Mosaic -configuration Debug test
```

## CLI Usage

The `mosaic` CLI communicates with the running app over a Unix socket at `/tmp/mosaic.sock`.

```bash
# Workspace management
mosaic workspace list
mosaic workspace create --title "Backend"
mosaic workspace select --id <uuid>
mosaic workspace rename --id <uuid> --title "Frontend"
mosaic workspace delete --id <uuid>

# Pane operations
mosaic pane split --direction horizontal
mosaic pane split --direction vertical --pane_id <uuid>
mosaic pane focus --pane_id <uuid>
mosaic pane resize --split_id <uuid> --ratio 0.6
mosaic pane send-keys "npm test\n"
mosaic pane read-screen --lines 50

# System
mosaic system ping
mosaic system version
mosaic system status
mosaic system capabilities

# AI (natural language control)
mosaic ai message --content "split pane and run npm test"
mosaic ai status
mosaic ai history --limit 20

# Notifications
mosaic notification create --title "Build done" --body "All tests passed"
mosaic notification list
mosaic notification clear

# Flags
mosaic workspace list --json            # raw JSON output
mosaic pane send-keys "ls\n" --timeout 10  # custom timeout
mosaic system ping --socket /tmp/mosaic-dev.sock  # custom socket
```

## Contributing

1. Fork the repository
2. Create a feature branch
3. Make your changes
4. Run `xcodebuild -scheme Mosaic test` to verify
5. Submit a pull request

Please read `AGENTS.md` for architectural conventions and coding guidelines.

## License

See LICENSE.
