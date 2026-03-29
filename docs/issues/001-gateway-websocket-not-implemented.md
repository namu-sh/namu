# Gateway desktop connection cannot work end-to-end

- Severity: Critical
- Area: `NamuGateway`, `NamuKit/Gateway`
- Validation: Revalidated against current code on 2026-03-29
- Bucket: Needs architectural correction
- Priority note: Lower priority if `NamuGateway` remains inactive, but still inconsistent as written

## Summary

The desktop client opens a WebSocket connection, but the gateway server only implements a minimal HTTP request/response server. There is no WebSocket upgrade path, session registration flow, or persistent bidirectional transport.

## Evidence

- `NamuKit/Gateway/GatewayClient.swift:129` creates a WebSocket task with `URLSession.webSocketTask(with:)`.
- `NamuGateway/WebhookRouter.swift:52` documents `GET /ws` as a route, but `NamuGateway/WebhookRouter.swift:67` only routes `/telegram/webhook`, `/health`, and `/status`.
- `NamuGateway/WebhookRouter.swift:161` reads a single HTTP request and `NamuGateway/WebhookRouter.swift:226` closes the connection after sending a response.

## Impact

- Desktop-to-gateway alert delivery cannot become a persistent session.
- Gateway-to-desktop commands cannot be delivered over the advertised channel.
- Reconnect logic in the desktop client will churn against an endpoint that never upgrades.

## Suggested fix

- Either implement a real WebSocket server path in the gateway, including authentication, session registration, heartbeat handling, and message framing.
- Or change the desktop client to use the actual transport the gateway supports.
- Remove or update the `/ws` documentation until the transport exists.

## Acceptance criteria

- A desktop can establish an authenticated long-lived connection to the gateway.
- The gateway can push a command to the desktop over that connection.
- The desktop can send an alert or heartbeat over that same connection.
- Connection loss and reconnect behavior work against the real server implementation.
