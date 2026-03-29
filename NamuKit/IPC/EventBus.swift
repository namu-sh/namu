import Foundation

// MARK: - Event Types

enum NamuEvent: String, CaseIterable, Sendable {
    case processExit      = "process.exit"
    case outputMatch      = "output.match"
    case portChange       = "port.change"
    case shellIdle        = "shell.idle"
    case workspaceChange  = "workspace.change"
}

// MARK: - Event Payload

struct NamuEventPayload: Sendable {
    let event: NamuEvent
    let params: JSONRPCParams?
}

// MARK: - EventBus

/// Thread-safe in-process pub/sub bus.
/// Subscribers receive events as JSON-RPC notifications pushed to their write closure.
final class EventBus: @unchecked Sendable {
    typealias NotificationWriter = @Sendable (Data) -> Void

    private struct Subscription {
        let id: UUID
        let events: Set<NamuEvent>
        let writer: NotificationWriter
    }

    private let lock = NSLock()
    private var subscriptions: [UUID: Subscription] = [:]
    private let encoder = JSONEncoder()

    // MARK: - Subscribe / Unsubscribe

    /// Subscribe a client to a set of events. Returns a subscription ID for later removal.
    @discardableResult
    func subscribe(events: Set<NamuEvent>, writer: @escaping NotificationWriter) -> UUID {
        let id = UUID()
        let sub = Subscription(id: id, events: events, writer: writer)
        lock.withLock { subscriptions[id] = sub }
        return id
    }

    /// Unsubscribe using the ID returned from `subscribe`.
    func unsubscribe(_ id: UUID) {
        lock.withLock { subscriptions.removeValue(forKey: id) }
    }

    // MARK: - Publish

    /// Publish an event to all subscribers that are listening for it.
    func publish(_ payload: NamuEventPayload) {
        let notification = JSONRPCNotification(method: payload.event.rawValue, params: payload.params)
        guard let data = try? encoder.encode(notification) else { return }

        let writers: [NotificationWriter] = lock.withLock {
            subscriptions.values
                .filter { $0.events.contains(payload.event) }
                .map { $0.writer }
        }

        for writer in writers {
            writer(data)
        }
    }

    /// Convenience: publish with an object-params dictionary.
    func publish(event: NamuEvent, params: [String: JSONRPCValue] = [:]) {
        publish(NamuEventPayload(
            event: event,
            params: params.isEmpty ? nil : .object(params)
        ))
    }

    // MARK: - Introspection

    var subscriberCount: Int {
        lock.withLock { subscriptions.count }
    }
}