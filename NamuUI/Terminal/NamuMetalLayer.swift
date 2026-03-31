import QuartzCore

/// CAMetalLayer subclass that tracks drawable statistics for GPU diagnostics.
///
/// Always compiled. Statistics are always collected (lock-protected counters).
/// Active layers self-register in `NamuMetalLayer.all` so the `system.render_stats`
/// IPC command can query all surfaces without needing a view hierarchy walk.
final class NamuMetalLayer: CAMetalLayer {

    // MARK: - Global registry

    private static let registryLock = NSLock()
    private static var registry: [ObjectIdentifier: NamuMetalLayer] = [:]

    /// All currently active NamuMetalLayer instances.
    static var all: [NamuMetalLayer] {
        registryLock.lock()
        defer { registryLock.unlock() }
        return Array(registry.values)
    }

    // MARK: - Per-layer stats

    private let lock = NSLock()
    private(set) var drawableCount: Int = 0
    private(set) var lastDrawableTime: CFTimeInterval = 0

    // MARK: - Lifecycle

    override init() {
        super.init()
        NamuMetalLayer.registryLock.lock()
        NamuMetalLayer.registry[ObjectIdentifier(self)] = self
        NamuMetalLayer.registryLock.unlock()
    }

    override init(layer: Any) {
        super.init(layer: layer)
        NamuMetalLayer.registryLock.lock()
        NamuMetalLayer.registry[ObjectIdentifier(self)] = self
        NamuMetalLayer.registryLock.unlock()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        NamuMetalLayer.registryLock.lock()
        NamuMetalLayer.registry[ObjectIdentifier(self)] = self
        NamuMetalLayer.registryLock.unlock()
    }

    deinit {
        NamuMetalLayer.registryLock.lock()
        NamuMetalLayer.registry.removeValue(forKey: ObjectIdentifier(self))
        NamuMetalLayer.registryLock.unlock()
    }

    // MARK: - Drawable tracking

    override func nextDrawable() -> (any CAMetalDrawable)? {
        lock.lock()
        drawableCount += 1
        lastDrawableTime = CACurrentMediaTime()
        lock.unlock()
        return super.nextDrawable()
    }

    func debugStats() -> (count: Int, lastTime: CFTimeInterval) {
        lock.lock()
        defer { lock.unlock() }
        return (drawableCount, lastDrawableTime)
    }
}
