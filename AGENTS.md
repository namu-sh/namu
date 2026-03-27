# AGENTS.md -- Namu Codebase Guide for AI Agents

This file is for AI coding agents (Claude, Codex, Copilot, etc.) working on the Namu codebase. It describes the project structure, build system, architectural decisions, conventions, and common tasks.

## Project Overview

Namu is a native macOS terminal multiplexer built on Ghostty (GPU-accelerated terminal via C FFI). It provides workspaces with split panes, a JSON-RPC socket API, a CLI tool, a built-in natural language AI control plane, and a Telegram gateway for remote alerts and commands.

Key identity: Namu AI is a **NL control plane**, not an agent bridge or MCP wrapper. It interprets natural language, maps to socket commands, safety-checks, and executes.

## Directory Structure

```
namu/
  NamuKit/              Core logic -- NO UI imports (except AppKit for FFI)
    AI/                   LLM integration, command safety, alert engine
      Providers/          ClaudeProvider, OpenAIProvider
    Domain/               Value types: Workspace, Panel, PaneTree, SessionSnapshot, SidebarMetadata
    Extensions/           Small utilities (e.g. Comparable+Clamped)
    Gateway/              Desktop-side gateway client and message models
    IPC/                  Socket server, dispatcher, registry, access control, event bus
      Commands/           Handler files: Workspace, Pane, Surface, Notification, Browser, System, AI
    Services/             WorkspaceManager, PanelManager, SessionPersistence, NotificationService, PortScanner
    Terminal/             Ghostty C FFI: Bridge, Config, Keyboard, TerminalSession, ShellIntegration
  NamuUI/               SwiftUI + AppKit views
    AI/                   AIPreferencesView
    App/                  NamuApp (@main), AppDelegate
    Browser/              (placeholder for browser panel views)
    CommandPalette/       CommandPaletteView
    Notifications/        (placeholder for notification views)
    Settings/             KeyboardShortcutSettings
    Sidebar/              SidebarView, SidebarItemView, SidebarViewModel
    Terminal/             TerminalView, TerminalPortalView, GhosttySurfaceView
    Workspace/            WorkspaceView, PaneTreeView
  NamuGateway/          Standalone gateway server (Hummingbird)
    Auth/                 GatewayAuth, MessageSigning
    Channels/             TelegramChannel
  CLI/                    namu CLI tool (namu.swift, main.swift)
  ghostty/                Ghostty submodule (manaflow-ai/ghostty fork)
  ghostty-stubs/          Stub C headers for building without full Ghostty
  Resources/              Info.plist, shell-integration scripts (zsh, bash)
  Scripts/                setup.sh (builds GhosttyKit xcframework)
  Tests/
    NamuKitTests/       Unit tests
    SocketTests/          Integration tests (CI only)
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
# All tests
xcodebuild -scheme Namu -configuration Debug test

# Specific test class
xcodebuild -scheme Namu -configuration Debug \
  -only-testing:NamuTests/WorkspaceTests test
```

Note: Socket integration tests in `Tests/SocketTests/` are CI-only and should not be run locally.

## Key Architectural Decisions

1. **Clean rewrite, not a fork.** Namu references Namu patterns (FFI, socket namespaces, portal, persistence) but shares no code. Namu had god objects (15K+ line files) and flat directory structure.

2. **Single target, folder-based modules.** NamuKit is a folder group within the Xcode project, not a separate Swift package. Same compile unit but organized by domain. SPM extraction planned for pre-v2.

3. **No god objects.** Workspace is ~100 lines. PanelManager handles panel lifecycle. WorkspaceManager handles workspace lifecycle. Each has a clear, bounded responsibility.

4. **Concrete types for v1.** TerminalSession is a concrete class wrapping Ghostty, not a protocol. Protocol extraction (`TerminalBackend`) deferred to pre-v2 when iOS `RelayBackend` requirements inform the abstraction boundary.

5. **AI is the control plane.** NamuAI interprets natural language, emits structured tool_use calls, each mapping to exactly one socket command. It is not an agent bridge.

6. **Async by default for AI.** Acknowledge immediately, deliver results when ready. No real-time pressure.

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
Every command path from external sources (Telegram, LLM) must pass through `CommandSafety` before execution. Three levels:
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

## Common Tasks

### Adding a new socket command

1. Choose the namespace (workspace, pane, surface, notification, browser, system, ai).
2. Add the handler method to the appropriate `*Commands.swift` file in `NamuKit/IPC/Commands/`.
3. Register it in the `register(in:)` method with the `namespace.method` key.
4. Update `CommandSafety.safetyLevel(for:)` if the command name is not already classified.
5. Add the command to the CLI's valid namespaces if adding a new namespace.
6. Write a test in `Tests/NamuKitTests/`.

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

1. Add a case to `NamuEvent` in `EventBus.swift`.
2. Publish the event from the appropriate service using `eventBus.publish(event:params:)`.
3. Document the event in the socket API reference.

## Files to Read First

When onboarding to this codebase, read these files in order:

1. `project.yml` -- project structure and build configuration
2. `NamuKit/Domain/Workspace.swift` -- core domain model
3. `NamuKit/Domain/PaneTree.swift` -- layout tree (indirect enum)
4. `NamuKit/Terminal/GhosttyBridge.swift` -- how Ghostty is embedded
5. `NamuKit/IPC/Models.swift` -- JSON-RPC types used everywhere
6. `NamuKit/IPC/CommandRegistry.swift` -- how commands are registered
7. `NamuKit/IPC/Commands/PaneCommands.swift` -- example command handler
8. `NamuKit/AI/CommandSafety.swift` -- safety classification system
9. `NamuKit/AI/NamuAI.swift` -- NL control plane core
10. `CLI/namu.swift` -- CLI tool (self-contained, good overview of the API)

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
