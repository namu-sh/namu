# Namu

**Terminal multiplexer for the agent era.**

Namu is a native macOS terminal built on [Ghostty](https://ghostty.org/) that organizes work into workspaces with split panes, exposes everything via a JSON-RPC socket API, and provides a built-in natural language control plane (Namu AI) accessible through Telegram.

<!-- screenshot placeholder -->
<!-- ![Namu screenshot](docs/assets/screenshot.png) -->

## Features

- **GPU-accelerated terminal** -- Ghostty-powered Metal rendering with sub-5ms typing latency
- **Workspaces and splits** -- Tabbed workspaces with arbitrary horizontal/vertical split nesting
- **Keyboard-driven** -- Full keyboard navigation, command palette, vim-style copy mode
- **Shell integration** -- Tracks working directory, git branch, ports, and command exit codes
- **Session persistence** -- Quit and relaunch restores layout, splits, and scrollback
- **Socket API** -- JSON-RPC 2.0 over Unix socket for full programmatic control
- **CLI tool** -- `namu` command-line interface for scripting and automation
- **Namu AI** -- Natural language control plane that maps intent to socket commands
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
git clone --recursive https://github.com/omxyz/namu.git
cd namu
./Scripts/setup.sh       # builds GhosttyKit xcframework
xcodegen generate        # generates Namu.xcodeproj
open Namu.xcodeproj
```

Build and run the `Namu` scheme in Xcode (Cmd+R).

## Architecture

Namu is organized into four modules:

```
NamuKit/       Core logic (no UI imports). Terminal, domain, IPC, AI, services.
NamuUI/        SwiftUI + AppKit views. App entry point, sidebar, workspace, terminal.
NamuGateway/   Standalone Hummingbird server. Telegram webhook, WebSocket bridge.
CLI/             Command-line tool. Sends JSON-RPC to the Unix socket.
```

### Module Breakdown

| Module | Directory | Purpose |
|--------|-----------|---------|
| **Domain** | `NamuKit/Domain/` | Value types: Workspace, Panel, PaneTree, SessionSnapshot, SidebarMetadata |
| **Terminal** | `NamuKit/Terminal/` | Ghostty C FFI: GhosttyBridge, GhosttyConfig, GhosttyKeyboard, TerminalSession, ShellIntegration |
| **IPC** | `NamuKit/IPC/` | SocketServer, CommandRegistry, CommandDispatcher, AccessControl, EventBus, command handlers |
| **Services** | `NamuKit/Services/` | WorkspaceManager, PanelManager, SessionPersistence, NotificationService, PortScanner |
| **AI** | `NamuKit/AI/` | NamuAI, LLMProvider, CommandSafety, AlertEngine, ConversationManager, ContextCollector |
| **Gateway** | `NamuKit/Gateway/` | GatewayClient, MessageModels (desktop-side gateway connection) |
| **Views** | `NamuUI/` | App, Sidebar, Workspace, Terminal, CommandPalette, Settings, AI preferences |
| **Gateway Server** | `NamuGateway/` | Telegram channel, auth, session management, webhook routing |
| **CLI** | `CLI/` | `namu` command-line tool |

### Data Flow

```
SwiftUI Views --> @MainActor Managers --> Domain Value Types --> Ghostty C FFI
                         |
                   SocketServer <-- CLI / External clients
                         |
                    NamuAI --> LLM Provider --> CommandSafety --> CommandRegistry
                         |
                   GatewayClient <--> NamuGateway <--> Telegram
```

## Building

### With Ghostty (full build)

```bash
./Scripts/setup.sh          # init submodules, build GhosttyKit
xcodegen generate
xcodebuild -scheme Namu -configuration Debug build
```

### Without Ghostty (stub build for CI/development)

The project includes stub headers in `ghostty-stubs/` that allow compilation without the full Ghostty xcframework:

```bash
xcodegen generate
xcodebuild -scheme Namu -configuration Debug build
```

### Running Tests

```bash
xcodebuild -scheme Namu -configuration Debug test
```

## CLI Usage

The `namu` CLI communicates with the running app over a Unix socket at `/tmp/namu.sock`.

```bash
# Workspace management
namu workspace list
namu workspace create --title "Backend"
namu workspace select --id <uuid>
namu workspace rename --id <uuid> --title "Frontend"
namu workspace delete --id <uuid>

# Pane operations
namu pane split --direction horizontal
namu pane split --direction vertical --pane_id <uuid>
namu pane focus --pane_id <uuid>
namu pane resize --split_id <uuid> --ratio 0.6
namu pane send-keys "npm test\n"
namu pane read-screen --lines 50

# System
namu system ping
namu system version
namu system status
namu system capabilities

# AI (natural language control)
namu ai message --content "split pane and run npm test"
namu ai status
namu ai history --limit 20

# Notifications
namu notification create --title "Build done" --body "All tests passed"
namu notification list
namu notification clear

# Flags
namu workspace list --json            # raw JSON output
namu pane send-keys "ls\n" --timeout 10  # custom timeout
namu system ping --socket /tmp/namu-dev.sock  # custom socket
```

## Contributing

1. Fork the repository
2. Create a feature branch
3. Make your changes
4. Run `xcodebuild -scheme Namu test` to verify
5. Submit a pull request

Please read `AGENTS.md` for architectural conventions and coding guidelines.

## License

See LICENSE.
