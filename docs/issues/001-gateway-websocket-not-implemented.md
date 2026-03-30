# Historical: gateway desktop connection could not work end-to-end

> Historical note: this issue refers to a dormant gateway design that is not part of the current checkout. The active remote-access path today is `NamuKit/IPC/RelayServer.swift` plus `daemon/remote/`.

- Severity: Historical
- Area: Dormant gateway design (`NamuGateway`, `NamuKit/Gateway`)
- Validation: Archived historical note on 2026-03-30
- Bucket: Needs architectural correction
- Priority note: Archived for historical context; not an active defect in the shipped target

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
