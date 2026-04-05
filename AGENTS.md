# AGENTS.md -- Namu Codebase Guide for AI Agents

This file is for AI coding agents (Claude, Codex, Copilot, etc.) working on the Namu codebase. It describes the project structure, build system, architectural decisions, conventions, and common tasks.

## Project Overview

Namu is a native macOS terminal multiplexer built on Ghostty (GPU-accelerated terminal via C FFI). It provides workspaces with split panes, a JSON-RPC socket API, a CLI tool, a built-in natural language AI control plane, outbound alert channels, and an authenticated TCP relay for remote access.

Key identity: Namu AI is a **NL control plane**, not an agent bridge or MCP wrapper. It interprets natural language, maps to socket commands, safety-checks, and executes.

## Directory Structure

```
namu/
  NamuKit/              Core logic -- NO UI imports (except AppKit for FFI)
    AI/                   LLM integration, command safety, conversation state, alert engine (4 trigger types)
      Providers/          ClaudeProvider, OpenAIProvider, GeminiProvider, CustomProvider
    Alerting/             Outbound alert channels: Slack, Telegram, Discord, webhook (credential security)
    Browser/              BrowserPanel, BrowserProfileStore, BrowserHistoryStore, MarkdownPanel (file watching),
                          BrowserControlling, 84+ browser automation commands
    Config/               Project configuration, directory trust, command execution
    Debug/                TypingTiming (keystroke latency profiling, 34 instrumentation points, always compiled)
    Domain/               Value types: Workspace (workspace placement), Panel, PaneTree, SessionSnapshot,
                          PanelFocusIntent enum (rich focus management), SidebarMetadata, PullRequestDisplay
    Extensions/           Small utilities (e.g. Comparable+Clamped)
    IPC/                  Socket server, dispatcher, registry, handler, middleware, access control, event bus
      Commands/           Handler files: Workspace, Pane, Surface, Sidebar, Notification, Browser, System, AI
      RelayServer.swift   Authenticated TCP relay (HMAC-SHA256) that proxies JSON-RPC to the dispatcher
    Scripting/            AppleScriptSupport (SDEF with 4 classes, 11 commands)
    Services/             WorkspaceManager, PanelManager, SessionPersistence, NotificationService, PortScanner
                          (batched ps+lsof, coalesce+burst), BonsplitLayoutEngine, LayoutEngine, AppearanceManager,
                          Analytics, WindowContext, VSCodeBridge, BrowserHistoryStore, BrowserProfileStore
    Terminal/             Ghostty C FFI: Bridge, Config, Keyboard, TerminalSession, ShellIntegration,
                          SessionState, CopyMode, SSHSessionDetector, ImageTransfer (Kitty graphics + SCP),
                          TerminalBackend, TerminalSurfaceRegistry (pointer safety with malloc_zone),
                          PortalHostLease system
  NamuUI/               SwiftUI + AppKit views
    AI/                   AIPreferencesView, AIChatPanelView
    App/                  NamuApp (@main), AppDelegate, ServiceContainer, NotificationPanelView
    Browser/              BrowserPanelView, 5 search engines with parallel suggest + history scoring
    CommandPalette/       CommandPaletteView
    Hints/                KeyboardHintOverlay
    Settings/             KeyboardShortcutSettings (32 configurable shortcuts), SettingsView
    Sidebar/              SidebarView, SidebarItemView, SidebarViewModel
    Terminal/             TerminalView, GhosttySurfaceView (NamuMetalLayer with GPU instrumentation),
                          FindOverlayView, NamuMetalLayer for Metal layer instrumentation
    Update/               UpdateController, UpdateViewModel, UpdatePopoverView, UpdateBadge, UpdateTitlebarAccessory
    Window/               WindowDecorationsController, WindowDragHandleView, WindowToolbarController
                          (traffic light management, custom drag handle)
    Workspace/            WorkspaceView, PaneTreeView
  CLI/                    namu CLI tool (flat aliases, 37 tmux-compat commands)
    Commands/             Subcommands: SplitWindow, ListPanes, SelectPane, CapturePane
  daemon/remote/         Remote helper for forwarded relay access (12 RPC methods)
  ghostty/                Ghostty submodule (manaflow-ai/ghostty fork)
  ghostty-stubs/          Stub C headers for building without full Ghostty
  vendor/bonsplit/        Bonsplit layout engine (submodule)
  Resources/              Info.plist, shell-integration scripts, bundled CLI, skills, 953 localization keys (19 languages)
  Scripts/                setup.sh (builds GhosttyKit xcframework)
  Tests/
    NamuKitTests/         Unit tests (Swift), including SurfaceSafetyTests
    NamuUITests/          UI tests (Swift)
    *.py                  Integration tests (Python)
  project.yml             XcodeGen project definition
```

## Build Commands

```bash
# Generate Xcode project from project.yml
xcodegen generate

# Build (debug)
xcodebuild -scheme Namu -configuration Debug build

# Build (release)
xcodebuild -scheme Namu -configuration Release build

# Run tests
xcodebuild -scheme Namu -configuration Debug test

# Setup Ghostty submodule + xcframework
./Scripts/setup.sh

# Compile a single Swift file (syntax check)
swiftc -typecheck -target arm64-apple-macos14.0 <file.swift>
```

## Test Commands

```bash
# All Swift tests
xcodebuild -scheme Namu -configuration Debug test

# Specific test class
xcodebuild -scheme Namu -configuration Debug \
  -only-testing:NamuTests/WorkspaceTests test

# Python integration tests (require running Namu instance)
python3 Tests/test_shell_integration.py
python3 Tests/test_v5_commands.py
```

## Key Architectural Decisions

1. **Clean architecture.** Namu uses established patterns (FFI, socket namespaces, portal, persistence) with modular design and clear separation of concerns.

2. **Single target, folder-based modules.** NamuKit is a folder group within the Xcode project, not a separate Swift package. Same compile unit but organized by domain. SPM extraction planned for pre-v2.

3. **No god objects.** Workspace is ~100 lines. PanelManager handles panel lifecycle. WorkspaceManager handles workspace lifecycle. Each has a clear, bounded responsibility.

4. **TerminalBackend protocol extracted.** `TerminalBackend` defines the abstraction boundary for terminal sessions. `TerminalSession` is the concrete Ghostty implementation. `SessionState` is an explicit state machine for session lifecycle (created → starting → running → exited → destroyed).

5. **Surface pointer safety.** `TerminalSurfaceRegistry` uses malloc_zone + registry cross-validation to detect dangling pointers. Tested against stack pointers and freed allocations in `SurfaceSafetyTests`.

6. **PortalHostLease system.** Manages portal host lifecycle and ensures consistent surface state across the app boundary.

7. **Port scanner as a service.** `PortScanner` batches ps+lsof calls, coalesces results, and publishes port.change events. Avoids rapid successive system calls.

8. **Browser isolation and profiles.** `BrowserProfileStore` maintains separate data stores per browser context. `BrowserHistoryStore` tracks visits with history scoring for search. Five search engines with parallel suggest.

9. **Keystroke latency always profiled.** `TypingTiming` is always compiled with 34 instrumentation points. Gated on env var but never disabled at compile time.

10. **Metal layer instrumentation.** `NamuMetalLayer` collects GPU drawable statistics for IPC diagnostics. `system.render_stats` exposes these metrics.

11. **Alert engine with trigger types.** AlertEngine supports 4 configurable rule-based trigger types. Credentials are stored securely with channel-specific validation.

12. **AI is the control plane.** NamuAI interprets natural language, emits structured tool_use calls, each mapping to exactly one socket command. It is not an agent bridge.

13. **Async by default for AI.** Acknowledge immediately, deliver results when ready. No real-time pressure.

14. **Tab pinning with session persistence.** `pane.pin` and `pane.unpin` persist to SessionSnapshot for cross-session state.

15. **Relay with HMAC-SHA256.** RelayServer uses constant-time HMAC-SHA256 for authentication, not a simple password.

## Ghostty FFI Patterns

The Ghostty C API is wrapped across three files, each with a clear domain:

| File | Domain | Key types |
|------|--------|-----------|
| `GhosttyBridge.swift` | Surface lifecycle, app lifecycle | `ghostty_app_t`, `ghostty_surface_t`, `ghostty_config_t` |
| `GhosttyConfig.swift` | Configuration reading/writing | `ghostty_config_*` C calls (~50 calls) |
| `GhosttyKeyboard.swift` | Keyboard input translation | `ghostty_input_key_s`, `ghostty_surface_key`, modifier translation |

The keyboard path is the hot path. GhosttyKeyboard must have zero allocations per keystroke.

Three-phase keyboard routing: `performKeyEquivalent` -> `keyDown` -> `interpretKeyEvents` (IME).

Display link defense: set display ID at surface creation AND re-assert on every focus gain.

## Important Conventions

### NamuKit has no UI imports
NamuKit must not import SwiftUI or UIKit. The only exception is AppKit imports in the Terminal/ FFI files that need NSView for Ghostty surface creation.

### SidebarItemView uses Equatable pattern
`SidebarItemView` uses the `.equatable()` modifier with precomputed `let` properties only. No `@EnvironmentObject` in SidebarItemView. This is critical for typing latency -- SwiftUI must be able to skip re-renders during keystroke processing.

### @MainActor on managers
`WorkspaceManager`, `PanelManager`, and all command handler classes (`WorkspaceCommands`, `PaneCommands`, etc.) are `@MainActor`. Socket parsing and validation happen off-main. Only UI mutations dispatch to main.

### CommandSafety is mandatory
Every command path from external sources (relay clients, hooks, future remote surfaces, LLM) must pass through `CommandSafety` before execution. Three levels:
- `safe` -- read-only (list, status, read_screen, ping)
- `normal` -- structural changes (create, delete, split, focus, resize)
- `dangerous` -- input injection (send_keys, send_text, execute_js)

Local dangerous commands: allowed with logging.
External dangerous commands: require confirmation.
Destructive patterns (rm -rf, dd if=, etc.): always require confirmation.
Rate limit: max 20 external commands per minute.

### PaneTree is immutable
`PaneTree` is an indirect enum (`case pane(Panel) | case split(direction, ratio, left, right)`). Methods return new trees; they do not mutate in place.

### Focus policy
Only `workspace.select` and `pane.focus` steal focus. All other socket commands preserve the current focus state.

### Socket path
Default: `/tmp/namu.sock`. Tagged debug builds: `/tmp/namu-<tag>.sock`.

### JSON-RPC 2.0
All IPC uses JSON-RPC 2.0. Requests have `id` (string or number). Notifications have no `id` (fire-and-forget). Events are pushed as notifications to subscribed clients.

## New Features in Latest Commit (101 Implemented)

### Notification Panel & Jump-to-Unread
- Notification panel UI with keyboard navigation (Cmd+Shift+I)
- Jump-to-unread command (Cmd+Shift+U, configurable)
- `notification.jump_to_unread` socket command
- Scrollback persistence with ANSI-safe truncation

### Layout Enhancements
- Workspace placement configuration (top/afterCurrent/end)
- Equalize splits with proportional leaf-count weighting (Cmd+Shift+=)
- `pane.equalize` socket command
- Tab-level pinning with session persistence (`pane.pin`, `pane.unpin`)

### New Panel Types
- Markdown panel with live file watching (`pane.new_markdown_tab`)
- Browser tab management (`pane.new_browser_tab`)
- Browser profiles with isolated data stores (separate cookie/localStorage per profile)
- BrowserHistoryStore with visit tracking and search scoring

### Terminal Safety & Performance
- TerminalSurfaceRegistry with malloc_zone + registry cross-validation
- PortalHostLease system for host lifecycle management
- PortScanner service with batched ps+lsof, coalesce and burst detection
- Keystroke latency profiling (34 instrumentation points, always compiled)
- GPU Metal layer instrumentation with IPC diagnostics (NamuMetalLayer, system.render_stats)

### Automation & Integration
- Image transfer pipeline: Kitty graphics protocol + SCP upload
- AppleScript SDEF with 4 classes and 11 commands
- Codex hook integration (install-hooks, uninstall-hooks, codex-hook events)
- OpenCode/omo subcommand support
- 37 tmux-compat commands via CLI bridge
- Claude hook events (10 types: session-start, prompt-submit, stop, etc.)
- Remote Go daemon with 12 RPC methods

### UI & Customization
- Window decorations controller (traffic light management)
- Custom drag handle (WindowDragHandleView)
- Window toolbar controller
- 32 configurable keyboard shortcuts in preferences
- 953 localization keys across 19 languages

### Browser & Search
- 5 search engines with parallel suggest + history scoring
- 84+ browser automation commands (comprehensive category coverage)
- Browser profile management and isolation
- BrowserHistoryStore with scoring algorithm

### Remote Access & Security
- TCP relay with HMAC-SHA256 authentication (constant-time comparison)
- RelayServer proxying JSON-RPC to CommandDispatcher
- Command middleware and safety levels
- PanelFocusIntent enum for rich focus management

### Alerting Enhancements
- Alert engine with 4 trigger types
- Slack, Telegram, Discord, and webhook channels
- Credential security with channel-specific validation
- Rule-based alert routing from EventBus

## Common Tasks

### Adding a new socket command

1. Choose the namespace (workspace, pane, surface, sidebar, notification, browser, system, ai).
2. Add the handler method to the appropriate `*Commands.swift` file in `NamuKit/IPC/Commands/`.
3. Register it in the `register(in:)` method with the `namespace.method` key.
4. Optionally add a `CommandMiddleware` for cross-cutting concerns (logging, auth, rate limiting).
5. Update `CommandSafety.safetyLevel(for:)` if the command name is not already classified.
6. Add the command to the CLI's valid namespaces if adding a new namespace.
7. Write a test in `Tests/NamuKitTests/`.

### Adding a new panel type

1. Define the new panel type case in `Panel.swift` (`PanelType` enum).
2. Create the panel's session/manager in `NamuKit/Services/`.
3. Create the SwiftUI view in `NamuUI/`.
4. Update `PaneTreeView.swift` to render the new panel type.
5. Update `SessionSnapshot.swift` for persistence if the panel has state.

### Adding a new LLM provider

1. Create a new file in `NamuKit/AI/Providers/`.
2. Conform to the `LLMProvider` protocol (`complete(messages:tools:) async throws -> Response`).
3. Register the provider in `AIPreferencesView` and `NamuAI`.

### Adding a new event type

1. Add a case to `NamuEvent` in `EventBus.swift` (or use `TypedEventBus` for type-safe events).
2. Publish the event from the appropriate service using `eventBus.publish(event:params:)`.
3. Document the event in the socket API reference.

## Files to Read First

When onboarding to this codebase, read these files in order:

1. `project.yml` -- project structure and build configuration
2. `NamuKit/Domain/Workspace.swift` -- core domain model
3. `NamuKit/Domain/PaneTree.swift` -- layout tree (indirect enum)
4. `NamuKit/Terminal/GhosttyBridge.swift` -- how Ghostty is embedded
5. `NamuKit/Terminal/SessionState.swift` -- session lifecycle state machine
6. `NamuKit/IPC/Models.swift` -- JSON-RPC types used everywhere
7. `NamuKit/IPC/CommandRegistry.swift` -- how commands are registered
8. `NamuKit/IPC/CommandHandler.swift` -- command handler protocol
9. `NamuKit/IPC/Commands/PaneCommands.swift` -- example command handler
10. `NamuKit/Services/BonsplitLayoutEngine.swift` -- Bonsplit-backed layout
11. `NamuKit/AI/CommandSafety.swift` -- safety classification system
12. `NamuKit/AI/NamuAI.swift` -- NL control plane core
13. `CLI/CLICommand.swift` -- tmux-compat command protocol
14. `CLI/main.swift` -- CLI tool entry point, hooks, and namespace dispatch

## Access Control Modes

The socket server supports five access control modes:

| Mode | Behavior |
|------|----------|
| `off` | All connections rejected |
| `localOnly` | Only child processes of Namu (PID ancestry check) |
| `automation` | Any local connection, marked as automation context |
| `password` | Challenge-response with constant-time password comparison |
| `allowAll` | Any local connection accepted |

## Event Types

The EventBus supports these events for server-push subscriptions:

| Event | Trigger |
|-------|---------|
| `process.exit` | A terminal process exits |
| `output.match` | Terminal output matches a subscribed pattern |
| `port.change` | Listening ports change (detected via port scanner) |
| `shell.idle` | Shell has been idle for a configured duration |
| `workspace.change` | Workspace created, deleted, selected, or modified |
