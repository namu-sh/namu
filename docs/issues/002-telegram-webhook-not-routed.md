# Telegram webhook updates are not connected to any service

- Severity: High
- Area: `NamuGateway`
- Validation: Revalidated against current code on 2026-03-29
- Bucket: Needs architectural correction
- Priority note: Lower priority if `NamuGateway` remains inactive, but incomplete as written

## Summary

Incoming Telegram webhook updates are decoded and forwarded to a callback, but no callback is ever registered in the gateway bootstrap. The webhook endpoint currently accepts traffic without driving pairing, confirmation, or command routing.

## Evidence

- `NamuGateway/Channels/TelegramChannel.swift:127` forwards inbound messages only through `messageHandler`.
- `NamuGateway/Channels/TelegramChannel.swift:131` exposes `setMessageHandler(_:)` as the only integration point.
- `NamuGateway/main.swift:56` creates `TelegramChannel`, but there is no subsequent `setMessageHandler` call anywhere in the codebase.
- `NamuGateway/WebhookRouter.swift:82` passes webhook payloads directly to `telegramChannel.handleWebhookPayload(body)` and returns success.

## Impact

- Telegram commands appear accepted at the HTTP layer but do nothing.
- Inline-button confirmations cannot resolve pending actions.
- Pairing and remote-control flows are effectively incomplete.

## Suggested fix

- Introduce a coordinator service that owns `TelegramChannel`, `UserLinkService`, `SessionManager`, and gateway command routing.
- Register a `setMessageHandler` callback during startup.
- Make webhook handling fail visibly when routing dependencies are not configured.

## Acceptance criteria

- A Telegram message reaches an application-level handler.
- A callback query resolves a pending confirmation.
- An unlinked user gets pairing guidance instead of a silent no-op.
- The gateway logs meaningful routing events for inbound Telegram traffic.
