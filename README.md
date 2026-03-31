# Namu

**Terminal multiplexer for the agent era.**

Namu is a native macOS terminal multiplexer built on [Ghostty](https://ghostty.org/). It organizes work into workspaces with split panes, exposes the app over a JSON-RPC socket API, ships a `namu` CLI for automation, and includes a built-in natural-language control plane (`NamuAI`) for local AI-assisted control.

The current checkout also includes outbound alert routing (Slack, Telegram, Discord, webhook), browser automation commands, and an authenticated TCP relay for remote command forwarding. Older docs may still reference a standalone gateway; the shipped code today centers on `SocketServer`, `RelayServer`, and local AI/alerting.

## Features

### Core Terminal & Layout
- **GPU-accelerated terminal** — Ghostty-powered Metal rendering with low-latency typing
- **Workspaces and splits** — Tabbed workspaces with arbitrary horizontal and vertical nesting via [Bonsplit](vendor/bonsplit)
- **Configurable workspace placement** — Position new workspaces at top, after current, or at end
- **Equalize splits** — Proportional leaf-count weighted split distribution (Cmd+Shift+=)
- **Tab-level pinning** — Pin tabs with session persistence across relaunches
- **Session persistence** — Restores layout, splits, scrollback, and window state across relaunches
- **Scrollback persistence** — ANSI-safe truncation with configurable buffer limits

### Notification & Discovery
- **Notification panel UI** — Cmd+Shift+I for keyboard-navigable notification panel
- **Jump-to-unread** — Cmd+Shift+U (configurable) to jump to first unread notification

### User Interface
- **Keyboard-driven UI** — Command palette, copy mode, keyboard hints, and pane/workspace shortcuts
- **32 configurable keyboard shortcuts** — Full customization in preferences
- **Window decorations** — Traffic light management, custom drag handle, toolbar controller
- **Keystroke latency profiling** — Always compiled with 34 instrumentation points (enabled via env var)

### Panels & Content
- **Embedded browser** — Browser panels with isolated profiles and data stores, 84+ automation commands
- **Browser profiles** — Isolated data stores for separate browser contexts
- **5 search engines** — Parallel suggest with history scoring
- **Markdown panel** — Live file watching and rendering
- **New panel shortcuts** — `pane.new_browser_tab`, `pane.new_markdown_tab` commands

### Terminal Features
- **Shell integration** — Tracks working directory, git branch, ports, shell state, and exit codes
- **Port scanner** — Batched ps+lsof with coalesce and burst detection
- **Image transfer pipeline** — Kitty graphics protocol + SCP upload support
- **Surface pointer safety** — malloc_zone + registry cross-validation for dangling pointer detection

### Automation & Integration
- **Socket API** — JSON-RPC 2.0 over Unix socket and TCP relay for programmatic control
- **CLI tool** — `namu` for scripting, tmux compatibility, and automation hooks
- **37 tmux-compat commands** — Full tmux command coverage via CLI bridge
- **AppleScript SDEF** — 4 classes, 11 commands for macOS automation
- **Codex hook integration** — Install/uninstall hooks for IDE integration
- **Remote Go daemon** — 12 RPC methods for remote command execution

### AI & Intelligence
- **NamuAI** — Natural-language control plane mapped onto structured socket commands
- **LLM-swappable** — Claude, OpenAI, Gemini, or custom provider backends
- **Command safety** — Structured safety classification with destructive-pattern detection
- **10 Claude hook event types** — Session start, prompt submit, stop events

### Localization & Accessibility
- **953 localization keys** — Support across 19 languages
- **Accessibility hints** — Full keyboard navigation and screen reader support

### Alerting & Monitoring
- **Alert engine** — Rule-based alerts with 4 trigger types
- **Slack channel** — Native Slack integration with credential security
- **Telegram channel** — Outbound Telegram delivery
- **Discord channel** — Discord webhook support
- **Webhook channel** — Generic webhook delivery with custom headers

### Remote Access & Diagnostics
- **Remote relay** — Authenticated TCP relay (HMAC-SHA256) for remote forwarding
- **GPU Metal instrumentation** — IPC diagnostics for rendering performance
- **Relay status monitoring** — `system.relay_status` command for relay health
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
