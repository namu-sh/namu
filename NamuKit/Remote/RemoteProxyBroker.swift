import Foundation

/// Singleton broker that multiplexes proxy tunnels by SSH target.
/// Two workspaces connecting to the same `user@host` share one tunnel.
final class RemoteProxyBroker {

    // MARK: - Public API

    enum Update {
        case connecting
        case ready(RemoteProxyEndpoint)
        case error(String)
    }

    /// Lease returned to callers — releasing it decrements the subscriber count.
    final class Lease {
        private let key: String
        private let subscriberID: UUID
        private weak var broker: RemoteProxyBroker?
        private var isReleased = false

        fileprivate init(key: String, subscriberID: UUID, broker: RemoteProxyBroker) {
            self.key = key
            self.subscriberID = subscriberID
            self.broker = broker
        }

        func release() {
            guard !isReleased else { return }
            isReleased = true
            broker?.release(key: key, subscriberID: subscriberID)
        }

        deinit {
            release()
        }
    }

    // MARK: - Singleton

    static let shared = RemoteProxyBroker()

    // MARK: - Internal entry per transport key

    private final class Entry {
        let configuration: RemoteConfiguration
        var remotePath: String
        var rpcClient: RemoteDaemonRPCClient?
        var tunnel: RemoteDaemonProxyTunnel?
        var endpoint: RemoteProxyEndpoint?
        var subscribers: [UUID: (Update) -> Void] = [:]
        var restartWorkItem: DispatchWorkItem?

        init(configuration: RemoteConfiguration, remotePath: String) {
            self.configuration = configuration
            self.remotePath = remotePath
        }
    }

    // MARK: - State

    private let queue = DispatchQueue(label: "com.namu.remote-ssh.proxy-broker", qos: .utility)
    private var entries: [String: Entry] = [:]

    // MARK: - Acquire / Release

    func acquire(
        configuration: RemoteConfiguration,
        remotePath: String,
        onUpdate: @escaping (Update) -> Void
    ) -> Lease {
        queue.sync {
            let key = configuration.proxyBrokerTransportKey
            let subscriberID = UUID()
            let entry: Entry
            if let existing = entries[key] {
                entry = existing
                if existing.remotePath != remotePath {
                    existing.remotePath = remotePath
                    if existing.tunnel != nil {
                        stopEntryRuntimeLocked(existing)
                        notifyLocked(existing, update: .connecting)
                    }
                }
            } else {
                entry = Entry(configuration: configuration, remotePath: remotePath)
                entries[key] = entry
            }

            entry.subscribers[subscriberID] = onUpdate
            if let endpoint = entry.endpoint {
                onUpdate(.ready(endpoint))
            } else {
                onUpdate(.connecting)
            }

            if entry.tunnel == nil, entry.restartWorkItem == nil {
                startEntryLocked(key: key, entry: entry)
            }

            return Lease(key: key, subscriberID: subscriberID, broker: self)
        }
    }

    private func release(key: String, subscriberID: UUID) {
        queue.async { [weak self] in
            guard let self, let entry = self.entries[key] else { return }
            entry.subscribers.removeValue(forKey: subscriberID)
            guard entry.subscribers.isEmpty else { return }
            self.teardownEntryLocked(key: key, entry: entry)
        }
    }

    // MARK: - Lifecycle helpers (all called on `queue`)

    private func startEntryLocked(key: String, entry: Entry) {
        entry.restartWorkItem?.cancel()
        entry.restartWorkItem = nil

        do {
            let rpcClient = RemoteDaemonRPCClient(
                configuration: entry.configuration,
                remotePath: entry.remotePath
            ) { [weak self] detail in
                self?.queue.async {
                    self?.handleRPCClientFailureLocked(key: key, detail: detail)
                }
            }
            try rpcClient.start()
            entry.rpcClient = rpcClient

            let tunnel = RemoteDaemonProxyTunnel(rpcClient: rpcClient)
            let port = try tunnel.start()
            entry.tunnel = tunnel

            let endpoint = RemoteProxyEndpoint(host: "127.0.0.1", port: port)
            entry.endpoint = endpoint
            notifyLocked(entry, update: .ready(endpoint))
        } catch {
            stopEntryRuntimeLocked(entry)
            let detail = "Failed to start remote proxy: \(error.localizedDescription)"
            notifyLocked(entry, update: .error("\(detail)\(Self.retrySuffix(delay: 2.0))"))
            scheduleRestartLocked(key: key, entry: entry, delay: 2.0)
        }
    }

    private func handleRPCClientFailureLocked(key: String, detail: String) {
        guard let entry = entries[key], entry.tunnel != nil else { return }
        stopEntryRuntimeLocked(entry)
        notifyLocked(entry, update: .error("\(detail)\(Self.retrySuffix(delay: 2.0))"))
        scheduleRestartLocked(key: key, entry: entry, delay: 2.0)
    }

    private func scheduleRestartLocked(key: String, entry: Entry, delay: TimeInterval) {
        guard !entry.subscribers.isEmpty else {
            teardownEntryLocked(key: key, entry: entry)
            return
        }
        guard entry.restartWorkItem == nil else { return }

        let workItem = DispatchWorkItem { [weak self] in
            guard let self, let currentEntry = self.entries[key] else { return }
            currentEntry.restartWorkItem = nil
            guard !currentEntry.subscribers.isEmpty else {
                self.teardownEntryLocked(key: key, entry: currentEntry)
                return
            }
            self.notifyLocked(currentEntry, update: .connecting)
            self.startEntryLocked(key: key, entry: currentEntry)
        }

        entry.restartWorkItem = workItem
        queue.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func teardownEntryLocked(key: String, entry: Entry) {
        entry.restartWorkItem?.cancel()
        entry.restartWorkItem = nil
        stopEntryRuntimeLocked(entry)
        entries.removeValue(forKey: key)
    }

    private func stopEntryRuntimeLocked(_ entry: Entry) {
        entry.tunnel?.stop()
        entry.tunnel = nil
        entry.rpcClient?.stop()
        entry.rpcClient = nil
        entry.endpoint = nil
    }

    private func notifyLocked(_ entry: Entry, update: Update) {
        let callbacks = Array(entry.subscribers.values)
        for callback in callbacks {
            DispatchQueue.main.async {
                callback(update)
            }
        }
    }

    // MARK: - Helpers

    private static func retrySuffix(delay: TimeInterval) -> String {
        let seconds = max(1, Int(delay.rounded()))
        return " (retry in \(seconds)s)"
    }
}
