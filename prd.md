# Mosaic — Product Requirements Document & Implementation Plan

> A native macOS/iOS terminal multiplexer that gives any coding agent rich workspace context via MCP, syncs terminals across devices, and alerts you through any messaging app.

---

## 1. Vision

Mosaic is a terminal for the agent era. It embeds Ghostty for GPU-accelerated terminal rendering, organizes work into workspaces with split panes and browser panels, and exposes everything — scrollback, ports, git state, shell activity — as structured context that any coding agent can read and act on. Terminals sync to your phone. Alerts reach you on Telegram, WhatsApp, or iMessage. You reply in natural language; your agent executes.

---

## 2. Target Users

| Persona | Need |
|---|---|
| **AI-assisted developer** | Runs Claude Code / Codex / Aider in multiple workspaces, needs visibility into what each agent is doing |
| **DevOps / SRE** | Monitors long-running processes, wants alerts on failures without staring at terminals |
| **Mobile-first developer** | Wants to check build status and send quick commands from phone |
| **Power terminal user** | Wants splits, tabs, keyboard-driven workflow, scriptable automation |

---

## 3. Core Concepts

| Concept | Definition |
|---|---|
| **Window** | A native macOS window. Contains one or more workspaces. |
| **Workspace** | A named unit of work (shown as a tab in the sidebar). Contains a pane tree. |
| **Pane Tree** | A binary tree of horizontal/vertical splits. Each leaf is a panel. |
| **Panel** | A content surface: terminal, browser, or markdown viewer. |
| **Terminal Panel** | A Ghostty-powered terminal session with shell integration. |
| **Browser Panel** | A WebKit-based embedded browser. |
| **Agent** | An external coding tool (Claude Code, Codex, Copilot, Aider, or any CLI) connected via MCP. |
| **Digest** | A structured, real-time summary of a workspace or panel's state. |
| **Gateway** | A server process that bridges Mosaic to messaging platforms. |

---

## 4. Feature Requirements

### 4.1 Terminal Core

| ID | Requirement | Priority |
|---|---|---|
| T-1 | Embed Ghostty as terminal renderer via xcframework (Metal GPU rendering) | P0 |
| T-2 | Shell integration: track working directory, command start/end, exit codes | P0 |
| T-3 | Scrollback buffer with configurable limit (default 10K lines) | P0 |
| T-4 | Ghostty config compatibility (~/.config/ghostty/config) for fonts, themes, colors | P0 |
| T-5 | Find-in-terminal overlay (regex support) | P1 |
| T-6 | Keyboard copy mode (vim-style selection without mouse) | P1 |
| T-7 | Clickable URLs with cmd+click | P0 |
| T-8 | Image rendering (iTerm2/Kitty image protocol) | P2 |

### 4.2 Workspace & Layout

| ID | Requirement | Priority |
|---|---|---|
| W-1 | Vertical sidebar showing all workspaces with metadata (git branch, status, ports) | P0 |
| W-2 | Split panes: horizontal and vertical, arbitrary nesting | P0 |
| W-3 | Drag-and-drop reordering of sidebar tabs | P0 |
| W-4 | Drag panels between splits and across workspaces | P1 |
| W-5 | Workspace persistence: save/restore layout, scrollback, and working directories on restart | P0 |
| W-6 | Keyboard-driven navigation: focus left/right/up/down across splits | P0 |
| W-7 | Command palette (fuzzy search for workspaces, commands, settings) | P0 |
| W-8 | Workspace renaming, pinning, and custom ordering | P1 |
| W-9 | Multi-window support (move workspaces between windows) | P1 |
| W-10 | Split zoom toggle (temporarily maximize one panel) | P1 |

### 4.3 Browser Panel

| ID | Requirement | Priority |
|---|---|---|
| B-1 | Embedded WebKit browser panel as a split alongside terminals | P0 |
| B-2 | Omnibar with URL/search input | P0 |
| B-3 | Developer tools toggle | P1 |
| B-4 | Bookmark management | P2 |
| B-5 | Profile import from Chrome/Safari/Firefox | P2 |
| B-6 | Browser automation via socket API (navigate, get URL, execute JS) | P1 |

### 4.4 Socket API & CLI

| ID | Requirement | Priority |
|---|---|---|
| S-1 | Unix socket server with JSON-RPC 2.0 protocol | P0 |
| S-2 | CLI tool (`mosaic`) that communicates via socket | P0 |
| S-3 | Access control modes: local-only, password-protected, open | P0 |
| S-4 | Command namespaces: `workspace.*`, `panel.*`, `pane.*`, `surface.*`, `browser.*`, `notification.*`, `system.*` | P0 |
| S-5 | Focus policy: non-focus commands must not steal app/window focus | P0 |
| S-6 | Off-main-thread command parsing and validation; main-thread only for UI mutations | P0 |

### 4.5 SSH & Remote

| ID | Requirement | Priority |
|---|---|---|
| R-1 | `mosaic ssh user@host` opens a remote workspace with shell integration | P1 |
| R-2 | Remote daemon (Go binary) for PTY management on remote hosts | P1 |
| R-3 | CLI relay over SSH reverse TCP forward (works when Unix socket forwarding is disabled) | P1 |
| R-4 | HMAC-SHA256 authentication for relay connections | P1 |
| R-5 | Proxy tunneling (SOCKS5/HTTP CONNECT) for browser panels on remote workspaces | P2 |
| R-6 | Smallest-screen-wins resize coordination for multi-attach sessions | P2 |

### 4.6 Agent Bridge (Mosaic AI)

| ID | Requirement | Priority |
|---|---|---|
| A-1 | `AgentProvider` protocol: swappable backend for any coding agent | P0 |
| A-2 | Built-in providers: Claude Code, Codex CLI, Copilot, Aider, custom CLI | P0 |
| A-3 | MCP server exposing workspace/panel context as resources | P0 |
| A-4 | MCP tools exposing socket commands (send keys, run command, create workspace, split, notify) | P0 |
| A-5 | `ContextCollector`: real-time aggregation of workspace/panel state into `WorkspaceDigest` and `PanelDigest` | P0 |
| A-6 | Per-workspace agent assignment (different agent per workspace) | P1 |
| A-7 | Agent configuration via `~/.config/mosaic/agents.json` | P0 |
| A-8 | AI context popover: hover/click a tab to see agent-generated summary | P1 |
| A-9 | AI sidebar section: live insights from active agents | P2 |

**Digest schema:**

```
WorkspaceDigest {
  workspaceId, title, panels: [PanelDigest],
  overallStatus: idle | running | error | completed,
  summary: String (agent-generated)
}

PanelDigest {
  panelId, type, workingDirectory, lastOutputTail (50 lines),
  gitBranch, listeningPorts, shellState: prompt | running(cmd) | idle,
  errorSignals: [String]
}
```

### 4.7 Alert Engine

| ID | Requirement | Priority |
|---|---|---|
| AL-1 | Rule-based alert detection (no LLM): output patterns, exit codes, SSH drops, port changes, idle duration | P0 |
| AL-2 | Configurable alert rules per workspace | P1 |
| AL-3 | In-app notification system with badges, sounds, and history | P0 |
| AL-4 | Route alerts to Gateway for external delivery | P1 |

**Default rules:**

| Trigger | Severity |
|---|---|
| Output matches `error:\|FAIL\|panic\|Exception` | error |
| Output matches `All \d+ tests passed\|BUILD SUCCEEDED` | success |
| Process exits with non-zero code | warning |
| SSH session disconnects | error |
| New port starts listening | info |
| Panel idle > 30 minutes | info |

### 4.8 Messaging Gateway

| ID | Requirement | Priority |
|---|---|---|
| G-1 | Standalone server process (deployable to cloud or self-hosted) | P1 |
| G-2 | `GatewayChannel` protocol with adapters for Telegram, WhatsApp, iMessage | P1 |
| G-3 | Bidirectional: alerts go out, user replies come back | P1 |
| G-4 | Inbound messages routed to active `AgentProvider` for natural language understanding | P1 |
| G-5 | Agent resolves user intent → socket command → Mosaic executes | P1 |
| G-6 | WebSocket persistent connection between Mosaic desktop and Gateway | P1 |
| G-7 | Multi-instance support: multiple Macs connect to one Gateway | P2 |
| G-8 | User account linking (messaging identity → Mosaic user) | P1 |
| G-9 | Conversation history per channel | P2 |

**Channel priority:**

| Channel | Mechanism | Priority |
|---|---|---|
| Telegram | Bot API (webhook) | P1 |
| iMessage | AppleScript bridge or macOS Shortcuts | P2 |
| WhatsApp | WhatsApp Business Cloud API | P2 |
| Push notifications (iOS) | APNs via Gateway | P1 |

### 4.9 iOS App

| ID | Requirement | Priority |
|---|---|---|
| I-1 | Workspace list view with real-time status from `WorkspaceDigest` | P1 |
| I-2 | Panel list per workspace with metadata | P1 |
| I-3 | Remote terminal view: renders relayed terminal frames (not local Ghostty) | P1 |
| I-4 | Touch keyboard with common terminal shortcuts | P1 |
| I-5 | State sync via CloudKit or WebSocket through Gateway | P1 |
| I-6 | Push notifications for alerts | P1 |
| I-7 | Reply to alerts with natural language (routed through agent) | P2 |
| I-8 | Widget: workspace status on home screen | P2 |

**Terminal relay protocol:**

```
TerminalFrame {
  panelId, rows, cols,
  cells: [[TerminalCell]],  // char + fg/bg + attributes
  cursorPosition, scrollbackOffset
}
```

Mac captures screen state from Ghostty, diffs, ships over WebSocket. iOS renders with custom `UIView`. Input travels the reverse path.

### 4.10 Non-Functional Requirements

| ID | Requirement |
|---|---|
| NF-1 | Typing latency < 5ms from keypress to Ghostty surface input |
| NF-2 | No allocations or I/O in the keystroke hot path |
| NF-3 | Socket command parsing off main thread; UI mutations on main thread only |
| NF-4 | All user-facing strings localized (English + Japanese initially) |
| NF-5 | Code-signed and notarized for macOS distribution |
| NF-6 | Sparkle-based auto-update system |
| NF-7 | Crash reporting (Sentry) and analytics (opt-in) |
| NF-8 | Accessibility: VoiceOver support for sidebar and command palette |

---

## 5. Architecture

### 5.1 Module Map

```
mosaic/
├── MosaicKit/                       # Shared framework (macOS + iOS, no UI imports)
│   ├── Domain/
│   │   ├── Workspace.swift              # Pure value type: id, title, order, pinned
│   │   ├── Panel.swift                  # Protocol + TerminalPanel, BrowserPanel, MarkdownPanel
│   │   ├── PaneTree.swift               # Binary tree of splits, each leaf is a Panel
│   │   ├── SidebarMetadata.swift        # Git branch, PR, ports, status — value types
│   │   └── SessionSnapshot.swift        # Codable snapshot for persistence
│   │
│   ├── Terminal/
│   │   ├── GhosttyBridge.swift          # ONLY file importing ghostty.h (C FFI)
│   │   ├── TerminalSession.swift        # Lifecycle: create, resize, destroy, env vars
│   │   ├── TerminalRenderer.swift       # Display link, IOSurface, forceRefresh
│   │   └── ShellIntegration.swift       # OSC parsing, pwd/title/command tracking
│   │
│   ├── IPC/
│   │   ├── SocketServer.swift           # Accept loop, connection lifecycle
│   │   ├── CommandRegistry.swift        # Register handlers by method name
│   │   ├── CommandDispatcher.swift      # Route JSON-RPC → handler
│   │   ├── AccessControl.swift          # Socket modes, HMAC, password store
│   │   └── Commands/
│   │       ├── WorkspaceCommands.swift
│   │       ├── PanelCommands.swift
│   │       ├── PaneCommands.swift
│   │       ├── BrowserCommands.swift
│   │       ├── NotificationCommands.swift
│   │       └── SystemCommands.swift
│   │
│   ├── Remote/
│   │   ├── SSHSessionController.swift
│   │   ├── ProxyBroker.swift
│   │   └── DaemonManifest.swift
│   │
│   ├── Services/
│   │   ├── WorkspaceManager.swift       # Create/delete/reorder workspaces
│   │   ├── PanelManager.swift           # Panel lifecycle within a workspace
│   │   ├── NotificationService.swift    # Notification creation, storage, clearing
│   │   ├── SessionPersistence.swift     # Save/restore snapshots
│   │   └── PortScanner.swift            # Listening port detection
│   │
│   ├── AI/
│   │   ├── ContextCollector.swift       # Subscribes to services, builds digests
│   │   ├── WorkspaceDigest.swift        # Per-workspace structured summary
│   │   ├── PanelDigest.swift            # Per-panel structured summary
│   │   ├── AlertEngine.swift            # Rule-based event detection
│   │   ├── AgentBridge.swift            # MCP server: context as resources, commands as tools
│   │   ├── AgentProvider.swift          # Protocol: swappable agent backend
│   │   └── Providers/
│   │       ├── ClaudeCodeProvider.swift
│   │       ├── CodexProvider.swift
│   │       ├── CopilotProvider.swift
│   │       ├── AiderProvider.swift
│   │       └── CustomCLIProvider.swift
│   │
│   ├── Sync/
│   │   ├── SyncEngine.swift             # Bidirectional state replication
│   │   ├── SyncTransport.swift          # Protocol (CloudKit / WebSocket)
│   │   ├── TerminalRelay.swift          # Streams terminal frames to iOS
│   │   ├── ConflictResolver.swift       # Handles concurrent state updates
│   │   └── SyncModels.swift             # Codable sync payloads
│   │
│   └── Gateway/
│       ├── GatewayClient.swift          # WebSocket connection to Gateway server
│       ├── GatewayChannel.swift         # Protocol: messaging channel adapter
│       └── MessageModels.swift          # Alert, inbound/outbound message types
│
├── MosaicUI/                        # macOS app (SwiftUI + AppKit)
│   ├── App/
│   │   ├── MosaicApp.swift              # @main, environment injection
│   │   └── AppDelegate.swift            # Window chrome, menu bar (slim, <500 lines)
│   │
│   ├── Sidebar/
│   │   ├── SidebarView.swift
│   │   ├── SidebarItemView.swift        # Equatable for typing-latency safety
│   │   └── SidebarViewModel.swift
│   │
│   ├── Workspace/
│   │   ├── WorkspaceView.swift          # Renders PaneTree
│   │   ├── PanelContentView.swift       # Switches on panel type → subview
│   │   └── PaneTreeView.swift           # Recursive split renderer
│   │
│   ├── Terminal/
│   │   ├── TerminalView.swift           # NSViewRepresentable (thin wrapper)
│   │   ├── TerminalSearchOverlay.swift
│   │   └── TerminalPortalView.swift     # AppKit hosting for hit-test perf
│   │
│   ├── Browser/
│   │   ├── BrowserView.swift
│   │   ├── OmnibarView.swift
│   │   └── BrowserSearchOverlay.swift
│   │
│   ├── CommandPalette/
│   │   ├── CommandPaletteView.swift
│   │   └── CommandPaletteViewModel.swift
│   │
│   ├── AI/
│   │   ├── AIContextPopover.swift
│   │   ├── AISidebarSection.swift
│   │   └── AIPreferencesView.swift
│   │
│   ├── Settings/
│   │   ├── SettingsView.swift
│   │   ├── KeyboardShortcutSettings.swift
│   │   └── SocketControlSettings.swift
│   │
│   ├── Notifications/
│   │   ├── NotificationBadgeView.swift
│   │   └── NotificationHistoryView.swift
│   │
│   └── Update/
│       ├── UpdateController.swift
│       └── UpdatePillView.swift
│
├── MosaicIOS/                       # iOS app target
│   ├── App/
│   │   └── MosaicIOSApp.swift
│   ├── Terminal/
│   │   ├── RemoteTerminalView.swift     # Renders TerminalFrame (no Ghostty)
│   │   └── TouchInputAdapter.swift      # Touch/swipe → terminal input
│   ├── Sidebar/
│   │   ├── WorkspaceListView.swift
│   │   └── PanelListView.swift
│   ├── Notifications/
│   │   └── AlertFeedView.swift
│   └── Widget/
│       └── WorkspaceStatusWidget.swift
│
├── MosaicGateway/                   # Standalone server (deployable)
│   ├── main.swift
│   ├── WebhookRouter.swift              # HTTP endpoints for Telegram/WhatsApp webhooks
│   ├── SessionManager.swift             # Tracks connected Mosaic instances
│   ├── PushRelay.swift                  # APNs for iOS push notifications
│   └── Channels/
│       ├── TelegramChannel.swift
│       ├── WhatsAppChannel.swift
│       └── iMessageChannel.swift
│
├── mosaic-remote/                   # Go daemon for SSH remote sessions
│   ├── cmd/mosaic-remote/
│   │   ├── main.go                      # RPC server (stdio), CLI relay
│   │   ├── session.go                   # PTY management, resize coordinator
│   │   ├── proxy.go                     # SOCKS5/HTTP CONNECT tunneling
│   │   └── cli.go                       # Command translation for remote CLI
│   ├── go.mod
│   └── go.sum
│
├── CLI/
│   └── mosaic.swift                     # CLI tool: parses args → JSON-RPC to socket
│
├── Resources/
│   ├── Info.plist
│   ├── Localizable.xcstrings
│   ├── shell-integration/               # zsh/bash/fish hooks
│   └── themes/                          # Bundled Ghostty themes
│
├── Tests/
│   ├── MosaicKitTests/
│   │   ├── Domain/
│   │   ├── IPC/
│   │   ├── AI/
│   │   └── Services/
│   ├── MosaicUITests/
│   ├── GatewayTests/
│   └── SocketTests/                     # Python integration tests against socket API
│
├── ghostty/                             # Git submodule: Ghostty fork
├── scripts/
│   ├── setup.sh                         # Init submodules, build GhosttyKit
│   ├── build.sh                         # Build macOS app
│   ├── build-ios.sh                     # Build iOS app
│   ├── build-gateway.sh                 # Build Gateway server
│   ├── reload.sh                        # Tagged debug build + launch
│   └── bump-version.sh                  # Version management
│
├── Package.swift
├── Mosaic.xcodeproj/
├── CLAUDE.md
├── README.md
└── CHANGELOG.md
```

### 5.2 Dependency Graph

```
MosaicIOS ──→ MosaicKit ←── MosaicUI (macOS)
                  ↑
           MosaicGateway

MosaicKit imports: Foundation, Combine, Network (no AppKit, no SwiftUI, no UIKit)
MosaicUI  imports: MosaicKit, SwiftUI, AppKit, WebKit, Sparkle
MosaicIOS imports: MosaicKit, SwiftUI, UIKit, WidgetKit
MosaicGateway imports: MosaicKit (Domain + Gateway only), Foundation, Network
```

**Enforcement:** `MosaicKit` is a Swift package with no platform UI framework dependencies. If someone accidentally imports AppKit in `MosaicKit`, it won't compile for iOS.

### 5.3 Data Flow

```
User keystroke
  → AppDelegate.performKeyEquivalent (if shortcut) OR
  → TerminalPortalView.keyDown → GhosttyBridge.sendKey → Ghostty renders
  → TerminalRenderer.forceRefresh (no allocs, no I/O)

Terminal output changes
  → ShellIntegration detects pwd/command/exit
  → TerminalSession updates published state
  → ContextCollector picks up change → updates PanelDigest
  → AlertEngine evaluates rules → may produce Alert
  → Alert → NotificationService (in-app) + GatewayClient (external)

Socket command arrives
  → SocketServer accepts connection (background thread)
  → CommandDispatcher parses JSON-RPC (background thread)
  → CommandRegistry finds handler
  → Handler reads from Services (background) or mutates UI (main actor)
  → Response sent back on socket

Agent interaction
  → AgentBridge exposes MCP server (resources + tools)
  → Agent reads Namu://workspace/123 → gets WorkspaceDigest
  → Agent calls mosaic_send_keys tool → CommandRegistry dispatches
  → Agent sends message → AgentBridge routes to NotificationService or Gateway

iOS sync
  → SyncEngine publishes WorkspaceDigest changes
  → SyncTransport ships via WebSocket to Gateway → Gateway pushes to iOS
  → iOS renders WorkspaceListView from received digests
  → User taps panel → TerminalRelay starts streaming TerminalFrame
  → TouchInputAdapter sends keystrokes back → relay → Mac → GhosttyBridge
```

### 5.4 Performance Contracts

| Hot Path | Contract | Enforcement |
|---|---|---|
| Keystroke → Ghostty input | No allocations, no I/O, no locking | `GhosttyBridge.sendKey` is a direct C call |
| `SidebarItemView` body evaluation | Must not re-evaluate during typing | `Equatable` conformance + `.equatable()` modifier |
| `TerminalRenderer.forceRefresh` | No allocations, no formatting, no file I/O | Code review + DEBUG-mode timing assertions |
| Socket command parsing | Off main thread | `SocketServer` runs on dedicated `DispatchQueue` |
| UI state mutations from socket | `DispatchQueue.main.async` only | `@MainActor` on service types, handlers use `await` |
| Telemetry commands (`report_*`) | Dedupe/coalesce off-main | Handler coalesces before scheduling main-thread update |

---

## 6. Implementation Plan

### Phase 0: Foundation (Weeks 1-2)

**Goal:** Empty macOS window with Ghostty terminal rendering.

| Step | Deliverable |
|---|---|
| 0.1 | Create Xcode project with `MosaicKit` (Swift package) and `MosaicUI` (app target) |
| 0.2 | Add Ghostty as git submodule, build GhosttyKit xcframework (`scripts/setup.sh`) |
| 0.3 | Implement `GhosttyBridge.swift` — thin C FFI wrapper around `ghostty_surface_t` |
| 0.4 | Implement `TerminalSession.swift` — lifecycle management (create, resize, destroy) |
| 0.5 | Implement `TerminalRenderer.swift` — display link, IOSurface hosting |
| 0.6 | Implement `TerminalView.swift` (NSViewRepresentable) and `TerminalPortalView.swift` (AppKit hit-test host) |
| 0.7 | Create `MosaicApp.swift` (@main) and `AppDelegate.swift` — single window, single terminal |
| 0.8 | Verify: keystroke → Ghostty → rendered output. Measure typing latency. |

**Exit criteria:** A macOS window running a fully functional terminal. Typing latency < 5ms.

### Phase 1: Workspace & Layout (Weeks 3-4)

**Goal:** Multiple workspaces with split panes.

| Step | Deliverable |
|---|---|
| 1.1 | Implement `Workspace.swift` (value type), `PaneTree.swift` (binary tree model) |
| 1.2 | Implement `WorkspaceManager.swift` — create, delete, reorder, select workspaces |
| 1.3 | Implement `PanelManager.swift` — panel lifecycle within a workspace |
| 1.4 | Implement `PaneTreeView.swift` — recursive split renderer with draggable dividers |
| 1.5 | Implement `SidebarView.swift` + `SidebarItemView.swift` (Equatable) + `SidebarViewModel.swift` |
| 1.6 | Implement keyboard navigation: focus left/right/up/down, split right/down |
| 1.7 | Implement `CommandPaletteView.swift` — fuzzy search for workspaces and commands |
| 1.8 | Implement drag-and-drop: reorder sidebar tabs, move panels between splits |

**Exit criteria:** Multiple workspaces, arbitrary split layouts, keyboard-driven navigation.

### Phase 2: Shell Integration & Metadata (Weeks 5-6)

**Goal:** Sidebar shows live metadata per workspace.

| Step | Deliverable |
|---|---|
| 2.1 | Implement `ShellIntegration.swift` — OSC 133 parsing for prompt/command/pwd tracking |
| 2.2 | Implement `SidebarMetadata.swift` — git branch, ports, status, working directory |
| 2.3 | Implement `PortScanner.swift` — detect listening ports per panel |
| 2.4 | Wire metadata into `SidebarItemView` — git branch badge, port list, directory path |
| 2.5 | Implement `SessionPersistence.swift` — save/restore workspace layouts on app restart |
| 2.6 | Implement `KeyboardShortcutSettings.swift` — customizable keybindings |
| 2.7 | Implement shell integration scripts for zsh, bash, fish (bundled in Resources) |

**Exit criteria:** Sidebar tabs show git branch, working directory, listening ports. Workspaces persist across restarts.

### Phase 3: Socket API & CLI (Weeks 7-8)

**Goal:** Full JSON-RPC socket API with CLI tool.

| Step | Deliverable |
|---|---|
| 3.1 | Implement `SocketServer.swift` — Unix socket accept loop on background thread |
| 3.2 | Implement `CommandRegistry.swift` + `CommandDispatcher.swift` — handler registration and JSON-RPC routing |
| 3.3 | Implement `AccessControl.swift` — socket modes (local-only, password, open) |
| 3.4 | Implement command handlers: `WorkspaceCommands`, `PanelCommands`, `PaneCommands`, `SystemCommands` |
| 3.5 | Implement `CLI/mosaic.swift` — CLI tool that sends JSON-RPC to socket |
| 3.6 | Implement `NotificationService.swift` + `NotificationCommands.swift` — in-app notifications with badges |
| 3.7 | Write Python integration test suite against socket API |

**Exit criteria:** `mosaic workspace list`, `mosaic panel send-keys`, `mosaic notify` all work. Test suite passes.

### Phase 4: Browser Panel (Weeks 9-10)

**Goal:** Embedded browser as a panel type.

| Step | Deliverable |
|---|---|
| 4.1 | Implement `BrowserPanel.swift` — WebKit WKWebView lifecycle |
| 4.2 | Implement `BrowserView.swift` + `OmnibarView.swift` — URL bar with search |
| 4.3 | Implement `BrowserSearchOverlay.swift` — find-in-page |
| 4.4 | Implement `BrowserCommands.swift` — socket commands: navigate, back, forward, reload, get URL |
| 4.5 | Wire browser panel into `PanelContentView` — can be split alongside terminals |

**Exit criteria:** Browser panel opens URLs, supports back/forward, controllable via CLI.

### Phase 5: Agent Bridge (Weeks 11-13)

**Goal:** Any coding agent gets rich workspace context via MCP.

| Step | Deliverable |
|---|---|
| 5.1 | Implement `ContextCollector.swift` — subscribes to all services, builds live digests |
| 5.2 | Implement `WorkspaceDigest.swift` + `PanelDigest.swift` — structured context models |
| 5.3 | Implement `AgentProvider.swift` protocol + `AgentBridge.swift` MCP server |
| 5.4 | Expose digests as MCP resources: `mosaic://workspaces`, `mosaic://workspace/{id}`, `mosaic://panel/{id}` |
| 5.5 | Expose socket commands as MCP tools: `mosaic_send_keys`, `mosaic_run_command`, `mosaic_create_workspace`, `mosaic_split`, `mosaic_notify`, `mosaic_read_screen` |
| 5.6 | Implement `ClaudeCodeProvider.swift` — connect to Claude Code via MCP |
| 5.7 | Implement `CodexProvider.swift` — connect to Codex CLI |
| 5.8 | Implement `CustomCLIProvider.swift` — spawn arbitrary CLI with context piped in |
| 5.9 | Implement agent config: `~/.config/mosaic/agents.json`, per-workspace agent assignment |
| 5.10 | Implement `AIContextPopover.swift` — click tab to see agent-generated summary |

**Exit criteria:** Claude Code running inside Mosaic can read workspace context via MCP resources and execute commands via MCP tools. Codex CLI works as alternative provider.

### Phase 6: Alert Engine (Week 14)

**Goal:** Rule-based detection of notable terminal events.

| Step | Deliverable |
|---|---|
| 6.1 | Implement `AlertEngine.swift` — configurable rules (output patterns, exit codes, SSH drops, port changes, idle) |
| 6.2 | Wire `AlertEngine` to `ContextCollector` — evaluates rules on every digest update |
| 6.3 | Route alerts to `NotificationService` (in-app badges, sounds) |
| 6.4 | Implement alert configuration UI in settings |
| 6.5 | Implement `NotificationHistoryView.swift` — scrollable alert history |

**Exit criteria:** Build failures, test passes, SSH drops trigger in-app notifications automatically.

### Phase 7: Messaging Gateway (Weeks 15-17)

**Goal:** Alerts reach users on Telegram/WhatsApp/iMessage. Users can reply.

| Step | Deliverable |
|---|---|
| 7.1 | Implement `MosaicGateway/main.swift` — standalone server with HTTP + WebSocket |
| 7.2 | Implement `GatewayChannel.swift` protocol |
| 7.3 | Implement `TelegramChannel.swift` — Telegram Bot API webhook handler |
| 7.4 | Implement `GatewayClient.swift` in `MosaicKit` — WebSocket connection from desktop app to Gateway |
| 7.5 | Wire `AlertEngine` → `GatewayClient` — alerts pushed to Gateway → Telegram |
| 7.6 | Implement inbound message handling: Telegram reply → Gateway → `GatewayClient` → active `AgentProvider` for NLU → `CommandRegistry` executes |
| 7.7 | Implement `SessionManager.swift` — track multiple connected Mosaic instances |
| 7.8 | Implement `UserLinkService.swift` — link messaging accounts to Mosaic user |
| 7.9 | Implement `WhatsAppChannel.swift` and `iMessageChannel.swift` |
| 7.10 | Implement `PushRelay.swift` — APNs integration for iOS push |

**Exit criteria:** Terminal failure → Telegram message to user. User replies "restart" → agent interprets → command executes on Mac.

### Phase 8: iOS App (Weeks 18-21)

**Goal:** View and interact with terminals from iPhone.

| Step | Deliverable |
|---|---|
| 8.1 | Create `MosaicIOS` target importing `MosaicKit` |
| 8.2 | Implement `SyncEngine.swift` + `SyncTransport.swift` — state sync via Gateway WebSocket |
| 8.3 | Implement `WorkspaceListView.swift` — live workspace list from synced digests |
| 8.4 | Implement `PanelListView.swift` — panel list per workspace with metadata |
| 8.5 | Implement `TerminalRelay.swift` — Mac captures Ghostty screen state, ships `TerminalFrame` diffs |
| 8.6 | Implement `RemoteTerminalView.swift` — renders `TerminalFrame` with custom `UIView` |
| 8.7 | Implement `TouchInputAdapter.swift` — on-screen keyboard with terminal shortcuts |
| 8.8 | Implement `AlertFeedView.swift` — notification history on iOS |
| 8.9 | Implement `WorkspaceStatusWidget.swift` — home screen widget |
| 8.10 | Push notification integration via Gateway |

**Exit criteria:** iPhone shows live workspace status. Tapping a panel shows real-time terminal output. Typing on phone appears in Mac terminal.

### Phase 9: SSH Remote (Weeks 22-24)

**Goal:** `mosaic ssh user@host` for remote terminal workspaces.

| Step | Deliverable |
|---|---|
| 9.1 | Implement `mosaic-remote` Go daemon — RPC server over stdio (hello, ping, session.*, proxy.*) |
| 9.2 | Implement PTY session management with smallest-screen-wins resize |
| 9.3 | Implement `SSHSessionController.swift` — SSH connection, daemon deployment, reverse TCP relay |
| 9.4 | Implement HMAC-SHA256 relay authentication |
| 9.5 | Implement remote CLI relay — `mosaic` commands work inside SSH sessions |
| 9.6 | Implement `ProxyBroker.swift` — SOCKS5/HTTP CONNECT for remote browser panels |
| 9.7 | Implement remote workspace UI indicators (connection status, latency) |

**Exit criteria:** `mosaic ssh user@host` opens a workspace with full shell integration, CLI access, and browser proxying.

### Phase 10: Polish & Release (Weeks 25-26)

| Step | Deliverable |
|---|---|
| 10.1 | Localization: English + Japanese |
| 10.2 | Auto-update via Sparkle |
| 10.3 | Code signing + notarization |
| 10.4 | Crash reporting (Sentry) + opt-in analytics |
| 10.5 | Documentation site |
| 10.6 | `scripts/bump-version.sh` + CI/CD pipeline |
| 10.7 | Homebrew formula |
| 10.8 | VoiceOver accessibility for sidebar and command palette |

---

## 7. Tech Stack

| Component | Technology |
|---|---|
| Terminal rendering | Ghostty (Zig/C, Metal GPU) via xcframework |
| macOS UI | SwiftUI + AppKit (hybrid, portals for perf) |
| iOS UI | SwiftUI + UIKit (terminal renderer) |
| Shared logic | Swift package (`MosaicKit`), Foundation + Combine |
| Browser | WebKit (WKWebView) |
| Socket API | Unix domain socket, JSON-RPC 2.0 |
| Remote daemon | Go 1.22, stdin/stdout RPC |
| Gateway server | Swift (Vapor or Hummingbird) or Go |
| Agent integration | MCP (Model Context Protocol) |
| State sync | WebSocket + CloudKit (iOS) |
| Messaging | Telegram Bot API, WhatsApp Business API, AppleScript (iMessage) |
| Auto-update | Sparkle |
| CI/CD | GitHub Actions |
| Crash reporting | Sentry |

---

## 8. Risk Register

| Risk | Impact | Mitigation |
|---|---|---|
| Ghostty API changes break bridge | High | Pin submodule, thin FFI layer (`GhosttyBridge.swift` is the only C-touching file) |
| Typing latency regression | High | DEBUG-mode timing assertions, performance contracts enforced via code review |
| WhatsApp Business API approval | Medium | Telegram first (no approval needed), WhatsApp as P2 |
| iOS terminal rendering quality | Medium | Start with text-only frames, add color/attribute rendering incrementally |
| Gateway hosting cost | Low | Self-hostable, minimal resource usage (WebSocket + webhook relay) |
| Agent provider API changes | Medium | `AgentProvider` protocol isolates changes to one adapter file |
| MCP spec evolution | Low | MCP is Anthropic-maintained and stable; abstract behind `AgentBridge` |

---

## 9. Success Metrics

| Metric | Target |
|---|---|
| Typing latency (p99) | < 5ms |
| Time from terminal event to Telegram alert | < 3 seconds |
| iOS terminal frame latency | < 200ms |
| Agent context query response time | < 100ms |
| Socket command throughput | > 1000 commands/sec |
| App cold launch to usable terminal | < 1 second |
| Crash-free session rate | > 99.5% |

---

## Appendix A: Terminal Rendering — Implementation Detail

### A.1 NSView Hierarchy

The terminal embedding requires a specific AppKit view hierarchy for performance and correct layering:

```
GhosttySurfaceScrollView (NSView — container)
├── backgroundView (NSView — background color fill)
├── scrollView (NSScrollView subclass)
│   └── documentView (NSView)
│       └── surfaceView (GhosttyNSView — Metal-backed, wantsLayer=true)
├── inactiveOverlayView (NSView — dimming overlay for unfocused splits)
└── SurfaceSearchOverlay (SwiftUI hosted — find-in-terminal UI)
```

**Critical:** The search overlay MUST be mounted from the AppKit scroll view container, not from any SwiftUI panel wrapper. Portal-hosted terminal views can sit above SwiftUI during split/workspace transitions. Mounting search from SwiftUI causes it to disappear during layout churn.

### A.2 Ghostty C FFI Surface

The bridge wraps these opaque C types and functions:

**Types:**
- `ghostty_app_t` — global application instance (singleton)
- `ghostty_surface_t` — one per terminal session, owns PTY + renderer
- `ghostty_config_t` — parsed configuration

**Surface creation requires a config struct:**
```c
ghostty_surface_config_s {
    platform_tag: GHOSTTY_PLATFORM_MACOS,
    platform: { macos: { nsview: <pointer> } },
    userdata: <callback_context>,
    scale_factor: Double,       // 1.0 or 2.0 (Retina)
    font_size: Float,
    working_directory: *char,
    command: *char,             // shell to run
    env_vars: *ghostty_env_var_s,
    env_var_count: size_t,
    context: WINDOW | TAB | SPLIT
}
```

**Key C API calls used (must all be in GhosttyBridge.swift):**

| Function | Purpose | Hot path? |
|---|---|---|
| `ghostty_surface_new` | Create surface | No |
| `ghostty_surface_free` | Destroy surface | No |
| `ghostty_surface_key` | Send keyboard input | **Yes — keystroke** |
| `ghostty_surface_text` | Send IME text | **Yes — keystroke** |
| `ghostty_surface_preedit` | IME composition | **Yes — keystroke** |
| `ghostty_surface_key_is_binding` | Check if key is a binding | **Yes — keystroke** |
| `ghostty_surface_key_translation_mods` | Translate modifiers per config | **Yes — keystroke** |
| `ghostty_surface_refresh` | Request redraw | **Yes — per frame** |
| `ghostty_surface_set_size` | Resize terminal | No |
| `ghostty_surface_size` | Query cell dimensions | No |
| `ghostty_surface_set_focus` | Focus state change | No |
| `ghostty_surface_set_display_id` | CVDisplayLink display target | No (but critical timing) |
| `ghostty_surface_mouse_button/pos/scroll` | Mouse input | No |
| `ghostty_surface_select_cursor_cell` | Copy mode: place cursor | No |
| `ghostty_surface_clear_selection` | Copy mode: clear | No |
| `ghostty_surface_has_selection` | Query selection state | No |
| `ghostty_surface_read_selection` | Read selected text | No |
| `ghostty_surface_ime_point` | IME popup positioning | No |

**Keyboard input struct:**
```c
ghostty_input_key_s {
    action: PRESS | RELEASE | REPEAT,
    keycode: UInt32,            // NSEvent.keyCode
    mods: SHIFT | CTRL | ALT | SUPER | ...,
    consumed_mods: <flags>,
    text: *char,                // UTF-8 (null-terminated)
    unshifted_codepoint: UInt32,
    composing: bool
}
```

### A.3 Display Link & Frozen Surface Prevention

**Problem:** Ghostty uses CVDisplayLink for vsync-driven rendering. If the display ID isn't set before the link starts, it runs but never fires callbacks → frozen terminal.

**Solution — two-point defense:**
1. Set display ID immediately after surface creation (from `window.screen.displayID`)
2. Re-assert display ID on every focus gain (catches display migration, wake-from-sleep)

```
Surface created → ghostty_surface_set_display_id(surface, displayID)
Surface gains focus → ghostty_surface_set_display_id(surface, displayID) // re-assert
```

### A.4 Keyboard Event Routing — Three Phases

```
Phase 1: performKeyEquivalent (NSView override)
  → Called BEFORE keyDown for ⌘-modified keys
  → Check ghostty_surface_key_is_binding()
  → If binding with PERFORMABLE flag: try NSApp.mainMenu.performKeyEquivalent()
  → Otherwise: fall through to keyDown

Phase 2: keyDown (NSView override)
  → If Ctrl (no Cmd/Opt): direct ghostty_surface_key() — skip IME
  → Otherwise: interpretKeyEvents() → NSTextInputClient pipeline
  → Text accumulated in keyTextAccumulator array during interpretation
  → Flushed as ghostty_surface_text() after interpretation completes

Phase 3: keyUp
  → Build release event from same translation path
  → action = RELEASE, text = nil
  → ghostty_surface_key(release_event)
```

**IME (Input Method Editor) support:**
- `NSTextInputClient` conformance on the Metal-backed NSView
- `markedText` (NSMutableAttributedString) for preedit composition
- `insertText()` flushes accumulated text to Ghostty
- `firstRect(forCharacterRange:)` positions the IME popup via `ghostty_surface_ime_point()`

### A.5 Copy Mode

Keyboard-driven text selection (vim-style) without mouse:

- Activation: toggle key → `ghostty_surface_select_cursor_cell()` places 1-cell selection at cursor
- Movement: arrow keys (or hjkl) move selection anchor via Ghostty binding actions
- Visual mode: `v` key toggles `keyboardCopyModeVisualActive` for range selection
- Copy: `y` reads selection via `ghostty_surface_read_selection()`, copies to pasteboard
- Exit: `Escape` or `q` → `ghostty_surface_clear_selection()`

State tracked separately from Ghostty's internal `has_selection` because copy mode always maintains a 1-cell selection as visible cursor indicator.

### A.6 Portal Pattern (AppKit Hit-Test Performance)

The terminal's AppKit container view (`WindowTerminalHostView`) overrides `hitTest()`:

```
hitTest(point) called on EVERY event (keyboard + mouse)

if event is pointer (mouse, scroll, drag):
    → Check sidebar resizer pass-through
    → Check split divider cursor (set resize cursor)
    → Check drag overlay routing policy
    → Return appropriate target view

if event is NOT pointer (keyboard):
    → Skip ALL divider/drag logic (fast path)
    → Return child view directly
```

**This guard is critical.** Without it, keyboard events would trigger expensive divider region collection and drag overlay checks on every keystroke. The pointer-only guard keeps keyboard latency at ~0ms overhead.

### A.7 Performance Instrumentation (DEBUG only)

```
NamuTypingTiming tracks per-keystroke:
  - Event delay (time from NSEvent timestamp to processing start)
  - Phase breakdown:
    1. ensureSurfaceReadyForInput
    2. dismissNotificationIfNeeded
    3. interpretKeyEvents / ghosttyKeyEvent
    4. ghostty_surface_key / ghostty_surface_text
    5. forceRefreshSurface
  - Total end-to-end latency

Logged if any phase > 1ms
```

---

## Appendix B: Domain Model — Detailed Type Definitions

### B.1 Workspace

```swift
// MosaicKit/Domain/Workspace.swift — pure value type
struct Workspace: Identifiable, Codable, Equatable {
    let id: UUID
    var title: String
    var customTitle: String?
    var isPinned: Bool = false
    var customColor: String?        // hex e.g. "#C0392B"
    var currentDirectory: String
    var portOrdinal: Int = 0        // assigned sequentially for MOSAIC_PORT env var
}
```

### B.2 Panel Protocol

```swift
@MainActor
protocol Panel: AnyObject, Identifiable, ObservableObject where ID == UUID {
    var id: UUID { get }
    var panelType: PanelType { get }
    var displayTitle: String { get }
    var displayIcon: String? { get }
    var isDirty: Bool { get }

    func close()
    func focus()
    func unfocus()
    func triggerFlash()

    // Focus intent routing — captures what sub-element has focus
    // (e.g., terminal surface vs find field, browser webview vs address bar)
    func captureFocusIntent(in window: NSWindow?) -> PanelFocusIntent
    func preferredFocusIntentForActivation() -> PanelFocusIntent
    func prepareFocusIntentForActivation(_ intent: PanelFocusIntent)
    @discardableResult func restoreFocusIntent(_ intent: PanelFocusIntent) -> Bool
    func ownedFocusIntent(for responder: NSResponder, in window: NSWindow) -> PanelFocusIntent?
    @discardableResult func yieldFocusIntent(_ intent: PanelFocusIntent, in window: NSWindow) -> Bool
}

enum PanelType: String, Codable, Sendable {
    case terminal, browser, markdown
}

enum PanelFocusIntent: Equatable {
    case panel
    case terminal(TerminalPanelFocusIntent)
    case browser(BrowserPanelFocusIntent)
}

enum TerminalPanelFocusIntent: Equatable {
    case surface      // terminal has keyboard focus
    case findField    // find-in-terminal field has focus
}

enum BrowserPanelFocusIntent: Equatable {
    case webView      // web content has focus
    case addressBar   // omnibar text field has focus
    case findField    // find-in-page field has focus
}
```

Focus intents are **captured** when switching away from a panel and **restored** when switching back. This ensures: if you were typing in the browser address bar, switched to a terminal, and switched back, the address bar regains focus — not the web content.

### B.3 Sidebar Metadata (per-workspace, observable)

```swift
@Observable final class SidebarMetadata {
    // Git state
    var gitBranch: GitBranchState?
    var panelGitBranches: [UUID: GitBranchState] = [:]

    // Pull request
    var pullRequest: PullRequestState?
    var panelPullRequests: [UUID: PullRequestState] = [:]

    // Status (key-value pairs set by agents/scripts via socket)
    var statusEntries: [String: StatusEntry] = [:]
    var metadataBlocks: [String: MetadataBlock] = [:]    // markdown blocks

    // Logging
    var logEntries: [LogEntry] = []

    // Progress
    var progress: ProgressState?    // 0.0-1.0 with optional label

    // Ports & TTY
    var surfaceListeningPorts: [UUID: [Int]] = [:]
    var surfaceTTYNames: [UUID: String] = [:]
    var listeningPorts: [Int] = []  // aggregated across all panels

    // Shell activity
    var panelShellActivityStates: [UUID: ShellActivityState] = [:]

    // Agent tracking
    var agentPIDs: [String: pid_t] = [:]   // status entry key → PID
}

struct GitBranchState: Equatable {
    let branch: String
    let isDirty: Bool
}

struct StatusEntry {
    let key: String
    let value: String
    let icon: String?
    let color: String?
    let url: URL?
    let priority: Int
    let format: MetadataFormat    // .plain or .markdown
    let timestamp: Date
}

struct LogEntry {
    let message: String
    let level: LogLevel           // .debug, .info, .warning, .error
    let source: String?
    let timestamp: Date
}

enum ShellActivityState: String {
    case idle, active
}
```

### B.4 Session Persistence — Complete Snapshot Hierarchy

```swift
struct AppSessionSnapshot: Codable, Sendable {
    var version: Int                        // schema version (currently 1)
    var createdAt: TimeInterval
    var windows: [WindowSnapshot]
}

struct WindowSnapshot: Codable, Sendable {
    var frame: RectSnapshot?                // window position/size
    var display: DisplaySnapshot?           // which monitor
    var tabManager: TabManagerSnapshot
    var sidebar: SidebarSnapshot
}

struct SidebarSnapshot: Codable, Sendable {
    var isVisible: Bool
    var selection: SidebarSelection         // .tabs or .notifications
    var width: Double?
}

struct TabManagerSnapshot: Codable, Sendable {
    var selectedWorkspaceIndex: Int?
    var workspaces: [WorkspaceSnapshot]
}

struct WorkspaceSnapshot: Codable, Sendable {
    var processTitle: String
    var customTitle: String?
    var customColor: String?
    var isPinned: Bool
    var currentDirectory: String
    var focusedPanelId: UUID?
    var layout: WorkspaceLayoutSnapshot     // recursive pane tree
    var panels: [PanelSnapshot]             // flat list of all panels
    var statusEntries: [StatusEntrySnapshot]
    var logEntries: [LogEntrySnapshot]
    var progress: ProgressSnapshot?
    var gitBranch: GitBranchSnapshot?
}

// Recursive layout tree
indirect enum WorkspaceLayoutSnapshot: Codable, Sendable {
    case pane(PaneLayoutSnapshot)           // leaf: panel tabs in a pane
    case split(SplitLayoutSnapshot)         // branch: two children with divider
}

struct PaneLayoutSnapshot: Codable, Sendable {
    var panelIds: [UUID]                    // tabs in this pane (order matters)
    var selectedPanelId: UUID?
}

struct SplitLayoutSnapshot: Codable, Sendable {
    var orientation: SplitOrientation       // .horizontal or .vertical
    var dividerPosition: Double             // 0.0-1.0 proportional
    var first: WorkspaceLayoutSnapshot      // left/top child
    var second: WorkspaceLayoutSnapshot     // right/bottom child
}

struct PanelSnapshot: Codable, Sendable {
    var id: UUID
    var type: PanelType
    var title: String?
    var customTitle: String?
    var directory: String?
    var isPinned: Bool
    var isManuallyUnread: Bool
    var gitBranch: GitBranchSnapshot?
    var listeningPorts: [Int]
    var ttyName: String?
    var terminal: TerminalPanelSnapshot?
    var browser: BrowserPanelSnapshot?
    var markdown: MarkdownPanelSnapshot?
}

struct TerminalPanelSnapshot: Codable, Sendable {
    var workingDirectory: String?
    var scrollback: String?                 // last N lines for restore
}

struct BrowserPanelSnapshot: Codable, Sendable {
    var urlString: String?
    var profileID: UUID?
    var shouldRenderWebView: Bool
    var pageZoom: Double
    var developerToolsVisible: Bool
    var backHistoryURLStrings: [String]?
    var forwardHistoryURLStrings: [String]?
}
```

**Persistence policy constants:**
- Autosave interval: 8 seconds
- Max windows per snapshot: 12
- Max workspaces per window: 128
- Max panels per workspace: 512
- Max scrollback lines per terminal: 4,000
- Max scrollback characters per terminal: 400,000
- Sidebar width range: 180–600 (default 200)

**Scrollback replay:** Captured scrollback is written to a temp file. The restored terminal's shell receives the file path via `MOSAIC_RESTORE_SCROLLBACK_FILE` env var. The shell integration script cats the file to restore visual state.

---

## Appendix C: Socket API — Complete Protocol Reference

### C.1 Server Setup

- **Path:** `~/.local/share/mosaic/mosaic.sock` (stable default)
- **Debug:** `/tmp/mosaic-debug.sock` or `/tmp/mosaic-debug-<tag>.sock`
- **Override:** `MOSAIC_SOCKET_PATH` or `MOSAIC_SOCKET` environment variable
- **Discovery:** Path written to `~/.local/share/mosaic/last-socket-path` for CLI lookup
- **Backlog:** 128 pending connections
- **Timeouts:** 5s read/write on client sockets; `SO_NOSIGPIPE` on macOS

### C.2 Protocol Detection

```
if line.hasPrefix("{") → JSON-RPC 2.0 (V2)
else                   → space-delimited text (V1 legacy)
```

### C.3 Access Control Modes

| Mode | Permissions | Verification |
|---|---|---|
| `off` | 0o600 | Socket disabled entirely |
| `localOnly` | 0o600 | PID ancestry check: client must be descendant of Mosaic process (via `LOCAL_PEERPID` + `sysctl KERN_PROC_PID` walk, up to 128 levels) |
| `automation` | 0o600 | Same UID only (no ancestry validation) |
| `password` | 0o600 | Requires `auth.login` with password before any command. Password from: (1) `MOSAIC_SOCKET_PASSWORD` env, (2) `~/.local/share/mosaic/socket-control-password` file |
| `allowAll` | 0o666 | No restrictions (any local process) |

### C.4 Focus Policy

Commands are classified as **focus-intent** or **non-focus**:

**Focus-intent commands** (may activate app/window, change in-app focus):
```
window.focus, workspace.select, workspace.next, workspace.previous,
workspace.last, surface.focus, pane.focus, pane.last,
browser.focus_webview, browser.focus, browser.tab.switch
```

**All other commands** must NOT steal macOS app focus or raise windows. Enforced via a stack-based policy: `shouldSuppressSocketCommandActivation()` returns true inside non-focus command handlers. Focus mutations (window ordering, NSApp activation, workspace selection) check this flag before proceeding.

### C.5 Threading Model

```
Background thread (per client):
  → Socket read loop
  → JSON parse + command dispatch
  → Access control checks
  → Parameter validation

Main actor (via DispatchQueue.main.async):
  → UI state mutations only
  → Workspace selection, panel focus, window management
  → @MainActor service method calls

Telemetry fast path (background, coalesced):
  → report_* commands: parse + dedupe off-main
  → Coalesce into batch update
  → Schedule single main-thread mutation
```

### C.6 V2 JSON-RPC Methods — Complete Reference

**Request format:** `{"id": <any>, "method": "<namespace.action>", "params": {<object>}}\n`
**Response format:** `{"id": <echo>, "ok": true, "result": {<object>}}\n` or `{"id": <echo>, "ok": false, "error": {"code": "<code>", "message": "<msg>"}}\n`

#### System

| Method | Params | Returns |
|---|---|---|
| `system.ping` | — | `{pong: true}` |
| `system.capabilities` | — | `{protocol, version, socket_path, access_mode, methods[]}` |
| `system.identify` | `caller?: {workspace_id?, surface_id?}` | Current focus state + caller validation |
| `system.tree` | `workspace_id?`, `all_windows?: bool` | Hierarchical window/workspace/pane/surface tree |

#### Auth

| Method | Params |
|---|---|
| `auth.login` | `password: string` |

#### Windows

| Method | Params |
|---|---|
| `window.list` | — |
| `window.current` | — |
| `window.focus` | `window_id: UUID` |
| `window.create` | — |
| `window.close` | `window_id: UUID` |

#### Workspaces

| Method | Params |
|---|---|
| `workspace.list` | `window_id?: UUID` |
| `workspace.create` | `window_id?`, `name?`, `initial_command?`, `working_directory?` |
| `workspace.select` | `workspace_id: UUID` |
| `workspace.current` | — |
| `workspace.close` | `workspace_id: UUID` |
| `workspace.move_to_window` | `workspace_id`, `window_id` |
| `workspace.reorder` | `workspace_id`, `index: int` |
| `workspace.rename` | `workspace_id`, `name: string` |
| `workspace.action` | `workspace_id`, `action: string` |
| `workspace.next` | — |
| `workspace.previous` | — |
| `workspace.last` | — |

#### Workspace Remote

| Method | Params |
|---|---|
| `workspace.remote.configure` | `workspace_id`, `destination`, `ssh_port?`, `identity_file?`, `ssh_options?[]`, `auto_connect?`, `relay_port?`, `relay_id?`, `relay_token? (64 hex chars)`, `local_socket_path?`, `terminal_startup_command?` |
| `workspace.remote.reconnect` | `workspace_id` |
| `workspace.remote.disconnect` | `workspace_id` |
| `workspace.remote.status` | `workspace_id` |
| `workspace.remote.terminal_session_end` | `workspace_id`, `surface_id`, `relay_port: 1-65535` |

#### Surfaces (Panels/Tabs)

| Method | Params |
|---|---|
| `surface.list` | `workspace_id?` |
| `surface.current` | — |
| `surface.focus` | `surface_id: UUID` |
| `surface.split` | `surface_id`, `direction: "horizontal"\|"vertical"` |
| `surface.create` | `workspace_id`, `direction?`, `type?`, `url?` |
| `surface.close` | `surface_id` |
| `surface.move` | `surface_id`, `pane_id` |
| `surface.reorder` | `surface_id`, `index: int` |
| `surface.send_text` | `surface_id`, `text: string` |
| `surface.send_key` | `surface_id`, `key: string` |
| `surface.clear_history` | `surface_id` |
| `surface.trigger_flash` | `surface_id` |
| `surface.refresh` | `surface_id` |
| `surface.health` | `surface_id` |
| `surface.read_text` | `surface_id` |
| `surface.drag_to_split` | `surface_id`, `target_pane_id`, `direction` |

#### Panes

| Method | Params |
|---|---|
| `pane.list` | `workspace_id?` |
| `pane.focus` | `pane_id: UUID` |
| `pane.surfaces` | `pane_id` |
| `pane.create` | `workspace_id`, `direction?`, `index?` |
| `pane.resize` | `pane_id`, `delta: float` (proportional) |
| `pane.swap` | `pane_id_a`, `pane_id_b` |
| `pane.break` | `pane_id` (extract to new window) |
| `pane.join` | `pane_id`, `target_pane_id`, `direction` |
| `pane.last` | — (focus previous pane) |

#### Notifications

| Method | Params |
|---|---|
| `notification.create` | `workspace_id`, `title`, `subtitle?`, `body?` |
| `notification.create_for_surface` | `surface_id`, `title`, `subtitle?`, `body?` |
| `notification.create_for_target` | `target: "current"\|UUID`, `title`, `subtitle?`, `body?` |
| `notification.list` | — |
| `notification.clear` | `workspace_id?`, `surface_id?` |

#### Browser Automation (80+ methods)

**Navigation & State:**

| Method | Params |
|---|---|
| `browser.open_split` | `workspace_id`, `url?`, `surface_id?` |
| `browser.navigate` | `surface_id`, `url` |
| `browser.back` | `surface_id` |
| `browser.forward` | `surface_id` |
| `browser.reload` | `surface_id` |
| `browser.url.get` | `surface_id` |
| `browser.focus` | `surface_id`, `selector` |
| `browser.focus_webview` | `surface_id` |

**Element Interaction:**

| Method | Params |
|---|---|
| `browser.click` | `surface_id`, `selector` |
| `browser.dblclick` | `surface_id`, `selector` |
| `browser.hover` | `surface_id`, `selector` |
| `browser.type` | `surface_id`, `selector`, `text` |
| `browser.fill` | `surface_id`, `selector`, `value` |
| `browser.press` | `surface_id`, `key` |
| `browser.check` / `uncheck` | `surface_id`, `selector` |
| `browser.select` | `surface_id`, `selector`, `value` |
| `browser.scroll` | `surface_id`, `selector?`, `x?`, `y?` |
| `browser.scroll_into_view` | `surface_id`, `selector` |

**Element Queries:**

| Method | Params |
|---|---|
| `browser.get.text` | `surface_id`, `selector` |
| `browser.get.html` | `surface_id`, `selector?` |
| `browser.get.value` | `surface_id`, `selector` |
| `browser.get.attr` | `surface_id`, `selector`, `attr` |
| `browser.get.title` | `surface_id` |
| `browser.get.count` | `surface_id`, `selector` |
| `browser.get.box` | `surface_id`, `selector` |
| `browser.get.styles` | `surface_id`, `selector` |
| `browser.is.visible` | `surface_id`, `selector` |
| `browser.is.enabled` | `surface_id`, `selector` |
| `browser.is.checked` | `surface_id`, `selector` |

**Element Finders:**

| Method | Params |
|---|---|
| `browser.find.role` | `surface_id`, `role` |
| `browser.find.text` | `surface_id`, `text` |
| `browser.find.label` | `surface_id`, `label` |
| `browser.find.placeholder` | `surface_id`, `placeholder` |
| `browser.find.testid` | `surface_id`, `testid` |
| `browser.find.first` / `last` / `nth` | `surface_id`, `selector`, `index?` |

**JavaScript & Evaluation:**

| Method | Params |
|---|---|
| `browser.eval` | `surface_id`, `expression` |
| `browser.wait` | `surface_id`, `selector`, `timeout?` |
| `browser.addinitscript` | `surface_id`, `script` |
| `browser.addscript` | `surface_id`, `path` |
| `browser.addstyle` | `surface_id`, `path` |
| `browser.highlight` | `surface_id`, `selector?` |

**Browser Tabs:**

| Method | Params |
|---|---|
| `browser.tab.new` | `surface_id` |
| `browser.tab.list` | `surface_id` |
| `browser.tab.switch` | `surface_id`, `index` |
| `browser.tab.close` | `surface_id`, `index` |

**Frames, Dialogs, Storage, Cookies:**

| Method | Params |
|---|---|
| `browser.frame.select` | `surface_id`, `name?`, `url?` |
| `browser.frame.main` | `surface_id` |
| `browser.dialog.accept` | `surface_id`, `text?` |
| `browser.dialog.dismiss` | `surface_id` |
| `browser.cookies.get/set/clear` | `surface_id`, `url?`, `cookies?` |
| `browser.storage.get/set/clear` | `surface_id`, `name?`, `value?` |

**Advanced:**

| Method | Params |
|---|---|
| `browser.screenshot` | `surface_id`, `path?` |
| `browser.snapshot` | `surface_id` |
| `browser.viewport.set` | `surface_id`, `width`, `height` |
| `browser.geolocation.set` | `surface_id`, `latitude`, `longitude`, `accuracy?` |
| `browser.offline.set` | `surface_id`, `offline: bool` |
| `browser.trace.start/stop` | `surface_id`, `path?` |
| `browser.network.route/unroute/requests` | `surface_id`, `url?`, `handler?` |
| `browser.console.list/clear` | `surface_id` |
| `browser.errors.list` | `surface_id` |
| `browser.input_mouse/keyboard/touch` | `surface_id`, `type`, coords/key |

#### Settings & Feedback

| Method | Params |
|---|---|
| `settings.open` | — |
| `feedback.open` | — |
| `feedback.submit` | `category`, `message` |

### C.7 Relay Authentication (HMAC-SHA256)

For SSH reverse-forwarded TCP connections (when Unix socket forwarding unavailable):

```
1. Server sends challenge:
   {"protocol": "mosaic-relay-auth", "version": 1, "relay_id": "<id>", "nonce": "<random>"}

2. Client computes:
   mac = HMAC-SHA256(token, "relay_id=<id>\nnonce=<nonce>\nversion=1")

3. Client sends:
   {"relay_id": "<id>", "mac": "<hex>"}

4. Server responds:
   {"ok": true} or {"ok": false}
```

Token stored in `~/.mosaic/relay/<port>.auth` (written by SSH session setup).

---

## Appendix D: Browser Panel — Implementation Detail

### D.1 WKWebView Configuration

```swift
let config = WKWebViewConfiguration()
config.processPool = sharedProcessPool          // shared across all browser panels
config.websiteDataStore = profileStore(for: profileID)  // isolated per profile
config.preferences.setValue(true, forKey: "developerExtrasEnabled")
config.defaultWebpagePreferences.allowsContentJavaScript = true

// Inject telemetry hooks at document start (all frames)
config.userContentController.addUserScript(telemetryBootstrap)
// Inject address bar focus tracking
config.userContentController.addUserScript(focusTrackingBootstrap)

let webView = MosaicWebView(frame: .zero, configuration: config)
webView.allowsBackForwardNavigationGestures = true
webView.isInspectable = true                    // enables DevTools
webView.customUserAgent = safariUserAgent       // Safari UA for compatibility
```

### D.2 First-Responder Hardening (MosaicWebView)

WKWebView aggressively tries to become first responder (via internal JavaScript focus events). Background panes must be prevented from stealing focus:

```swift
class MosaicWebView: WKWebView {
    var allowsFirstResponderAcquisition: Bool = true
    private var pointerFocusAllowanceDepth: Int = 0

    override func becomeFirstResponder() -> Bool {
        guard allowsFirstResponderAcquisition || pointerFocusAllowanceDepth > 0 else {
            return false   // BLOCK background pane from stealing focus
        }
        return super.becomeFirstResponder()
    }

    // Temporarily allow focus for pointer interactions (click, scroll)
    func withPointerFocusAllowance<T>(_ body: () -> T) -> T {
        pointerFocusAllowanceDepth += 1
        defer { pointerFocusAllowanceDepth -= 1 }
        return body()
    }
}
```

The view layer sets `allowsFirstResponderAcquisition = false` for unfocused panels and `true` for the active panel.

### D.3 Browser Profiles

Isolated browsing contexts with separate cookies, history, and data stores:

```swift
struct BrowserProfileDefinition: Codable {
    let id: UUID
    var displayName: String
    let createdAt: Date
    let isBuiltInDefault: Bool
}

// Each profile gets its own WKWebsiteDataStore (cookie/cache isolation)
// and its own BrowserHistoryStore
class BrowserProfileStore {
    func websiteDataStore(for profileID: UUID) -> WKWebsiteDataStore
    func historyStore(for profileID: UUID) -> BrowserHistoryStore
    func createProfile(named: String) -> BrowserProfileDefinition?
    func renameProfile(id: UUID, to: String) -> Bool
}
```

### D.4 Omnibar (Address Bar)

- Search engine selection: Google, DuckDuckGo, Bing, Kagi, Startpage (configurable)
- Inline URL completion from history
- Remote search suggestions (optional, privacy toggle)
- Keyboard navigation: up/down through suggestions, Enter to commit
- Suggestions dropdown positioned via `GeometryReader` coordinate space

### D.5 Popup Window Management

When JavaScript opens `window.open()`:
```swift
func createFloatingPopup(
    configuration: WKWebViewConfiguration,
    windowFeatures: WKWindowFeatures
) -> WKWebView? {
    let controller = BrowserPopupWindowController(
        configuration: configuration,
        windowFeatures: windowFeatures,
        openerPanel: self
    )
    popupControllers.append(controller)
    return controller.webView
}
```

Popups get their own `NSWindow` but share the opener's process pool and data store.

---

## Appendix E: Notification System — Implementation Detail

### E.1 Data Model

```swift
struct TerminalNotification: Identifiable {
    let id: UUID
    let workspaceId: UUID
    let surfaceId: UUID?
    let title: String
    let subtitle: String
    let body: String
    let createdAt: Date
    var isRead: Bool
}
```

### E.2 Ring System

Notifications track unread state at multiple granularities:

```
Global: total unreadCount → dock badge
Per workspace: unreadCountByWorkspaceId → sidebar badge number
Per workspace+surface: unreadByWorkspaceSurface → pane ring indicator (blue glow)
Per workspace latest: latestUnreadByWorkspaceId → sidebar preview text
```

The pane ring indicator (blue animated ring around a terminal pane) signals unread activity in that specific terminal without needing to look at the sidebar.

### E.3 Dock Badge

```
unreadCount == 0       → no badge
unreadCount <= 99      → "42"
unreadCount > 99       → "99+"
tagged debug build     → "tag:42" (identifies which build)
```

### E.4 Sound Settings

13 system sounds available: Default, Basso, Blow, Bottle, Frog, Funk, Glass, Hero, Morse, Ping, Pop, Purr, Sosumi. Plus: custom audio file, or silent.

### E.5 macOS UNUserNotificationCenter Integration

- Authorization requested on first notification attempt
- Category: `com.mosaic.app.userNotification` with "Show" action
- Off-main removal queue to prevent UI freezing when clearing many notifications

---

## Appendix F: Shell Integration — Hook Reference

Shell integration scripts (bundled in `Resources/shell-integration/`) install hooks into zsh, bash, and fish. They communicate with the app via Unix socket using `ncat` (preferred), `socat`, or `nc` fallback.

### F.1 Hooks Installed

| Hook | Shell Event | Socket Command | Purpose |
|---|---|---|---|
| **PWD reporting** | `chpwd` (zsh) / `PROMPT_COMMAND` (bash) | `report_pwd <dir> --tab=X --panel=Y` | Track working directory per panel |
| **TTY reporting** | Session start (once) | `report_tty <tty> --tab=X --panel=Y` | Register TTY for port scanner mapping |
| **Git branch** | `chpwd` + async background job | `report_git_branch <branch> [--dirty] --tab=X --panel=Y` | Sidebar git badge |
| **Pull request** | `chpwd` + async background job | `report_pr <number> <url> [--status=<status>] --tab=X --panel=Y` | Sidebar PR indicator (uses `gh pr view`) |
| **Port scan kick** | After command execution | `ports_kick --tab=X --panel=Y` | Trigger batched port detection |
| **Shell activity** | preexec/precmd | `report_shell_state <idle\|active> --tab=X --panel=Y` | Track if shell is running a command |
| **Ghostty semantic patch** | zsh precmd/preexec | Patches OSC 133 markers | Use `OSC 133;A;redraw=last` for prompt redraws to avoid extra blank lines |
| **WINCH guard** | `TRAPWINCH` | Emits spacer line | Prevent terminal resize from overwriting command output |
| **Git HEAD watcher** | Background file check | Re-reports branch on change | Detect branch switch without `chpwd` |

### F.2 Git Branch Detection (Without `git` Command)

For performance, branch detection reads `.git/HEAD` directly instead of running `git`:

```
1. Resolve .git path (supports worktrees: reads .git file → real .git dir)
2. Read HEAD file contents
3. If starts with "ref: refs/heads/" → extract branch name
4. Compute signature = mtime + content hash
5. Only report if signature changed since last check
6. Run `git status --porcelain` in background for dirty flag (with 20s timeout)
```

### F.3 Port Scanner — Batched Coalesce+Burst Algorithm

Instead of running `lsof` per panel, ports are scanned in batches:

```
1. Shell calls ports_kick → queued in pendingKicks set
2. 200ms coalesce timer fires → snapshot pending set
3. Burst sequence: 6 scans at [0.5s, 1.5s, 3s, 5s, 7.5s, 10s]
4. Each scan:
   a. ps -t tty1,tty2,... -o pid=,tty=     → {pid: tty}
   b. lsof -nP -a -p <pids> -iTCP -sTCP:LISTEN -F pn  → {pid: [ports]}
   c. Join on TTY → deliver per-panel port list
5. If new kicks arrive during burst → queue new coalesce after burst ends
```

This minimizes subprocess spawning while still catching ports that appear shortly after command execution.

---

## Appendix G: Remote Daemon — RPC Protocol Reference

### G.1 Transport

- JSON-RPC over stdin/stdout (newline-delimited)
- Max frame size: 4MB
- Entry points: `mosaic-remote serve --stdio` (RPC), `mosaic-remote cli <cmd>` (relay)

### G.2 RPC Methods

**Handshake:**
- `hello` → `{name, version, capabilities[]}` where capabilities = `["session.basic", "session.resize.min", "proxy.http_connect", "proxy.socks5", "proxy.stream", "proxy.stream.push"]`
- `ping` → `{pong: true}`

**Session Management (PTY):**
- `session.open` → `{session_id?}` — auto-generates ID if omitted (format: `sess-<uint64>`)
- `session.close` → `{session_id}`
- `session.attach` → `{session_id, attachment_id, cols, rows}` — register a view
- `session.detach` → `{session_id, attachment_id}` — remove a view
- `session.resize` → `{session_id, attachment_id, cols, rows}` — update view size
- `session.status` → `{session_id}` — returns current snapshot

### G.3 Resize Coordinator (Smallest-Screen-Wins)

```
if no attachments:
    keep lastKnownCols, lastKnownRows (preserve history)
else:
    effectiveCols = min(attachment.Cols for all attachments)
    effectiveRows = min(attachment.Rows for all attachments)
    ioctl(TIOCSWINSZ) to resize PTY
```

This ensures all connected views (e.g., phone + laptop viewing same session) see the same terminal size. History isn't shrunk when a small screen detaches.

### G.4 Proxy Streams (TCP Tunneling)

- `proxy.open` → `{host, port, timeout_ms?}` — opens TCP connection, returns `stream_id` (format: `s-<uint64>`)
- `proxy.close` → `{stream_id}` — close stream
- `proxy.write` → `{stream_id, data_base64, timeout_ms?}` — write data (base64-encoded), returns `{written: bytes}`
- `proxy.stream.subscribe` → `{stream_id}` — start async read pump (32KB buffer)

**Async events pushed to client:**
- `proxy.stream.data` → `{stream_id, data_base64}`
- `proxy.stream.eof` → `{stream_id}`
- `proxy.stream.error` → `{stream_id, error: string}`

### G.5 CLI Relay Command Table

The daemon also works as a CLI relay, translating local commands to socket JSON-RPC:

| CLI Command | Socket Method | Key Flags |
|---|---|---|
| `mosaic list-workspaces` | `workspace.list` | — |
| `mosaic new-workspace` | `workspace.create` | `--command`, `--working-directory`, `--name` |
| `mosaic select-workspace` | `workspace.select` | `--workspace` |
| `mosaic list-panels` | `surface.list` | `--workspace` |
| `mosaic focus-panel` | `surface.focus` | `--panel` |
| `mosaic new-split` | `surface.split` | `--surface`, `--direction` |
| `mosaic send` | `surface.send_text` | `--surface`, `--text` |
| `mosaic send-key` | `surface.send_key` | `--surface`, `--key` |
| `mosaic notify` | `notification.create` | `--title`, `--body`, `--workspace` |
| `mosaic browser open` | `browser.open_split` | `--url`, `--workspace` |
| `mosaic browser navigate` | `browser.navigate` | `--url`, `--surface` |
| `mosaic rpc <method> [json]` | passthrough | arbitrary JSON-RPC |

Flag mappings: `--workspace` → `workspace_id`, `--surface` → `surface_id`, `--panel` → `surface_id`, `--pane` → `pane_id`. Environment fallbacks: `MOSAIC_WORKSPACE_ID`, `MOSAIC_SURFACE_ID`.

---

## Appendix H: Ghostty Fork — Required Patches

Building on Ghostty requires these patches (maintained in a fork):

| # | Patch | Why |
|---|---|---|
| 1 | **OSC 99 (Kitty) notification parser** | Parse kitty-style desktop notifications from terminal programs |
| 2 | **macOS display link restart on display ID change** | Prevents frozen surfaces when vsync link starts before display ID is valid |
| 3 | **Keyboard copy mode C API** (`select_cursor_cell`, `clear_selection`) | Enables vim-style copy mode without mouse — these C functions were removed upstream |
| 4 | **macOS resize stale-frame mitigation** | Replays last rendered frame with top-left gravity during resize to reduce blank/scaled frames |
| 5 | **Zsh OSC 133;P for prompt redraws** | Distinguishes real prompt transitions (`OSC 133;A`) from async theme redraws (`OSC 133;P`) to avoid extra blank lines |
| 6 | **Zsh pure-style multiline prompt redraws** | Handles prompts with `\n%{\r%}` continuation (Pure theme) — avoids duplicate continuation markers |
| 7 | **Theme picker helper hooks** | Adds `zig build cli-helper` target; helper writes theme override to config and posts reload notification |

**Conflict hotspots on rebase:**
- `src/terminal/osc/parsers.zig` — keep kitty_notification import alongside iterm2
- `src/shell-integration/zsh/ghostty-integration` — OSC 133;A vs 133;P split
- `src/cli/list_themes.zig` — env-driven hooks vs stock Ghostty UI

---

## Appendix I: Keyboard Shortcuts — 31 Customizable Actions

| Category | Actions |
|---|---|
| **Sidebar/UI** | toggleSidebar, newTab (workspace), newWindow, closeWindow, openFolder, sendFeedback |
| **Notifications** | showNotifications, jumpToUnread, triggerFlash |
| **Workspace Nav** | nextSidebarTab, prevSidebarTab, renameTab, renameWorkspace, closeWorkspace |
| **Surfaces** | nextSurface, prevSurface, newSurface, toggleTerminalCopyMode |
| **Pane Navigation** | focusLeft, focusRight, focusUp, focusDown |
| **Split Management** | splitRight, splitDown, toggleSplitZoom |
| **Browser** | splitBrowserRight, splitBrowserDown, openBrowser, toggleBrowserDeveloperTools, showBrowserJavaScriptConsole |

**Storage:** Each binding stored as JSON in UserDefaults with key format `shortcut.<action>`:

```swift
struct StoredShortcut: Codable, Equatable {
    key: String,      // "A", "→", "\t", etc.
    command: Bool,    // ⌘
    shift: Bool,      // ⇧
    option: Bool,     // ⌥
    control: Bool     // ⌃
}
```

Interactive recorder view captures key combinations for rebinding.

---

## Appendix J: Command Palette — Two-Mode Design

### J.1 Modes

| Mode | Trigger | Behavior |
|---|---|---|
| **Commands** | `⌘K` | Fuzzy search across all registered commands (actions + workspace switcher) |
| **Rename** | Select "Rename" command | Text input field with current name pre-filled, confirm/cancel |

### J.2 Command Registration

Each command has:
```swift
struct CommandPaletteCommand {
    let id: String          // unique identifier
    let title: String       // display text
    let subtitle: String    // secondary text (e.g., keyboard shortcut hint)
    let action: () -> Void  // execution closure
    let isEnabled: Bool     // grayed out if false
}
```

### J.3 Usage History

Commands track `{lastUsedAt, usageCount}` per command ID. Fuzzy search results are boosted by recency and frequency. Stored in UserDefaults.

### J.4 Workspace Switcher

When the palette detects a query matching a workspace title, it shows workspace results alongside commands. Selecting a workspace result invokes `workspace.select`. Configurable: `searchAllSurfaces` (bool) controls whether individual surfaces are also searchable, not just workspaces.

### J.5 Overlay Mounting

The command palette is mounted as an AppKit overlay (not SwiftUI sheet) via `CommandPaletteOverlayContainerView` — an NSView injected into the window's content view hierarchy. This ensures it renders above portal-hosted terminal views during layout transitions.

---

## Appendix K: AppleScript Bridge

Scriptable object model:

```
Application
├── windows[] (ScriptWindow)
│   └── workspaces[] (ScriptTab)
│       └── terminals[] (ScriptTerminal)
└── terminals[] (flattened across all workspaces)
```

**Supported commands:**
- `make new window` → creates window, returns `ScriptWindow`
- `make new tab in <window>` → creates workspace, returns `ScriptTab`
- `perform action "<action>" on <terminal>` → executes binding action
- Property access: window IDs, workspace titles, terminal IDs

Gated by `isAppleScriptEnabled` preference. Returns `errAEEventNotPermitted` when disabled.

---

## Appendix L: Config File Parsing

### L.1 Load Order

Config files searched in order (all are optional, later values override earlier):

```
~/.config/ghostty/config
~/.config/ghostty/config.ghostty
~/Library/Application Support/com.mitchellh.ghostty/config
~/Library/Application Support/com.mitchellh.ghostty/config.ghostty
~/.config/mosaic/config
~/.config/mosaic/config.mosaic
```

### L.2 Supported Keys

| Key | Type | Default |
|---|---|---|
| `font-family` | String | "Menlo" |
| `font-size` | Float | 12 |
| `theme` | String | — |
| `working-directory` | String | — |
| `scrollback-limit` | Int | 10000 |
| `background` | Hex color | "#272822" |
| `background-opacity` | Double | 1.0 |
| `foreground` | Hex color | "#fdfff1" |
| `cursor-color` | Hex color | "#c0c1b5" |
| `cursor-text-color` | Hex color | "#8d8e82" |
| `selection-background` | Hex color | "#57584f" |
| `selection-foreground` | Hex color | "#fdfff1" |
| `palette` | "N=#hex" | ANSI 0-15 |
| `unfocused-split-opacity` | Double | 0.7 |
| `split-divider-color` | Hex color | — |
| `sidebar-background` | String | — (supports light:/dark: prefix) |

### L.3 Theme Resolution

Theme values support light/dark variants:

```
theme = light:Solarized Light,dark:Solarized Dark,Monokai
```

Resolution: pick theme matching current system appearance, fall back to unqualified value.

Theme search paths:
1. `~/.config/ghostty/themes/<name>`
2. `~/Library/Application Support/com.mitchellh.ghostty/themes/<name>`
3. Bundled `Resources/themes/<name>`

Theme files use the same key=value format as config files. Cached per color scheme.
