# Namu Feature Parity Improvements vs Namu

> Comprehensive gap analysis generated 2026-03-30 from deep investigation of both codebases.

## Table of Contents

- [Executive Summary](#executive-summary)
- [Priority Matrix](#priority-matrix)
- [1. SSH & Remote Workspaces](#1-ssh--remote-workspaces)
- [2. Terminal Input Handling](#2-terminal-input-handling)
- [3. Workspace UX & Pane Operations](#3-workspace-ux--pane-operations)
- [4. Notification System](#4-notification-system)
- [5. Browser Panel](#5-browser-panel)
- [6. CLI & API Ergonomics](#6-cli--api-ergonomics)
- [7. Configuration & Theming](#7-configuration--theming)
- [8. Window Management & Diagnostics](#8-window-management--diagnostics)
- [9. Agent & Third-Party Integrations](#9-agent--third-party-integrations)
- [10. Testing & Performance Infrastructure](#10-testing--performance-infrastructure)
- [Features Where Namu Leads](#features-where-namu-leads)
- [Implementation Roadmap](#implementation-roadmap)

---

## Executive Summary

**Total gaps identified: 89 features across 10 categories.**

| Category | Gaps | Critical | High | Medium | Low |
|----------|------|----------|------|--------|-----|
| SSH & Remote Workspaces | 8 | 3 | 3 | 2 | 0 |
| Terminal Input Handling | 5 | 1 | 2 | 2 | 0 |
| Workspace UX & Pane Ops | 11 | 2 | 4 | 3 | 2 |
| Notification System | 8 | 1 | 2 | 3 | 2 |
| Browser Panel | 7 | 0 | 3 | 3 | 1 |
| CLI & API Ergonomics | 5 | 1 | 2 | 1 | 1 |
| Configuration & Theming | 5 | 1 | 2 | 1 | 1 |
| Window Management & Debug | 10 | 1 | 3 | 4 | 2 |
| Agent Integrations | 6 | 1 | 2 | 2 | 1 |
| Testing Infrastructure | 12 | 2 | 4 | 4 | 2 |
| **Total** | **77** | **13** | **27** | **25** | **12** |

**Namu's unique advantages over Namu:** Alert engine (4 trigger types + 4 delivery channels), native multi-provider AI engine (Claude/OpenAI/Gemini), AppleScript SDEF automation, more sophisticated notification ring system (5 attention reasons vs 1), configurable user agent, network tracing API.

---

## Priority Matrix

### Legend
- **Complexity:** S (Small, <1 day) | M (Medium, 1-3 days) | L (Large, 3-7 days) | XL (Extra Large, 1-2 weeks)
- **Priority:** P0 (Critical) | P1 (High) | P2 (Medium) | P3 (Low)

| # | Feature | Priority | Complexity | Impact |
|---|---------|----------|------------|--------|
| 1 | Short ref IDs (workspace:N) | P0 | M | CLI usability |
| 2 | --no-focus flag | P0 | S | Agent automation |
| 3 | Config hot-reload (Cmd+Shift+,) | P0 | S | Developer workflow |
| 4 | Middle-click paste (X11) | P0 | S | Linux user UX |
| 5 | Status tracking API | P0 | L | Build monitoring |
| 6 | Window management APIs | P0 | M | Multi-window control |
| 7 | Claude Code hook integration | P0 | L | Agent ecosystem |
| 8 | Pane swap command | P1 | M | Power user workflow |
| 9 | Surface move between panes | P1 | M | Layout flexibility |
| 10 | Progress tracking API | P1 | M | CI/CD visibility |
| 11 | Remote workspace orchestration | P1 | XL | Remote dev |
| 12 | Find-in-page state restoration | P1 | S | Browser UX |
| 13 | HTTPS insecure bypass | P1 | M | Local dev |
| 14 | Git branch dirty flag | P1 | S | Sidebar info |
| 15 | Structured logging API | P2 | M | Observability |

---

## 1. SSH & Remote Workspaces

### Current State

Namu has the **Go daemon code** (100% identical to Namu) and **SSH session detection** (identical), but is **missing the entire Swift orchestration layer** that drives the remote workspace feature.

**What exists in namu:**
- `NamuKit/Terminal/SSHSessionDetector.swift` — SSH detection (identical to Namu)
- `NamuKit/Terminal/RemoteRelayZshBootstrap.swift` — Shell injection (identical to Namu)
- `daemon/remote/cmd/namud-remote/main.go` — Remote daemon RPC (identical to Namu)
- `NamuKit/Domain/SidebarMetadata.swift` — Remote metadata fields (display only)

**What's missing (~4,120 lines of Swift):**

### 1.1 Remote Configuration Struct
- **Priority:** P1 | **Complexity:** S
- **Namu ref:** `Sources/Workspace.swift` lines 4926-4972
- **Description:** `WorkspaceRemoteConfiguration` struct holding destination, port, identity file, SSH options, proxy port, relay credentials, socket path
- **Implementation:** Create `NamuKit/Domain/WorkspaceRemoteConfiguration.swift` with all connection parameters

### 1.2 Daemon Binary Manifest & Download
- **Priority:** P1 | **Complexity:** M
- **Namu ref:** `Sources/Workspace.swift` lines 192-215
- **Description:** Cross-platform manifest (goOS, goArch, downloadURL, sha256) for automatic daemon binary distribution and verification
- **Implementation:** Platform detection, SHA-256 verification, cached binary storage

### 1.3 Daemon RPC Client (Swift Wrapper)
- **Priority:** P1 | **Complexity:** L (~800 lines)
- **Namu ref:** `Sources/Workspace.swift` lines 1048-1834
- **Description:** Wraps stdio RPC protocol. Manages hello handshake, capability negotiation. Implements all session/proxy RPC methods.
- **Capabilities advertised by daemon:**
  - `session.basic` — Basic session management
  - `session.resize.min` — PTY resize coordination
  - `proxy.http_connect` — HTTP CONNECT proxy
  - `proxy.socks5` — SOCKS5 proxy
  - `proxy.stream` / `proxy.stream.push` — Raw stream proxy

### 1.4 Remote Proxy Broker
- **Priority:** P2 | **Complexity:** L (~250 lines)
- **Namu ref:** `Sources/Workspace.swift` lines 2456+
- **Description:** Singleton broker that multiplexes proxy connections by configuration key. Reuses daemon processes for same destination/port/identity.
- **Architecture:** Lease acquisition/release pattern, transport-key routing

### 1.5 Remote Proxy Tunnel (Stream Management)
- **Priority:** P2 | **Complexity:** L (~400 lines)
- **Namu ref:** `Sources/Workspace.swift` lines 1835+
- **Description:** Manages individual proxy stream lifecycle. Handles read/write buffering with base64 encoding. Emits stream events (data/EOF/error).
- **Protocol support:** SOCKS5, HTTP CONNECT, raw TCP

### 1.6 Remote Session Controller (Main Orchestrator)
- **Priority:** P1 | **Complexity:** XL (~1,800 lines)
- **Namu ref:** `Sources/Workspace.swift` lines 3172+
- **Description:** Main controller for remote workspace lifecycle. Manages daemon startup, verification, reconnection. Coordinates CLI relay. Tracks connection state.
- **SSH launch args:** BatchMode=yes, ServerAliveInterval=20, ServerAliveCountMax=2, ConnectTimeout=6, StrictHostKeyChecking=accept-new

### 1.7 CLI Relay Server
- **Priority:** P2 | **Complexity:** M (~500 lines)
- **Namu ref:** `Sources/Workspace.swift` lines 2692+
- **Description:** Local socket listener that relays CLI commands via SSH tunnel to remote daemon. HMAC-SHA256 challenge-response auth.

### 1.8 PTY Resize Coordination
- **Priority:** P1 | **Complexity:** M
- **Namu ref:** `daemon/remote/cmd/Namud-remote/main.go` lines 907-929
- **Description:** "Smallest screen wins" — uses minimum dimensions across all attached clients. Daemon code exists but namu's TerminalController doesn't call `session.attach`/`session.resize`/`session.detach`.
- **Implementation:** Add attachment lifecycle calls in terminal controller

---

## 2. Terminal Input Handling

### 2.1 Middle-Click Paste (X11-Style)
- **Priority:** P0 | **Complexity:** S (5-10 lines)
- **Namu ref:** `Sources/GhosttyTerminalView.swift` lines 6240-6260
- **namu status:** NOT IMPLEMENTED
- **Description:** `otherMouseDown()` handler checks `event.buttonNumber == 2`, sends `GHOSTTY_MOUSE_MIDDLE` to surface, calls `requestPointerFocusRecovery()`
- **Implementation:** Add `otherMouseDown()`/`otherMouseUp()` to `NamuUI/Terminal/GhosttySurfaceView.swift`

### 2.2 macOS Dictation Support
- **Priority:** P1 | **Complexity:** S
- **Namu ref:** `Sources/GhosttyTerminalView.swift` lines 5347-5352
- **namu status:** No explicit dictation routing
- **Description:** Third-party voice input apps inject text via single-argument `insertText:` action. Namu explicitly routes to `NSTextInputClient.insertText()` with `replacementRange: NSRange(location: NSNotFound, length: 0)`. Also handles dictation caret requests (zero-width ranges) in `firstRect()`.
- **Implementation:** Add voice input routing in GhosttySurfaceView, complete accessibility support

### 2.3 Clipboard Image Paste Enhancement
- **Priority:** P1 | **Complexity:** M
- **Namu ref:** `Sources/GhosttyTerminalView.swift` lines 256-412
- **namu status:** Basic `ImageTransfer.transferClipboardImage()` works but lacks sophistication
- **Description:** Namu's `GhosttyPasteboardHelper` provides:
  - Comprehensive format detection (TIFF, PNG, all image UTTypes)
  - TIFF-to-PNG conversion pipeline
  - RTFD rich text attachment extraction
  - 10MB size limit validation
  - Ownership tracking for temporary file cleanup safety
- **Implementation:** Port `GhosttyPasteboardHelper` pattern, add format conversion pipeline

### 2.4 CJK IME Improvements
- **Priority:** P2 | **Complexity:** M
- **Namu ref:** `Sources/GhosttyTerminalView.swift` lines 9523-9614
- **namu status:** Basic NSTextInputClient works, missing advanced features
- **Gaps:**
  - Keyboard layout change detection during composition (Namu lines 9556-9562)
  - Better IME popup positioning via `ghostty_surface_ime_point()`
  - `syncPreedit()` accumulation pattern for precise timing
- **Implementation:** Enhance `setMarkedText()` with layout detection, improve `firstRect()` positioning

### 2.5 Focus-Follows-Mouse Enhancement
- **Priority:** P2 | **Complexity:** S
- **Namu ref:** `Sources/GhosttyTerminalView.swift` lines 1970-1977, 6346-6376
- **namu status:** Basic implementation exists (lines 1060-1063, 509-523)
- **Gaps:**
  - Missing drag operation state tracking (prevents focus thrashing during drag)
  - Less comprehensive visibility/geometry checks
  - No handling for pressed mouse buttons during focus change
- **Implementation:** Add state guards matching Namu's `maybeRequestFirstResponderForMouseFocus()` checks

---

## 3. Workspace UX & Pane Operations

### 3.1 Git Branch Dirty State
- **Priority:** P1 | **Complexity:** S
- **Namu ref:** `Sources/Workspace.swift` lines 4887-4890, 6404-6429
- **namu status:** Has `gitBranch: String?` in SidebarMetadata but no dirty flag
- **Description:** Namu's `SidebarGitBranchState` includes `isDirty: Bool` to show uncommitted changes
- **Implementation:** Add `isDirty` to `SidebarMetadata.gitBranch`, update shell integration to report dirty state

### 3.2 Per-Panel Git Branches
- **Priority:** P2 | **Complexity:** M
- **Namu ref:** `Sources/Workspace.swift` lines 6404-6429
- **namu status:** Only workspace-level branch, no per-panel tracking
- **Description:** `panelGitBranches: [UUID: SidebarGitBranchState]` with `updatePanelGitBranch()` and `clearPanelGitBranch()`
- **Implementation:** Add dictionary to workspace model, update on panel shell state changes

### 3.3 PR Status Enhancement
- **Priority:** P2 | **Complexity:** M
- **Namu ref:** `Sources/Workspace.swift` lines 4974-5015
- **namu status:** Has `PullRequestDisplay` struct but limited integration
- **Gaps:** Per-panel PR tracking, command palette "Open All PRs" command, coalescing of metadata updates
- **Implementation:** Add `panelPullRequests` dictionary, command palette integration

### 3.4 Drag-to-Split Operations
- **Priority:** P1 | **Complexity:** M
- **Namu ref:** `Sources/TerminalController.swift` lines 2120, 4750-4796
- **namu status:** Only has `pane.split` command, no drag-to-split
- **Description:** `surface.drag_to_split` takes surface_id + direction (left/right/up/down), calls `bonsplitController.splitPane()` to move existing tab to new split
- **Implementation:** Register Bonsplit drag-to-split handler, add IPC command

### 3.5 Pane Swap
- **Priority:** P1 | **Complexity:** M
- **Namu ref:** `Sources/TerminalController.swift` lines 6228-6315
- **namu status:** CLI stub exists (`swap-pane` in main.swift) but NO backend implementation
- **Description:** Takes `pane_id` + `target_pane_id`. Creates placeholder surfaces for single-tab panes, swaps selected tabs between panes, cleans up placeholders.
- **Implementation:** Create `PaneCommands.swap()` with placeholder handling logic

### 3.6 Pane Break (Detach to New Workspace)
- **Priority:** P1 | **Complexity:** L
- **Namu ref:** `Sources/TerminalController.swift` lines 6317-6401+
- **namu status:** CLI stub exists but NO backend implementation
- **Description:** Detaches a surface from source pane, creates new workspace, attaches surface. Full rollback on failure.
- **Prerequisites:** Surface detach/attach infrastructure
- **Implementation:** Create detach/attach foundation, then implement `PaneCommands.break()` with rollback

### 3.7 Surface Reorder Within Pane
- **Priority:** P1 | **Complexity:** M
- **Namu ref:** `Sources/Workspace.swift` lines 8271-8282
- **namu status:** NOT IMPLEMENTED
- **Description:** `reorderSurface(panelId:toIndex:)` calls `bonsplitController.reorderTab()`, applies selection and geometry updates
- **Implementation:** Add Bonsplit tab reorder integration

### 3.8 Surface Move Between Panes
- **Priority:** P1 | **Complexity:** M
- **Namu ref:** `Sources/Workspace.swift` lines 8254-8268
- **namu status:** NOT IMPLEMENTED
- **Description:** `moveSurface(panelId:toPane:atIndex:focus:)` moves tab between panes with focus and geometry reconciliation
- **Implementation:** Add Bonsplit tab move integration

### 3.9 Surface Move Across Workspaces
- **Priority:** P2 | **Complexity:** L
- **Namu ref:** `Sources/TerminalController.swift` lines 4798-4830+
- **namu status:** NOT IMPLEMENTED
- **Description:** `surface.move` with flexible targeting (pane_id, workspace_id, window_id, before/after anchors)
- **Implementation:** Cross-workspace surface detach/reattach with state preservation

### 3.10 Surface Move Across Windows
- **Priority:** P3 | **Complexity:** L
- **Namu ref:** Same as 3.9, extends to cross-window moves
- **namu status:** NOT IMPLEMENTED (move workspace to window exists, but not individual surfaces)
- **Implementation:** Requires window management APIs (see section 8)

### 3.11 Workspace Reorder Enhancements
- **Priority:** P3 | **Complexity:** S
- **namu status:** COMPLETE — Both have drag reorder. Namu has visual feedback (opacity, border highlighting). No gap.

---

## 4. Notification System

### 4.1 Status Tracking API
- **Priority:** P0 | **Complexity:** L
- **Namu ref:** `Sources/TerminalController.swift` lines 1729-1760, `Sources/Workspace.swift` lines 115-144
- **namu status:** NOT IMPLEMENTED

**Data model:**
```swift
struct SidebarStatusEntry: Identifiable {
    let key: String           // unique identifier
    let value: String         // display text
    let icon: String?         // SF Symbol name
    let color: String?        // hex color #rrggbb
    let url: URL?             // clickable link
    let priority: Int         // sort order
    let format: SidebarMetadataFormat  // plain | markdown
    let timestamp: Date
}
```

**CLI commands:** `set-status <key> <value> [--icon --color --url --priority --format --workspace]`, `clear-status <key>`, `list-status`

**Display:** Colored pills in sidebar with icon, text, optional link. Essential for build monitoring, CI/CD integration, agent status.

### 4.2 Progress Tracking API
- **Priority:** P1 | **Complexity:** M
- **Namu ref:** `Sources/TerminalController.swift` lines 1771-1775, `Sources/Workspace.swift` lines 4882-4885
- **namu status:** NOT IMPLEMENTED

**Data model:**
```swift
struct SidebarProgressState {
    let value: Double   // 0.0 to 1.0
    let label: String?  // optional display text
}
```

**CLI commands:** `set-progress <0.0-1.0> [--label --workspace]`, `clear-progress`

**Display:** Progress bar in sidebar with optional label.

### 4.3 Structured Logging API
- **Priority:** P2 | **Complexity:** M
- **Namu ref:** `Sources/TerminalController.swift` lines 1762-1769, `Sources/Workspace.swift` lines 4865-4880
- **namu status:** NOT IMPLEMENTED

**Data model:**
```swift
enum SidebarLogLevel: String { case info, progress, success, warning, error }
struct SidebarLogEntry {
    let message: String
    let level: SidebarLogLevel
    let source: String?     // e.g., "build", "test"
    let timestamp: Date
}
```

**CLI commands:** `log [--level --source --workspace] -- <message>`, `clear-log`, `list-log [--limit]`

### 4.4 macOS System Notification Enhancements
- **Priority:** P2 | **Complexity:** S
- **Namu ref:** `Sources/TerminalNotificationStore.swift` lines 686-687
- **namu status:** Basic UNUserNotificationCenter exists
- **Gaps:** Notification category registration with "Show" action, off-main-thread notification removal, intelligent focus suppression (suppress when app is active AND notified pane is visible)

### 4.5 Custom Notification Sound File Picker
- **Priority:** P3 | **Complexity:** M
- **Namu ref:** `Sources/TerminalNotificationStore.swift` lines 32-425
- **namu status:** 15 system sounds + basic custom file support. Missing file picker UI, staged sound directory, background preparation queue, sound preview button.

### 4.6 Menu Bar Badge
- **Priority:** P3 | **Complexity:** S
- **Namu ref:** `Sources/AppDelegate.swift` lines 11660-11763
- **namu status:** NOT IMPLEMENTED
- **Description:** Menu bar icon shows unread count badge (1-9 exact, 10+ shows "99+"). Tag prefix support via `NAMU_TAG` env var.

### 4.7 Tab Highlighting for Unread
- **Priority:** P3 | **Complexity:** S
- **Namu ref:** `Sources/ContentView.swift` lines 1813, 5245
- **namu status:** Has workspace badge count but no visual highlight/dim effect on tabs with unread notifications

### 4.8 Blue Ring Visual Indicators
- **Priority:** N/A | **Complexity:** N/A
- **namu status:** EXCEEDS Namu. Namu has 5 attention reasons (navigation, notificationArrival, notificationDismiss, debug, manualUnreadDismiss) with distinct colors, opacities, and animations. Namu has single blue ring only.

---

## 5. Browser Panel

### 5.1 Find-in-Page State Restoration
- **Priority:** P1 | **Complexity:** S
- **Namu ref:** `Sources/Panels/BrowserPanel.swift` line 4873
- **namu status:** Has find-in-page but state resets on navigation
- **Description:** Namu's `restoreFindStateAfterNavigation()` replays search query on new pages, preserves search UI visibility
- **Implementation:** Add state management to BrowserSearchOverlay, replay on `didFinishNavigation`

### 5.2 Find-in-Page JavaScript Highlighting
- **Priority:** P1 | **Complexity:** S
- **Namu ref:** `Sources/Find/BrowserFindJavaScript.swift` lines 13-158
- **namu status:** Uses native `WKWebView.find()` on macOS 13+ with JS fallback
- **Description:** Namu uses custom TreeWalker DOM traversal with `<mark>` elements, yellow highlights (#facc15), orange current match (#f97316), smooth scrolling
- **Implementation:** Port JavaScript highlighting for richer UX, especially on older macOS

### 5.3 HTTPS Insecure HTTP Bypass
- **Priority:** P1 | **Complexity:** M
- **Namu ref:** `Sources/Panels/BrowserPanel.swift` lines 672-860
- **namu status:** NOT IMPLEMENTED
- **Description:** Pattern-based allowlist for insecure HTTP (default: localhost, 127.0.0.1, ::1, 0.0.0.0, *.localtest.me). One-time bypass per host. User confirmation dialog. Per-host allowlist management.
- **Implementation:** Port `BrowserInsecureHTTPSettings`, navigation delegate integration, alert factory

### 5.4 Remote Workspace Browser Proxy
- **Priority:** P1 | **Complexity:** M
- **Namu ref:** `Sources/Panels/BrowserPanel.swift` lines 29-32, 2703-2735
- **namu status:** Config struct has `proxyHost`/`proxyPort` fields but they're NOT applied
- **Description:** SOCKS5 + HTTP CONNECT proxy configuration via `URLSessionConfiguration.connectionProxyDictionary`. Applied when `usesRemoteWorkspaceProxy` is true.
- **Implementation:** Apply proxy config during webview setup, integrate with remote workspace state

### 5.5 Camera/Microphone Permission Handling
- **Priority:** P2 | **Complexity:** S (1 delegate method)
- **Namu ref:** `Sources/Panels/BrowserPanel.swift` lines 6369-6377
- **namu status:** No explicit handler; uses WKWebView defaults
- **Description:** WKUIDelegate `requestMediaCapturePermissionFor` returns `.prompt` to show system dialog
- **Implementation:** Add delegate method to BrowserPanel

### 5.6 Browser Theme Mode
- **Priority:** P2 | **Complexity:** S
- **Namu ref:** `Sources/Panels/BrowserPanel.swift` lines 156-212
- **namu status:** NOT IMPLEMENTED
- **Description:** System/light/dark theme injection via CSS media query override
- **Implementation:** Inject `prefers-color-scheme` CSS override based on app appearance

### 5.7 Network Mocking
- **Priority:** P3 | **Complexity:** N/A
- **Status:** NEITHER supports this — Namu explicitly returns `v2BrowserNotSupported("browser.network.route")` due to WKWebView limitation. Namu has network tracing (fetch/XHR interception) which Namu lacks. **No action needed.**

---

## 6. CLI & API Ergonomics

### 6.1 Short Ref ID System
- **Priority:** P0 | **Complexity:** M
- **Namu ref:** `CLI/Namu.swift` lines 2842-2983
- **namu status:** Uses full UUIDs only. `ref` field exists in responses but CLI doesn't parse compact notation.

**How it works:**
```
workspace:1, pane:2, surface:3  (kind:ordinal format)
```

**Resolution logic:**
1. `isHandleRef()` validates `<kind>:<digit>` format
2. `normalizeWorkspaceHandle()` accepts UUIDs, refs, or numeric indices
3. Fallback to index lookup: fetches list, matches by ordinal position

**Implementation:** Add ref parsing to `CLI/main.swift`, add normalization functions for workspace/pane/surface handles

### 6.2 --no-focus Flag
- **Priority:** P0 | **Complexity:** S
- **Namu ref:** `CLI/Namu.swift` lines 3855, 10685
- **namu status:** NOT IMPLEMENTED
- **Description:** Boolean flag for commands that typically focus results (new-workspace, break-pane, etc.). Sends `"focus": false` in RPC params.
- **Implementation:** Add flag parsing, pass `focus` parameter in affected commands

### 6.3 --id-format Flag
- **Priority:** P2 | **Complexity:** M
- **Namu ref:** `CLI/Namu.swift` lines 517-525, 8148-8156
- **namu status:** NOT IMPLEMENTED

**Options:** `refs` (default) | `uuids` | `both`

```swift
func textHandle(_ item: [String: Any], idFormat: CLIIDFormat) -> String {
    switch idFormat {
    case .refs:  return ref ?? id ?? "?"
    case .uuids: return id ?? ref ?? "?"
    case .both:  return [ref, id].compactMap({ $0 }).joined(separator: " ")
    }
}
```

### 6.4 Socket Security Model
- **Priority:** P2 | **Complexity:** L
- **Namu ref:** `Sources/SocketControlSettings.swift` lines 63-674, `CLI/Namu.swift` lines 533-650
- **namu status:** Basic socket server with access control, no authentication

**Namu three-level security:**
1. File-based auth (`~/.Namu/relay/<port>.auth` with relay_id + relay_token)
2. Environment variables (`NAMU_RELAY_ID`, `NAMU_RELAY_TOKEN`)
3. Keychain integration with file fallback (`~/.Namu/socket-control-password`)

**Socket control modes:** off | namuOnly | automation | password | allowAll

### 6.5 Dual V1+V2 Protocol Support
- **Priority:** P3 | **Complexity:** S
- **namu status:** Daemon supports both. CLI only uses JSON-RPC v2. V1 text protocol is legacy — low priority.

---

## 7. Configuration & Theming

### 7.1 Config Hot-Reload
- **Priority:** P0 | **Complexity:** S
- **Namu ref:** `Sources/NamuApp.swift` lines 6-7, `Sources/GhosttyTerminalView.swift` line 1834
- **namu status:** NOT IMPLEMENTED

**Implementation:**
1. Add menu item with `Cmd+Shift+,` shortcut
2. Call `ghostty_app_update_config(app, config)` for soft reload
3. Invalidate config load cache
4. Post `.ghosttyConfigDidReload` notification

### 7.2 Project Config File Watching
- **Priority:** P1 | **Complexity:** M
- **Namu ref:** `Sources/NamuConfig.swift` lines 260-600
- **namu status:** Reads `namu.json` at startup but no live watching
- **Description:** Namu uses `DispatchSourceFileSystemObject` to watch config files. Handles create/modify/delete/rename events. Automatic reload on changes.
- **Implementation:** Add file watcher to `NamuProjectConfig`, debounce and reload on changes

### 7.3 Sidebar Tint Light/Dark Mode Separation
- **Priority:** P1 | **Complexity:** S
- **Namu ref:** `Sources/GhosttyConfig.swift` lines 144-190
- **namu status:** Single color + opacity, no light/dark separation
- **Description:** Namu stores `sidebarTintHexLight` and `sidebarTintHexDark` separately, resolves based on current appearance
- **Implementation:** Add separate color pickers in AppearanceSettings, dual storage in UserDefaults

### 7.4 Menu Bar Visibility Toggle
- **Priority:** P2 | **Complexity:** S
- **Namu ref:** `Sources/NamuApp.swift` (settings toggle)
- **namu status:** No settings UI toggle for menu bar visibility
- **Implementation:** Add toggle in General settings, observe in AppDelegate

### 7.5 Telemetry System with Opt-Out
- **Priority:** P3 | **Complexity:** L
- **Namu ref:** `Sources/AppDelegate.swift` (Sentry integration)
- **namu status:** No telemetry system. This is actually a privacy advantage — only implement if crash reporting is needed.

---

## 8. Window Management & Diagnostics

### 8.1 Window Management APIs
- **Priority:** P0 | **Complexity:** M
- **Namu ref:** `Sources/TerminalController.swift` lines 3205-3279
- **namu status:** NO window APIs at all

**Missing APIs:**

| Method | Description |
|--------|-------------|
| `window.list` | Returns all windows with id, ref, index, workspace_count |
| `window.current` | Returns active window ID |
| `window.focus` | Focus window by ID |
| `window.create` | Create new main window |
| `window.close` | Close window by ID |

**Implementation:** Create `NamuKit/IPC/Commands/WindowCommands.swift`, wire to `NSApplication.shared.windows`

### 8.2 Layout Debug Visualization
- **Priority:** P1 | **Complexity:** M
- **Namu ref:** `Sources/TerminalController.swift` lines 10820-10831
- **namu status:** NOT IMPLEMENTED
- **Description:** `debug.layout` returns JSON tree of pane hierarchy with dimensions, positions, focus state, split directions
- **Implementation:** Bridge to Bonsplit layout tree, serialize to JSON

### 8.3 Window Screenshot Capture
- **Priority:** P1 | **Complexity:** S
- **Namu ref:** `Sources/TerminalController.swift` line 10919-10934
- **namu status:** NOT IMPLEMENTED
- **Description:** `debug.window.screenshot` captures entire window to PNG, returns path
- **Implementation:** `NSWindow.contentView?.bitmapImageRepForCachingDisplay`, write to temp file

### 8.4 Panel Snapshot with Pixel Change Detection
- **Priority:** P1 | **Complexity:** M
- **Namu ref:** `Sources/TerminalController.swift` lines 10889-10917, 12521-12580
- **namu status:** NOT IMPLEMENTED
- **Description:** Captures panel visual snapshot, tracks pixel changes between snapshots for visual regression detection. Returns: changed_pixels, width, height, path.

### 8.5 Bonsplit Debug Counter Integration
- **Priority:** P2 | **Complexity:** S
- **Namu ref:** `Sources/TerminalController.swift` lines 10840-10862
- **namu status:** Bonsplit debug code EXISTS in vendor but NOT integrated into IPC

**Commands to expose:**
- `debug.bonsplit_underflow.count` / `.reset`
- `debug.empty_panel.count` / `.reset`

### 8.6 Flash Counter Tracking
- **Priority:** P2 | **Complexity:** S
- **Namu ref:** `Sources/TerminalController.swift` lines 10874-10887
- **namu status:** NOT IMPLEMENTED
- **Description:** `debug.flash.count` per surface, `debug.flash.reset` all counters

### 8.7 Enhanced Render Stats
- **Priority:** P2 | **Complexity:** S
- **Namu ref:** `Sources/TerminalController.swift` lines 11856-11912
- **namu status:** Returns only layer_index, drawable_count, last_drawable

**Namu returns 13 additional fields:** drawCount, lastDrawTime, metalDrawableCount, metalLastDrawableTime, presentCount, lastPresentTime, layerClass, layerContentsKey, windowIsKey, windowOcclusionVisible, appIsActive, isActive, isFirstResponder

### 8.8 App Focus Override
- **Priority:** P2 | **Complexity:** S
- **Namu ref:** `Sources/TerminalController.swift` lines 6711-6747
- **namu status:** NOT IMPLEMENTED
- **Description:** `app.focus_override.set` (active/inactive/clear) and `app.simulate_active` for testing

### 8.9 Fullscreen Control API
- **Priority:** P3 | **Complexity:** M
- **Namu ref:** `Sources/ContentView.swift` lines 2439-2466
- **namu status:** Uses native macOS fullscreen only, no programmatic control API

### 8.10 Command Palette Debug APIs
- **Priority:** P3 | **Complexity:** M
- **Namu ref:** `Sources/TerminalController.swift` lines 10482-10722
- **namu status:** NOT IMPLEMENTED
- **Description:** 10+ debug commands for command palette: toggle, visible, selection, results, rename operations. Used for UI testing automation.

---

## 9. Agent & Third-Party Integrations

### 9.1 Claude Code Hook Integration
- **Priority:** P0 | **Complexity:** L (500-800 lines)
- **Namu ref:** `Resources/bin/claude` (97 lines), `CLI/Namu.swift` lines 2272-11201

**Architecture:**
1. Wrapper script at `Resources/bin/claude` intercepts Claude Code invocations
2. Injects `--session-id <UUID>` and `--settings <JSON>` flags
3. Registers 6 hook types: SessionStart, Stop, SessionEnd, Notification, UserPromptSubmit, PreToolUse
4. All hooks call `namu claude-hook <subcommand>` which dispatches to CLI
5. Session state stored at `~/.namu/claude-hook-sessions.json`

**RPC commands used:**
- `set_agent_pid claude_code <pid>`
- `set_status claude_code <value> --icon --color`
- `notify_target <workspace_id> <surface_id> <message>`
- `clear_notifications --tab=<id>`

**Environment variables to set:**
- `NAMU_CLAUDE_HOOKS_DISABLED` — Disable hook injection
- `NAMU_CLAUDE_PID` — Wrapper PID

### 9.2 Enhanced Environment Variables
- **Priority:** P1 | **Complexity:** M
- **Namu ref:** `Sources/SocketControlSettings.swift` lines 289-674, `Sources/GhosttyTerminalView.swift` lines 3518-3620
- **namu status:** Only 4 env vars (NAMU_SOCKET, NAMU_SHELL_INTEGRATION_DIR, NAMU_ZSH_ZDOTDIR, PATH)

**Missing env vars:**

| Variable | Purpose |
|----------|---------|
| `NAMU_SURFACE_ID` | UUID of current pane (for agent targeting) |
| `NAMU_WORKSPACE_ID` | UUID of workspace |
| `NAMU_PANEL_ID` | Alias for SURFACE_ID |
| `NAMU_TAB_ID` | Alias for WORKSPACE_ID |
| `NAMU_PORT` / `NAMU_PORT_END` / `NAMU_PORT_RANGE` | Port allocation per workspace |
| `NAMU_BUNDLED_CLI_PATH` | Path to bundled CLI binary |
| `NAMU_BUNDLE_ID` | Bundle identifier |
| `NAMU_SOCKET_PASSWORD` | Socket auth password |
| `NAMU_SOCKET_MODE` | Socket control mode |
| `NAMU_TAG` | Launch tag for debug builds |

### 9.3 Agent PID Tracking
- **Priority:** P1 | **Complexity:** S
- **Namu ref:** `Sources/TerminalController.swift` lines 1729-1750
- **namu status:** NOT IMPLEMENTED
- **Description:** `set_agent_pid <agent_name> <pid>` tracks running agents per surface. `clear_agent_pid <agent_name>` for cleanup.
- **Use case:** Status display, process monitoring, cleanup on workspace close

### 9.4 Socket Control Modes
- **Priority:** P2 | **Complexity:** M
- **Namu ref:** `Sources/SocketControlSettings.swift` lines 63-287
- **namu status:** Basic access control only
- **Description:** 5 modes: off, namuOnly, automation, password, allowAll. File permissions (0o600 restricted, 0o666 allowAll). Password auth via env or file.

### 9.5 Codex Hook Support
- **Priority:** P2 | **Complexity:** M
- **Namu ref:** `CLI/Namu.swift` lines 7158-12265
- **namu status:** NOT IMPLEMENTED
- **Description:** Similar to Claude hooks but for OpenAI Codex. Basic session-start, prompt-submit, stop events.

### 9.6 Session Lockfiles
- **Priority:** P3 | **Complexity:** S
- **Namu ref:** `Sources/SocketControlSettings.swift` lines 298-308
- **namu status:** NOT IMPLEMENTED
- **Description:** `~/.namu/last-socket-path` tracks previous socket for fallback reconnection. Atomic writes with directory creation (mode 0o700).

---

## 10. Testing & Performance Infrastructure

### Test Coverage Comparison

| Metric | Namu | namu | Gap |
|--------|------|------|-----|
| Python tests (v1+v2) | 178 | 7 | 171 |
| Swift unit tests | 30 files | 28 files | ~similar count, less scope |
| UI tests | 16 files (67KB max) | 12 files (10KB max) | 6-7x less comprehensive |
| SSH remote Docker e2e | 15 tests (5,591 LOC) | 0 | Complete gap |
| Visual screenshot tests | Full HTML reports | 0 | Complete gap |
| Stress profile tests | P95 budgeting | 0 | Complete gap |
| CPU monitoring tests | Full | 0 | Complete gap |

### 10.1 Python Test Framework Expansion
- **Priority:** P0 | **Complexity:** L
- **Namu ref:** `tests/Namu.py` (49,728 bytes), `tests_v2/Namu.py` (41,279 bytes)
- **namu status:** `Tests/namu.py` (7,887 bytes) — minimal IPC client
- **Description:** Namu's Python framework includes socket automation, workspace management, browser operations, CPU profiling, stress testing helpers

### 10.2 Visual Screenshot Testing
- **Priority:** P0 | **Complexity:** L
- **Namu ref:** `tests/test_visual_screenshots.py` (150+ lines)
- **namu status:** NOT IMPLEMENTED
- **Description:** Before/after screenshot capture, HTML report generation with embedded base64 images, state snapshot comparison, visual regression detection

### 10.3 Workspace Stress Profile Tests
- **Priority:** P1 | **Complexity:** M
- **Namu ref:** `NamuTests/WorkspaceStressProfileTests.swift`

**Config:**
```swift
struct StressConfig {
    let workspaceCount: Int              // 48
    let tabsPerWorkspace: Int            // 10
    let switchPasses: Int                // 6
    let createP95BudgetMs: Double?
    let switchP95BudgetMs: Double?
}
```

**Metrics collected:** count, averageMs, medianMs, p95Ms, maxMs, totalMs

### 10.4 CPU Usage Monitoring Tests
- **Priority:** P1 | **Complexity:** M
- **Namu ref:** `tests/test_cpu_usage.py`
- **Description:** Monitors idle CPU (threshold: 15%), detects runaway animations, continuous view updates, 3-second monitoring window with 0.5s sampling

### 10.5 SSH Remote Docker E2E Tests
- **Priority:** P1 (after remote workspace implementation) | **Complexity:** XL
- **Namu ref:** `tests_v2/test_ssh_remote_docker_*.py` (15 tests, 5,591 LOC)
- **Docker fixture:** Alpine Linux 3.20 with SSH, Python3, iproute2, HTTP/WebSocket fixture servers
- **Prerequisite:** Remote workspace orchestration (section 1)

### 10.6 Command Palette Fuzzy Search Tests
- **Priority:** P1 | **Complexity:** L
- **Namu ref:** `NamuTests/CommandPaletteSearchEngineTests.swift` (33,241 bytes)
- **namu status:** 74-line basic test only
- **Description:** 512-entry corpus tests, cancellation tests, performance benchmarks, single-character match tests, ranking validation

### 10.7 Command Palette Integration Tests
- **Priority:** P2 | **Complexity:** M
- **Namu ref:** 10+ tests in `tests_v2/test_command_palette_*.py`
- **Covers:** Fuzzy ranking, mode switching, navigation keys, typing stability, action sync, cross-window search, shortcut hints, rename operations, focus locking

### 10.8 Browser Automation Tests
- **Priority:** P2 | **Complexity:** M
- **Namu ref:** `tests_v2/test_browser_*.py` (multiple files)
- **namu status:** No browser automation tests

### 10.9 Network Simulation Tests
- **Priority:** P2 | **Complexity:** L
- **Namu ref:** Docker fixture with iproute2 for latency/bandwidth simulation
- **Prerequisites:** Docker fixture setup, SSH remote infrastructure

### 10.10 Sparkle Auto-Update Infrastructure
- **Priority:** P2 | **Complexity:** M
- **Namu ref:** `scripts/sparkle_generate_keys.sh` (61 lines), `scripts/sparkle_generate_appcast.sh`
- **namu status:** Manual update system only
- **Description:** ed25519 keypair generation, keychain storage, appcast signing, GitHub attestation verification

### 10.11 UI Test Recording & Replay
- **Priority:** P3 | **Complexity:** L
- **Namu ref:** Various UI test files with comprehensive interaction recording
- **namu status:** Basic UI tests without recording infrastructure

### 10.12 CI Self-Hosted Runner Validation
- **Priority:** P3 | **Complexity:** S
- **Namu ref:** `tests/test_ci_self_hosted_guard.sh`, `tests/test_ci_universal_release_settings.sh`
- **Description:** Validates build settings and self-hosted runner configuration before release

---

## Features Where Namu Leads

These are features namu has that Namu lacks:

| Feature | Description | Namu Implementation |
|---------|-------------|---------------------|
| **Alert Engine** | Rule-based pattern matching with 4 trigger types (process exit, output match, port change, shell idle) | `NamuKit/Services/AlertEngine.swift` |
| **Multi-Channel Alerting** | Slack, Telegram, Discord, Webhook delivery channels with rate limiting | `NamuKit/Services/AlertChannels/` |
| **Native AI Engine** | LLM-agnostic abstraction for Claude, OpenAI, Gemini with safety classification | `NamuKit/AI/NamuAI.swift` |
| **Multi-Provider LLM** | 3 providers, 10+ models, per-provider API key storage in Keychain | `NamuKit/AI/Providers/` |
| **AI Conversation Management** | Persistent session history, context collection, command mapping | `NamuKit/AI/ConversationManager.swift` |
| **Command Safety Classification** | Structured safe/normal/dangerous classification with destructive pattern detection | `NamuKit/AI/CommandSafety.swift` |
| **AppleScript SDEF** | 4 classes, 11 commands for macOS automation scripting | `Resources/Namu.sdef` |
| **Advanced Notification Rings** | 5 attention reasons with distinct colors, opacities, and animations | `NamuUI/Terminal/GhosttySurfaceView.swift` |
| **Configurable User Agent** | Per-webview custom user agent setting | `NamuKit/Browser/NamuWebView.swift` |
| **Network Tracing** | JavaScript-based fetch/XHR interception and tracing | `NamuKit/Browser/NamuWebView.swift` |

---

## Implementation Roadmap

### Phase 1: Quick Wins (Week 1-2)
High-impact, low-complexity items that immediately improve daily usage.

| Task | Priority | Complexity | Section |
|------|----------|------------|---------|
| Config hot-reload (Cmd+Shift+,) | P0 | S | 7.1 |
| Middle-click paste | P0 | S | 2.1 |
| --no-focus flag | P0 | S | 6.2 |
| Short ref IDs | P0 | M | 6.1 |
| Window management APIs | P0 | M | 8.1 |
| Git branch dirty flag | P1 | S | 3.1 |
| Find-in-page state restoration | P1 | S | 5.1 |
| Dictation support | P1 | S | 2.2 |
| Window screenshot capture | P1 | S | 8.3 |
| Bonsplit debug counter integration | P2 | S | 8.5 |

### Phase 2: Core Features (Week 3-5)
Essential features for power users and automation.

| Task | Priority | Complexity | Section |
|------|----------|------------|---------|
| Status tracking API | P0 | L | 4.1 |
| Claude Code hook integration | P0 | L | 9.1 |
| Pane swap | P1 | M | 3.5 |
| Surface move between panes | P1 | M | 3.8 |
| Surface reorder | P1 | M | 3.7 |
| Progress tracking API | P1 | M | 4.2 |
| HTTPS insecure bypass | P1 | M | 5.3 |
| Project config file watching | P1 | M | 7.2 |
| Enhanced environment variables | P1 | M | 9.2 |
| Drag-to-split | P1 | M | 3.4 |
| Layout debug visualization | P1 | M | 8.2 |

### Phase 3: Advanced Operations (Week 6-8)
Pane break, cross-workspace moves, remote foundations.

| Task | Priority | Complexity | Section |
|------|----------|------------|---------|
| Pane break (detach to new workspace) | P1 | L | 3.6 |
| Structured logging API | P2 | M | 4.3 |
| Surface move across workspaces | P2 | L | 3.9 |
| Socket security model | P2 | L | 6.4 |
| Remote daemon RPC client | P1 | L | 1.3 |
| Remote configuration struct | P1 | S | 1.1 |
| Remote daemon binary manifest | P1 | M | 1.2 |

### Phase 4: Remote Workspaces (Week 9-12)
Full remote workspace support.

| Task | Priority | Complexity | Section |
|------|----------|------------|---------|
| Remote session controller | P1 | XL | 1.6 |
| Remote proxy broker | P2 | L | 1.4 |
| Remote proxy tunnel | P2 | L | 1.5 |
| CLI relay server | P2 | M | 1.7 |
| PTY resize coordination | P1 | M | 1.8 |
| Remote browser proxy | P1 | M | 5.4 |

### Phase 5: Testing & Polish (Ongoing)
Test infrastructure and lower-priority improvements.

| Task | Priority | Complexity | Section |
|------|----------|------------|---------|
| Python test framework expansion | P0 | L | 10.1 |
| Visual screenshot testing | P0 | L | 10.2 |
| Stress profile tests | P1 | M | 10.3 |
| CPU usage monitoring | P1 | M | 10.4 |
| Command palette fuzzy search tests | P1 | L | 10.6 |
| Sparkle auto-update | P2 | M | 10.10 |

---

## Reference: Key File Locations

### Namu Implementation Files
| Component | File | Lines |
|-----------|------|-------|
| Window/Debug/Browser APIs | `Sources/TerminalController.swift` | 14,000+ |
| Workspace/Remote | `Sources/Workspace.swift` | 11,000+ |
| Terminal input | `Sources/GhosttyTerminalView.swift` | 9,600+ |
| Socket control | `Sources/SocketControlSettings.swift` | 675 |
| Config system | `Sources/NamuConfig.swift` | 617 |
| Ghostty config | `Sources/GhosttyConfig.swift` | 593 |
| SSH detection | `Sources/TerminalSSHSessionDetector.swift` | 808 |
| Notifications | `Sources/TerminalNotificationStore.swift` | 860+ |
| Remote daemon | `daemon/remote/cmd/Namud-remote/main.go` | 1,105 |
| Remote CLI relay | `daemon/remote/cmd/Namud-remote/cli.go` | 758 |
| CLI | `CLI/Namu.swift` | 12,000+ |

### namu Key Files to Modify
| Component | File |
|-----------|------|
| Terminal input | `NamuUI/Terminal/GhosttySurfaceView.swift` |
| IPC commands | `NamuKit/IPC/Commands/*.swift` |
| Sidebar metadata | `NamuKit/Domain/SidebarMetadata.swift` |
| Workspace model | `NamuKit/Domain/Workspace.swift` |
| Browser panel | `NamuKit/Browser/NamuWebView.swift` |
| Config system | `NamuKit/Config/NamuProjectConfig.swift` |
| Ghostty config | `NamuKit/Terminal/GhosttyConfig.swift` |
| Terminal session | `NamuKit/Terminal/TerminalSession.swift` |
| Socket server | `NamuKit/IPC/SocketServer.swift` |
| CLI | `CLI/main.swift` |
| Settings UI | `NamuUI/Settings/*.swift` |
| Sidebar UI | `NamuUI/Sidebar/*.swift` |
| Test framework | `Tests/namu.py` |
