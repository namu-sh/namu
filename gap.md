# namu vs Namu: Code-Level Feature Parity Report

## Executive Summary

Both are native macOS terminal apps built on libghostty with the same Bonsplit split-pane engine. They share ~70% of core terminal functionality but diverge significantly in their strengths: **namu excels at browser automation and multi-channel alerting**, while **Namu excels at remote SSH relay, tmux compatibility, and UI polish**.

---

## 1. Terminal & Ghostty Integration

| Feature | namu | Namu | Winner |
|---------|:----:|:----:|--------|
| Ghostty surface lifecycle | Full (`GhosttyBridge.swift`, `TerminalSession.swift`) | Full (`GhosttyTerminalView.swift`) | Tie |
| Config handling | C API (full fidelity, all keys) | Swift parser (18 keys, can diverge) | **namu** |
| Surface pointer safety | No liveness check | `malloc_zone_from_ptr` guard | **Namu** |
| Font zoom inheritance | Reads `inherited_config` only | Reads runtime CTFont + post-create correction | **Namu** |
| `wait_after_command` / `initial_input` | Not exposed | Supported | **Namu** |
| Terminal find/search | Fixed top-right overlay, SwiftUI TextField | Draggable snap-to-corner, AppKit NSTextField, CJK IME guard | **Namu** |
| Vim copy mode | Full (h/j/k/l/w/b/0/$/v/y/G/gg/search/count/page-scroll) | Full (equivalent) | Tie |
| Keyboard abstraction | Clean `GhosttyKeyboard` module, zero-alloc | Inlined in view | **namu** |
| Keystroke latency profiling | None | `NamuTypingTiming` in DEBUG builds | **Namu** |
| Focus-follows-mouse | Reads Ghostty config, implemented | Not found | **namu** |
| GPU rendering | Standard CAMetalLayer | Debug-instrumented `GhosttyMetalLayer` + IOSurface testing | **Namu** |
| Kitty inline images | Full Kitty graphics protocol | Path insertion only | **namu** |

---

## 2. Workspace, Tabs & Splits

| Feature | namu | Namu | Winner |
|---------|:----:|:----:|--------|
| Workspace model | Value type `struct`, separate `PanelManager` | `ObservableObject` class, self-contained | Tie (tradeoffs) |
| Split panes (H/V) | Via Bonsplit + `LayoutEngine` protocol | Via Bonsplit direct | Tie |
| Directional focus nav | All 4 directions | All 4 directions | Tie |
| Equalize splits | Domain model exists, **no UI/IPC entry point** | Full: IPC + command palette + Ghostty action | **Namu** |
| Resize splits | IPC `pane.resize` + Ghostty bindings | IPC + command palette | Tie |
| Toggle zoom | IPC `pane.zoom`/`pane.unzoom` | IPC + command palette | Tie |
| Pane-internal tabs | `createTabInFocusedPane()` | Yes, multi-type (terminal/browser/markdown) | **Namu** |
| Panel types in splits | Terminal only (`[UUID: TerminalPanel]`) | Terminal + Browser + Markdown (`[UUID: any Panel]`) | **Namu** |
| Workspace placement | Always append to end | Configurable: top/afterCurrent/end | **Namu** |
| Auto-reorder on notification | Not implemented | Configurable, moves to top | **Namu** |
| Sidebar metadata | Git branch, dirty, PRs, ports, shell state, progress, custom k/v, markdown blocks | Git branch, dirty, PRs, ports, status entries, progress, log entries, metadata blocks | Tie |
| Sidebar shell state indicator | 5-state color dot (idle/prompt/running/commandInput/unknown) | 3-state (unknown/promptIdle/commandRunning) | **namu** |
| Workspace drag-and-drop | Reorder in sidebar | Reorder + cross-workspace tab transfer + move-to-window | **Namu** |
| Session persistence | Schema v3, 3 rotating backups, corrupt-file safety | Schema v1, no backups, no migration | **namu** |
| Session: scrollback save | Infrastructure exists but **always writes nil** | Saves up to 4000 lines / 400K chars with ANSI-safe truncation | **Namu** |
| Session: browser state | URL only | URL + profile + zoom + DevTools + back/forward history | **Namu** |
| Session: size limits | None | `maxWindows: 12`, `maxWorkspaces: 128`, `maxPanels: 512` | **Namu** |
| Pinned workspaces | Yes (`isPinned`) | Yes (`isPinned`) | Tie |
| Custom workspace colors | Yes | Yes | Tie |

---

## 3. Notifications & Alerting

| Feature | namu | Namu | Winner |
|---------|:----:|:----:|--------|
| OSC 9/99/777 detection | Shared Ghostty Zig parsers | Same | Tie |
| Pane attention ring | Blue ring, not configurable | Blue ring, enable/disable in settings | **Namu** |
| Sidebar unread badge | Red pill with count | Circle with count | Tie |
| **Notification panel UI** | **Missing** (data model exists, no view) | Full SwiftUI page (Cmd+I) | **Namu** |
| **Jump to unread** | **Missing** | Cmd+Shift+U, configurable | **Namu** |
| macOS native notifications | Basic `UNNotificationRequest` | Full lifecycle: auth state machine, focus suppression, categories, off-main removal | **Namu** |
| Sound options | 6 built-in | 17 + custom file + transcoding + custom shell command | **Namu** |
| Dock badge | Simple count | Count + tag prefix + 99+ cap | **Namu** |
| Claude hook notifications | 10 event types, PID-based suppression | Similar events, focus-based suppression | Tie |
| **Multi-channel alerting** | **Slack, Telegram, Discord, Webhook** with AlertRouter + AlertEngine | **None** | **namu** |
| **Rule-based alert triggers** | processExit, outputMatch, portChange, shellIdle | **None** | **namu** |
| **Keychain credential store** | Per-channel, actor-based | N/A | **namu** |
| Notification subscribe/unsubscribe IPC | Yes (`notification.subscribe`) | Not found | **namu** |

---

## 4. Browser & Panels

| Feature | namu | Namu | Winner |
|---------|:----:|:----:|--------|
| In-app browser | Yes (`NamuWebView`) | Yes (`NamuWebView`) | Tie |
| Address bar | Basic omnibar | Omnibar + 5 search engines + suggestions | **Namu** |
| Developer tools | **None** | Toggle shortcut + console shortcut | **Namu** |
| **Browser automation API** | **37 IPC commands** (click, type, hover, screenshot, cookies, storage, frames, viewport, download wait, init scripts) | ~10 basic commands | **namu** |
| `BrowserControlling` protocol | 40+ method protocol | None | **namu** |
| `BrowserAutomation` sequencer | 30+ action types with step delay | None | **namu** |
| Console log capture | JS injection at document start | None | **namu** |
| Download tracker | Async `waitForDownload` | None | **namu** |
| Cookie CRUD | Full (get/set/delete/clear) | None | **namu** |
| Browser history import | Safari, Chrome, Firefox, Arc, Edge, Brave | Referenced in tests | Tie |
| Markdown panel | **None** | Yes (`MarkdownPanel.swift`) | **Namu** |
| AI Chat panel | **Yes** (Claude, OpenAI, Gemini, Custom providers) | **None** | **namu** |
| Port scanner | Data model exists, **no scanner implementation** | Batched `ps+lsof` with coalesce+burst | **Namu** |
| SSH config parser | `~/.ssh/config` with glob patterns, Host/Hostname/Port/User/ProxyJump | None | **namu** |
| PR status in sidebar | Multi-PR per workspace with checks status | Single PR per workspace | **namu** |
| Keyboard shortcut customization | 13 actions | 30+ actions | **Namu** |
| Window decorations | Basic | Traffic light management, custom drag handle, toolbar controller | **Namu** |

---

## 5. CLI, Socket API & Extensibility

| Feature | namu | Namu | Winner |
|---------|:----:|:----:|--------|
| CLI architecture | Namespace-based (`namu workspace list`) | Flat (`Namu list-workspaces`) | Tie (preference) |
| Socket protocol | Clean JSON-RPC 2.0 only | Mixed v1 text + v2 JSON | **namu** |
| Command middleware | Safety levels (`safe`/`normal`/`dangerous`) + execution context | Inline checks | **namu** |
| Browser IPC commands | **38 commands** | ~10 commands | **namu** |
| AI IPC commands | `ai.message`, `ai.status`, `ai.history` | None | **namu** |
| Tmux compat layer | 4 commands | **24+ commands** | **Namu** |
| AppleScript | None | Full SDEF + scripting classes | **Namu** |
| App Intents (macOS 15+) | 8 intents (from Ghostty) | None | **namu** |
| Remote daemon | **None** | Go binary, HMAC auth, SOCKS5 proxy, reverse SSH | **Namu** |
| Remote relay zsh bootstrap | None | Full dotfile proxy chain | **Namu** |
| Codex integration | None | `Namu codex-hook` | **Namu** |
| OpenCode integration | None | `Namu omo` | **Namu** |
| Localization | ~7 strings, English only | 866 strings, EN+JP | **Namu** |
| Analytics consent | Explicit opt-in, no embedded keys | SDK-based, embedded API keys | **namu** (privacy) |

---

## Critical Gaps

### namu needs (from Namu)

1. **Notification panel UI** -- data model exists, just needs a view
2. **Jump-to-unread navigation** -- Cmd+Shift+U equivalent
3. **Scrollback persistence** -- save path writes nil despite infrastructure existing
4. **Port scanner** -- sidebar field exists but no scanner populates it
5. **Workspace placement options** -- always-append-to-end only
6. **Surface pointer safety** -- no `malloc_zone_from_ptr` guard
7. **Equalize splits wired to UI** -- domain model exists, no entry point
8. **Localization** -- ~7 strings vs 866

### Namu needs (from namu)

1. **Browser automation API** -- namu has 37 Playwright-like IPC commands vs ~10
2. **Multi-channel alerting** -- Slack/Telegram/Discord/Webhook with rule engine
3. **AI Chat panel** -- multi-provider in-app AI
4. **Kitty graphics protocol** -- inline terminal images
5. **SSH config parser** -- `~/.ssh/config` awareness
6. **Command safety middleware** -- structured safe/normal/dangerous levels
7. **AI IPC commands** -- `ai.message`/`ai.status`/`ai.history`

---

## Architectural Observations

- **namu is better factored**: separate `LayoutEngine` protocol, clean `GhosttyKeyboard` abstraction, value-type `Workspace`, JSON-RPC 2.0 only, command middleware with safety levels, typed event bus
- **Namu is more feature-complete**: 24x tmux compat, remote daemon, 866 localized strings, full AppleScript, richer session persistence, more keyboard shortcuts
- **Shared foundation**: same Ghostty fork, same Bonsplit vendor, same Sparkle updates, same fundamental split/tab/workspace model
