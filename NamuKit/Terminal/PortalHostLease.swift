import Foundation
import OSLog

private let logger = Logger(subsystem: "com.namu.app", category: "PortalHostLease")

/// A lease that prevents a Ghostty surface from being freed while a portal host
/// view is temporarily removed during SwiftUI split-pane rebuilds.
///
/// When SwiftUI rebuilds split pane layouts, it may remove and re-add views,
/// which would normally trigger surface destruction. Holding a lease defers
/// the free until the lease is released, preventing use-after-free crashes.
///
/// Usage:
///   let lease = session.acquireLease()
///   // ... SwiftUI rebuild in progress ...
///   session.releaseLease(lease)
struct PortalHostLease: Sendable {
    /// Unique identifier for this lease.
    let leaseID: UUID
    /// The session (surface) this lease protects.
    let surfaceID: UUID
    /// When the lease was acquired.
    let acquiredAt: Date

    init(surfaceID: UUID) {
        self.leaseID = UUID()
        self.surfaceID = surfaceID
        self.acquiredAt = Date()
    }
}

// MARK: - PortalHostLeaseManager

/// Thread-safe manager for active portal host leases.
/// One shared instance per app — TerminalSession queries this before freeing.
final class PortalHostLeaseManager: @unchecked Sendable {

    static let shared = PortalHostLeaseManager()

    /// Maximum duration a lease may be held before the reaper forcibly removes it.
    static let leaseTTL: TimeInterval = 30.0

    private let lock = NSLock()
    /// Active leases keyed by leaseID.
    private var leases: [UUID: PortalHostLease] = [:]

    /// Called on the main queue when a lease has been reaped.
    /// Receives the surfaceID of the expired lease so TerminalSession can
    /// complete any pending deferred destroy.
    var onLeaseExpired: ((UUID) -> Void)?

    private var reaperTimer: DispatchSourceTimer?

    private init() {
        startReaperTimer()
    }

    // MARK: - Public API

    /// Acquire a lease for the given surface ID.
    /// Returns the new lease — caller must retain it and pass it to `release(_:)`.
    func acquire(surfaceID: UUID) -> PortalHostLease {
        let lease = PortalHostLease(surfaceID: surfaceID)
        lock.lock()
        leases[lease.leaseID] = lease
        lock.unlock()
        return lease
    }

    /// Release a previously acquired lease.
    func release(_ lease: PortalHostLease) {
        lock.lock()
        leases.removeValue(forKey: lease.leaseID)
        lock.unlock()
    }

    /// Returns true if any active lease covers the given surface ID.
    func isLeaseActive(for surfaceID: UUID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return leases.values.contains { $0.surfaceID == surfaceID }
    }

    /// All active leases (for diagnostics).
    var activeLeases: [PortalHostLease] {
        lock.lock()
        defer { lock.unlock() }
        return Array(leases.values)
    }

    // MARK: - Reaper

    /// Remove all leases older than `leaseTTL` and fire `onLeaseExpired` for each.
    func reapExpiredLeases() {
        let now = Date()
        let cutoff = Self.leaseTTL
        var expired: [PortalHostLease] = []

        lock.lock()
        for (id, lease) in leases {
            let elapsed = now.timeIntervalSince(lease.acquiredAt)
            if elapsed > cutoff {
                expired.append(lease)
                leases.removeValue(forKey: id)
            }
        }
        lock.unlock()

        guard !expired.isEmpty else { return }

        for lease in expired {
            let elapsed = Date().timeIntervalSince(lease.acquiredAt)
            logger.warning("Portal lease expired for surface \(lease.surfaceID), held for \(String(format: "%.1f", elapsed))s")
        }

        let callback = onLeaseExpired
        DispatchQueue.main.async {
            for lease in expired {
                callback?(lease.surfaceID)
            }
        }
    }

    // MARK: - Private

    private func startReaperTimer() {
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        timer.schedule(deadline: .now() + 60, repeating: 60)
        timer.setEventHandler { [weak self] in
            self?.reapExpiredLeases()
        }
        timer.resume()
        reaperTimer = timer
    }
}
