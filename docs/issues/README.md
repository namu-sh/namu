# Code Review Issues

Static review findings documented as repo-local issue writeups.

Revalidated against the current codebase on 2026-03-29.

## Accepted Debt

- `docs/issues/accepted-architectural-debt.md` — architectural compromises currently accepted as trade-offs

## Resolved

3. `003-workspace-lifecycle-bypasses-panelmanager.md` — **Resolved** (was High)
5. `005-session-persistence-flattens-layout.md` — **Resolved** (was Medium)

## Needs Correction

1. `001-gateway-websocket-not-implemented.md` — Critical (dormant — NamuGateway not compiled in main target)
2. `002-telegram-webhook-not-routed.md` — High (dormant — NamuGateway not compiled in main target)
4. `004-workspace-window-move-breaks-panel-state.md` — High

## Notes

- These are based on current code review, not full end-to-end runtime validation.
- Severity reflects user impact and architectural risk.
- Suggested fixes are directional, not prescriptive.
- Some concerns previously raised as architectural problems are now bucketed as accepted debt
  rather than active correction items.
