# Code Review Issues

Static review findings documented as repo-local issue writeups.

Last updated: 2026-03-29.

## Accepted Debt

- `accepted-architectural-debt.md` — architectural compromises currently accepted as trade-offs

## Open Issues

1. `001-gateway-websocket-not-implemented.md` — Critical (dormant — NamuGateway not in build target)
2. `002-telegram-webhook-not-routed.md` — High (dormant — NamuGateway not in build target)
4. `004-workspace-window-move-breaks-panel-state.md` — High (multi-window only)

## Notes

- Issues 003 and 005 were resolved and removed (workspace lifecycle centralized, dual layout state eliminated).
- Issues 001/002 affect NamuGateway which is not compiled in the main target. They remain as documentation for when the gateway module is activated.
- Issue 004 only affects multi-window workspace drag-out, not single-window usage.
