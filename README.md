<p align="center">
  <img src="Resources/namu-icon.png" width="256" height="256" alt="Namu">
</p>

# Namu

**AI native terminal app.**

Namu is a native macOS terminal app built on [Ghostty](https://ghostty.org/). It organizes work into workspaces with split panes, exposes full programmatic control over a JSON-RPC socket API, ships a `namu` CLI for automation, and provides SSH remote workspace orchestration, deep agent integrations, and embedded browser automation.

## Features

### Core Terminal & Layout
- **GPU-accelerated terminal** — Ghostty-powered Metal rendering with low-latency typing
- **Workspaces and splits** — Tabbed workspaces with arbitrary horizontal and vertical nesting via NamuSplit
- **Tabbed panes** — Multiple tabs per pane with drag-and-drop reordering and cross-pane moves
- **Split inherits CWD** — New split panes and tabs start in the parent shell's working directory
- **Configurable workspace placement** — Position new workspaces at top, after current, or at end
- **Equalize splits** — Proportional leaf-count weighted split distribution (Cmd+Shift+=)
- **Tab-level pinning** — Pin tabs with session persistence across relaunches
- **Session persistence** — Restores layout, splits, scrollback, working directory, git branch, and window state across relaunches with fingerprint-based save skipping
- **Scrollback persistence** — ANSI-safe truncation with configurable buffer limits
- **Config hot-reload** — Cmd+Shift+, reloads Ghostty config without restarting
- **Project config file watching** — Live reload of `namu.json` on save with debounce

### SSH & Remote Workspaces
- **`namu ssh user@host`** — Full remote workspace command with SSH relay bootstrap
- **SSH session detection** — Detects active SSH connections via KERN_PROCARGS2 with full `~/.ssh/config` parsing
- **Remote daemon provisioning** — Automatic cross-platform binary download with SHA256 verification
- **SOCKS5 and HTTP CONNECT proxy tunnel** — Routes browser panel traffic through remote workspace
- **HMAC-SHA256 authenticated CLI relay** — Secure challenge-response for remote command forwarding
- **File upload via SCP** — Drag files into remote sessions with full SSH option forwarding
- **Connection pooling** — Multiple workspaces to the same host share one proxy tunnel
- **PTY resize coordination** — "Smallest screen wins" debounced resize across all attached clients
- **Automatic reconnection** — Exponential backoff with jitter on connection loss, heartbeat monitoring
- **ControlSocket multiplexing** — SSH connection reuse enabled by default
- **Terminfo provisioning** — xterm-ghostty sent to remote via infocmp/tic
- **ZDOTDIR overlay** — Shell integration injected into remote zsh sessions automatically
- **Cloud metadata SSRF blocking** — 169.254.169.254 and cloud provider metadata endpoints blocked in proxy tunnel

### Terminal Input
- **CJK IME** — Full NSTextInputClient with keyboard layout change detection during composition
- **macOS dictation** — Voice input routed correctly via accessibility APIs
- **Enhanced clipboard paste** — HTML/RTF/RTFD to plaintext conversion, image-only detection, 10MB limit
- **Middle-click paste** — X11-style paste from mouse button 2
- **Focus-follows-mouse** — Drag guards prevent focus thrashing during drag operations

### Sidebar & Workspace
- **Compact fixed-height rows** — 2-line workspace items: title + context (branch, path, ports, running command)
- **Shell state indicator** — Colored dot shows prompt/running/idle/error state
- **Pin icon** — Vertical pin replaces dot for pinned workspaces, colored by custom or accent color
- **Inline exit code** — Non-zero exit codes shown in red with the failed command
- **Running command display** — Active command shown in the context line
- **Hover close** — X button crossfades with badges on hover, no layout shift

### Pane Operations
- **`surface.reorder`** — Reorder tabs within a pane
- **`surface.drag_to_split`** — Drag existing tab into split position
- **`surface.move`** — Move surface across panes, workspaces, and windows
- **`pane.swap`** — Swap two panes with placeholder handling
- **`pane.break`** — Detach surface to new workspace with rollback on failure
- **Per-panel git branch tracking** — Shows branch and dirty state per panel
- **Per-panel PR status** — `panelPullRequests` dictionary with command palette "Open All PRs"

### Notification System
- **Per-workspace unread tracking** — Derived from NotificationService; auto-cleared when selecting workspace
- **Per-panel deduplication** — Same notification from different workspaces/tabs not suppressed
- **Correct workspace attribution** — Notifications attributed to owning workspace via surface pointer, not selected workspace
- **Status tracking API** — `sidebar.set_status` / `clear_status` / `list_status` with icon, color, priority pills
- **Structured logging API** — `sidebar.log` / `clear_log` / `list_log` with 5 severity levels (info, progress, success, warning, error)
- **Progress tracking API** — `sidebar.set_progress` / `clear_progress` with label
- **Menu bar unread badge** — Dynamic icon with unread count overlay, inline recent notifications, and mark-all-read
- **16 built-in notification sounds** — Plus custom sound support with background transcoding
- **Desktop notifications** — Focus suppression when notified pane is visible
- **5-reason attention rings** — Distinct colors, opacities, and animations per reason

### Browser Panel
- **84 automation IPC commands** — Navigation, DOM, JS eval, tabs, history, profiles, cookies, screenshots
- **Frecency-ranked address bar** — Tiered text matching + frequency × recency scoring with typed-navigation weighting
- **External URL scheme routing** — Non-web schemes (mailto:, discord://, slack://, etc.) handed off to macOS
- **Popup window support** — `window.open()` with nesting depth limits and cascading close
- **Browser profile import** — 20+ browsers (Chrome, Firefox, Safari, Arc, Edge, Brave, and more)
- **HTTPS insecure HTTP bypass** — Pattern allowlist for localhost/127.0.0.1/::1/\*.localtest.me
- **Find-in-page state restoration** — Search query replayed after navigation
- **Camera/microphone permissions** — System dialog via WKUIDelegate
- **Browser theme mode** — System/light/dark via CSS media query override
- **Content process crash recovery** — Automatic webview process restart
- **Browser profiles** — Isolated data stores for separate contexts
- **Network tracing** — JavaScript fetch/XHR interception (unique to Namu)

### CLI & API Ergonomics
- **Short ref IDs** — `workspace:1`, `pane:2`, `surface:3` accepted everywhere UUIDs are
- **`--id-format` flag** — `refs` / `uuids` / `both` on all list commands
- **`--no-focus` flag** — Prevents focus steal on commands that normally take focus
- **Socket password auth** — `--password` flag, `NAMU_SOCKET_PASSWORD` env var, or file
- **7-candidate socket auto-discovery** — Finds the running instance without configuration
- **37 tmux-compat commands** — Full tmux command coverage via CLI bridge

### Configuration & Theming
- **Centralized theme system** — `NamuColors` semantic colors that adapt to light/dark mode and fullscreen
- **Appearance-aware terminal** — Terminal colors auto-switch between Apple System Colors light/dark themes
- **Per-app Ghostty config** — `~/Library/Application Support/Namu/config.ghostty` overrides global Ghostty config
- **Auto-generated defaults** — Config and themes created on first launch; user-editable
- **Sidebar tint light/dark separation** — Separate colors for light and dark mode
- **Menu bar visibility toggle** — Show or hide the menu bar from settings
- **Telemetry opt-out** — No telemetry by default; opt-in only if crash reporting is configured

### Window Management & Debug
- **Window APIs** — `window.list`, `window.create`, `window.focus`, `window.close`, `window.current`
- **30+ debug commands** — Layout tree, window screenshot, panel snapshot with pixel diff, render stats
- **Flash and underflow counters** — Per-surface flash tracking with reset commands
- **Fullscreen control API** — Programmatic enter/exit fullscreen
- **Command palette debug APIs** — Toggle, visible state, selection, and rename operations

### Agent Integrations
- **Claude Code hooks** — 10 hook event types (SessionStart, Stop, SessionEnd, Notification, UserPromptSubmit, PreToolUse, and 4 more)
- **Codex hook support** — Install/uninstall hooks for OpenAI Codex
- **Agent PID tracking** — `set_agent_pid` / `clear_agent_pid` per surface with stale reaping
- **Session lockfile store** — `~/.namu/claude-hook-sessions.json` with 7-day TTL
- **Per-workspace port allocation** — `NAMU_PORT` / `NAMU_PORT_END` / `NAMU_PORT_RANGE` env vars
- **Claude hooks disabled toggle** — `NAMU_CLAUDE_HOOKS_DISABLED` env var

### Telemetry & Observability
- **OpenTelemetry-compatible metrics** — Zero-dependency OTLP HTTP JSON exporter
- **Sentry integration** — Direct OTLP export via DSN auto-configuration ([docs](https://docs.sentry.io/concepts/otlp/direct/))
- **Multi-target export** — Send to Sentry + any OTel collector simultaneously
- **Predefined metrics** — IPC latency/errors, socket health, browser navigations, notification counts
- **Structured logs** — Severity-leveled log records exported alongside metrics
- **Opt-in activation** — `NAMU_SENTRY_DSN` or `NAMU_OTEL_ENDPOINT` env vars; zero overhead when disabled

### Security
- **Cloud metadata SSRF blocking** — 169.254.169.254 blocked in proxy tunnel
- **CryptoKit constant-time HMAC** — Relay authentication resistant to timing attacks
- **Path traversal protection** — Manifest field validation on remote daemon download
- **Atomic relay metadata writes** — No partial-write race on credential files
- **Relay credential hex validation** — Malformed token rejection at parse time
- **Response size caps** — 1MB relay responses, 64KB proxy headers
- **Socket auth resilience** — LOCAL_PEERCRED UID fallback when LOCAL_PEERPID is unavailable
- **Socket server hardening** — Error classification, exponential backoff, consecutive failure tracking, health API

### Localization & Accessibility
- **953 localization keys** — Support across 19 languages
- **Full keyboard navigation** — Command palette, copy mode, keyboard hints, and pane shortcuts
- **AppleScript SDEF** — 4 classes, 11 commands for macOS automation

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

Namu is organized around three main code areas:

```text
NamuKit/       Core logic: terminal, domain, IPC, services, alerting
NamuUI/        SwiftUI + AppKit app and views
CLI/           `namu` command-line interface and tmux-compat tooling
daemon/remote/ Remote relay helper for forwarded command access
```

### Module Breakdown

| Area | Directory | Purpose |
|------|-----------|---------|
| **Domain** | `NamuKit/Domain/` | Value types: `Workspace`, `Panel`, `SessionSnapshot`, `WorkspaceRemoteConfiguration` |
| **Terminal** | `NamuKit/Terminal/` | Ghostty FFI, `TerminalSession`, keyboard/input, IME, shell integration, image transfer, SSH detection |
| **IPC** | `NamuKit/IPC/` | `SocketServer`, `RelayServer`, registry, dispatcher, middleware, access control, event bus |
| **Services** | `NamuKit/Services/` | `WorkspaceManager`, `PanelManager`, persistence, notifications, layout, port scanner |
| **NamuSplit** | `NamuKit/NamuSplit/` | Split-pane layout engine: tree model, controller, tabs, drag-and-drop, zoom |
| **Telemetry** | `NamuKit/Telemetry/` | `NamuTelemetry` OTLP exporter, `NamuMetrics` predefined metric definitions |
| **Alerting** | `NamuKit/Alerting/` | Channel abstractions and outbound Slack/Telegram/Discord/webhook delivery |
| **Browser** | `NamuKit/Browser/` | Profile/history stores, 84+ command handlers, network tracing, proxy configuration |
| **UI** | `NamuUI/` | App entry, sidebar, workspace, browser, settings, notifications, update UI |
| **CLI** | `CLI/` | JSON-RPC client, hooks for Claude/Codex, tmux compat, ref ID resolution |
| **Remote Helper** | `daemon/remote/` | Go daemon for remote session/proxy RPC; 12 RPC methods |

### Runtime Data Flow

```text
SwiftUI Views --> @MainActor managers --> domain models --> Ghostty FFI
                         |
CLI / local clients --> SocketServer --> CommandRegistry --> handlers
                         |
Remote clients --> RelayServer (HMAC-SHA256) --> CommandDispatcher --> handlers
                         |
SSH sessions --> RemoteSessionController --> daemon RPC --> proxy broker
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

# Run specific suites
xcodebuild test -scheme Namu -only-testing:NamuTests/BrowserHistoryStoreTests
xcodebuild test -scheme Namu -only-testing:NamuTests/AccessControlTests
xcodebuild test -scheme Namu -only-testing:NamuTests/SocketServerTests
```

## CLI Usage

The `namu` CLI communicates with the running app over `/tmp/namu.sock` by default.

```bash
# Workspaces — accepts UUIDs or short refs like workspace:1
namu workspace list
namu workspace create --title "Backend"
namu workspace select --id workspace:1
namu workspace rename --id workspace:1 --title "Frontend"
namu workspace delete --id workspace:1

# Panes
namu pane split --direction horizontal
namu pane swap --pane_id pane:1 --target_pane_id pane:2
namu pane break --pane_id pane:3
namu pane send_keys "npm test\n"
namu pane read_screen --lines 50
namu pane zoom

# Surfaces
namu surface reorder --surface_id surface:1 --index 0
namu surface move --surface_id surface:1 --pane_id pane:2

# Browser
namu browser open
namu browser navigate --url "https://example.com"
namu browser eval --code "document.title"
namu browser screenshot --path shot.png

# Sidebar status / progress / log
namu sidebar set_status build "Running tests" --icon checkmark.circle --color "#34C759"
namu sidebar set_progress 0.75 --label "Building..."
namu sidebar log --level success "All tests passed"

# Windows
namu window list
namu window create
namu window focus --id window:1

# System
namu system ping
namu system identify
namu system relay_status
namu system capabilities

# SSH remote workspace
namu ssh user@host

# Agent hooks
namu claude-teams
namu claude-hook session-start
namu codex install-hooks
```

### Global Flags

| Flag | Description | Default |
|------|-------------|---------|
| `--json` | Output raw JSON-RPC response | off |
| `--socket <path>` | Custom socket path | `/tmp/namu.sock` |
| `--timeout <secs>` | Request timeout | 5s (30s for long-running) |
| `--no-focus` | Prevent focus steal | off |
| `--id-format <fmt>` | `refs` / `uuids` / `both` | `refs` |
| `--password <pw>` | Socket password | `$NAMU_SOCKET_PASSWORD` |

## Contributing

1. Fork the repository
2. Create a feature branch
3. Make your changes
4. Run `xcodebuild -scheme Namu -configuration Debug test`
5. Submit a pull request

Please read `AGENTS.md` for architecture and workflow conventions before editing the codebase.

## License

See `LICENSE`.
