# Accepted Architectural Debt

These are real architectural compromises, but currently justified by the product stage,
build structure, or Ghostty/AppKit integration constraints. They should stay visible,
but they are not the same class of problem as the active correction issues.

## 1. Single-target folder modules

- Status: Accepted debt
- Evidence: `project.yml:41`

`NamuKit` and `NamuUI` are compiled into the same app target, so folder boundaries are
organizational rather than compiler-enforced. This is explicitly documented in the repo
guide and appears to be an intentional pre-v2 trade-off.

## 2. AppKit in terminal/FFI paths

- Status: Accepted debt
- Evidence: `NamuKit/Terminal/GhosttyBridge.swift:1`, `NamuKit/Terminal/TerminalSession.swift:68`

Ghostty surface embedding requires AppKit/`NSView` participation. The codebase guide
explicitly allows AppKit in terminal/FFI code. This is a controlled exception, not a
clean-core violation by itself.

## 3. Some process-global callback routing for Ghostty C callbacks

- Status: Accepted debt
- Evidence: `NamuKit/Terminal/GhosttyBridge.swift:363`, `NamuKit/Terminal/GhosttyBridge.swift:606`

Ghostty C callbacks enter through process-global function pointers, which makes some
global lookup and app-level routing understandable. This is still debt, but it is more
of an integration constraint than a standalone design failure.

## 4. Derived `Workspace.paneTree` compatibility bridge

- Status: Accepted debt, with caveat
- Evidence: `NamuKit/Services/PanelManager.swift:403`

The mirrored `Workspace.paneTree` is explicitly treated as a compatibility bridge over
authoritative Bonsplit state. That bridge is intentional. However, when that mirrored
state becomes lossy persistence input, it stops being acceptable debt and becomes an
active correction issue.

## Caveat

Accepted debt is not the same as solved design. These items should be revisited when:

- `NamuKit` is split into a real package/target,
- Ghostty integration is refactored behind stronger adapter boundaries,
- layout persistence can switch fully to authoritative Bonsplit snapshots.
