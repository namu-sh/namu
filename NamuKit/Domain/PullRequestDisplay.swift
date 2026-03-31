import Foundation

/// The lifecycle state of a pull request.
enum PRState: String, Codable, Equatable {
    case open
    case merged
    case closed
}

/// The CI checks status for a pull request.
enum PRChecksStatus: String, Codable, Equatable {
    case pass
    case fail
    case pending
    case none
}

/// Display model for a pull request shown in the sidebar.
struct PullRequestDisplay: Equatable {
    let number: Int
    let state: PRState
    let url: String
    let branch: String
    let checksStatus: PRChecksStatus?
}
