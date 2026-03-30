# Code Review Issues

Static review findings documented as repo-local issue writeups.

Last updated: 2026-03-30.

## Accepted Debt

- `accepted-architectural-debt.md` — architectural compromises currently accepted as trade-offs

## Historical / Dormant Issues

1. `001-gateway-websocket-not-implemented.md` — historical note for a dormant gateway design not present in the current checkout
2. `002-telegram-webhook-not-routed.md` — historical note for a dormant gateway design not present in the current checkout

## Resolved Issues

- Issues 003 and 005 were resolved and removed (workspace lifecycle centralized, dual layout state eliminated).
- `004-workspace-window-move-breaks-panel-state.md` — resolved 2026-03-29. `PanelManager.migrateWorkspace(id:to:)` now atomically transfers the layout engine and all panels when a workspace is moved between windows.

## Notes

- The current app ships local AI, outbound alert routing, and `RelayServer`-based remote forwarding.
- The gateway-focused issues above are preserved as archival architecture notes, not active defects in the shipped target.
