import Foundation

/// Opaque identifier for tabs
struct TabID: Hashable, Codable, Sendable {
    let id: UUID

    init() {
        self.id = UUID()
    }

    init(uuid: UUID) {
        self.id = uuid
    }

    var uuid: UUID {
        id
    }

    init(id: UUID) {
        self.id = id
    }
}
