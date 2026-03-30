# Namu

**Terminal multiplexer for the agent era.**

Namu is a native macOS terminal multiplexer built on [Ghostty](https://ghostty.org/). It organizes work into workspaces with split panes, exposes the app over a JSON-RPC socket API, ships a `namu` CLI for automation, and includes a built-in natural-language control plane (`NamuAI`) for local AI-assisted control.

The current checkout also includes outbound alert routing (Slack, Telegram, Discord, webhook), browser automation commands, and an authenticated TCP relay for remote command forwarding. Older docs may still reference a standalone gateway; the shipped code today centers on `SocketServer`, `RelayServer`, and local AI/alerting.

## Features

- **GPU-accelerated terminal** — Ghostty-powered Metal rendering with low-latency typing
- **Workspaces and splits** — Tabbed workspaces with arbitrary horizontal and vertical nesting via [Bonsplit](vendor/bonsplit)
- **Keyboard-driven UI** — Command palette, copy mode, keyboard hints, and pane/workspace shortcuts
- **Shell integration** — Tracks working directory, git branch, ports, shell state, and exit codes
- **Session persistence** — Restores layout, splits, and scrollback across relaunches
- **Embedded browser** — Browser panels with JSON-RPC automation commands
- **Socket API** — JSON-RPC 2.0 over a Unix socket for programmatic control
- **CLI tool** — `namu` for scripting, tmux compatibility, and automation hooks
- **NamuAI** — Natural-language control plane mapped onto structured socket commands
- **LLM-swappable** — Claude, OpenAI, Gemini, or custom provider backends
- **Command safety** — Structured safety classification with destructive-pattern detection
- **Alert engine** — Rule-based alerts with Slack, Telegram, Discord, and webhook fan-out
- **Remote relay** — Authenticated TCP relay for remote forwarding and daemon-assisted access
- **In-app updates** — Update controller and titlebar badge UI

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
./Scripts/setup.sh      # builds GhosttyKit.xcframework
xcodegen generate       # generates Namu.xcodeproj
open Namu.xcodeproj
```

Build and run the `Namu` scheme in Xcode.

## Architecture

Namu is organized around four main code areas:

```text
NamuKit/       Core logic: terminal, domain, IPC, services, AI, alerting
NamuUI/        SwiftUI + AppKit app and views
CLI/           `namu` command-line interface and tmux-compat tooling
daemon/remote/ Remote relay helper for forwarded command access
```

### Module Breakdown

| Area | Directory | Purpose |
|------|-----------|---------|
| **Domain** | `NamuKit/Domain/` | Value types like `Workspace`, `Panel`, `PaneTree`, `SessionSnapshot` |
| **Terminal** | `NamuKit/Terminal/` | Ghostty FFI, `TerminalSession`, keyboard/input, shell integration, lifecycle |
| **IPC** | `NamuKit/IPC/` | `SocketServer`, `RelayServer`, registry, dispatcher, middleware, access control, event bus |
| **Services** | `NamuKit/Services/` | `WorkspaceManager`, `PanelManager`, persistence, notifications, layout, analytics |
| **AI** | `NamuKit/AI/` | `NamuAI`, provider abstraction, safety, conversations, context collection, tool mapping |
| **Alerting** | `NamuKit/Alerting/` | Channel abstractions and outbound Slack/Telegram/Discord/webhook delivery |
| **UI** | `NamuUI/` | App entry point, sidebar, workspace, browser, settings, AI chat, update UI |
| **CLI** | `CLI/` | JSON-RPC client, hooks, `claude-teams`, tmux compatibility helpers |
| **Remote Helper** | `daemon/remote/` | Remote relay bootstrap/helper used for forwarded command access |

### Runtime Data Flow

```text
SwiftUI Views --> @MainActor managers --> domain models --> Ghostty FFI
                         |
CLI / local clients --> SocketServer --> CommandRegistry --> handlers
                         |
Remote clients --> RelayServer --> CommandDispatcher --> handlers
                         |
NamuAI --> provider --> CommandSafety --> CommandRegistry
                         |
AlertEngine --> AlertRouter --> Slack / Telegram / Discord / Webhook
```

## Building

### Full build

```bash
./Scripts/setup.sh
xcodegen generate
xcodebuild -scheme Namu -configuration Debug build
```

### Tests

```bash
xcodebuild -scheme Namu -configuration Debug test
```

## CLI Usage

The `namu` CLI communicates with the running app over `/tmp/namu.sock` by default.

```bash
# Workspaces
namu workspace list
namu workspace create --title "Backend"
namu workspace select --id <uuid>
namu workspace rename --id <uuid> --title "Frontend"
namu workspace delete --id <uuid>

# Panes
namu pane split --direction horizontal
namu pane send_keys "npm test\n"
namu pane read_screen --lines 50
namu pane zoom
namu pane unzoom

# Browser
namu browser open
namu browser navigate --url "https://example.com"
namu browser eval --code "document.title"

# System
namu system ping
namu system identify
namu system relay_status
namu system capabilities

# AI
namu ai message --content "split pane and run npm test"
namu ai status
namu ai history --limit 20

# Integrations
namu claude-teams
namu codex install-hooks
```

## Contributing

1. Fork the repository
2. Create a feature branch
3. Make your changes
4. Run `xcodebuild -scheme Namu -configuration Debug test`
5. Submit a pull request

Please read `AGENTS.md` for architecture and workflow conventions before editing the codebase.

## License

See `LICENSE`.
