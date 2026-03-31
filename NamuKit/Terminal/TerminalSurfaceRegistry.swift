import Foundation

/// Thread-safe registry mapping live Ghostty surface pointers to their owning session IDs.
///
/// Used by liveSurface() to cross-validate that a surface pointer still belongs to this
/// session, catching use-after-free scenarios where a pointer address is reused by a new
/// allocation before the old session has nil'd its reference.
final class TerminalSurfaceRegistry: @unchecked Sendable {

    static let shared = TerminalSurfaceRegistry()

    private let lock = NSLock()
    private var map: [UnsafeRawPointer: UUID] = [:]

    private init() {}

    /// Record a surface pointer → session ID mapping.
    func register(surface: ghostty_surface_t, ownerID: UUID) {
        let key = UnsafeRawPointer(surface)
        lock.lock()
        map[key] = ownerID
        lock.unlock()
    }

    /// Remove a surface pointer from the registry.
    func unregister(surface: ghostty_surface_t) {
        let key = UnsafeRawPointer(surface)
        lock.lock()
        map.removeValue(forKey: key)
        lock.unlock()
    }

    /// Returns the session ID that owns the given surface, or nil if not registered.
    func ownerID(for surface: ghostty_surface_t) -> UUID? {
        let key = UnsafeRawPointer(surface)
        lock.lock()
        defer { lock.unlock() }
        return map[key]
    }
}
