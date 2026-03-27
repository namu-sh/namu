import Foundation

/// The lifecycle state of a pull request.
enum PRState: String, Codable, Equatable {
    case open
    case merged
    case closed
}

/// Display model for a pull request shown in the sidebar.
struct PullRequestDisplay: Equatable {
    let number: Int
    let state: PRState
    let url: String
    let branch: String
    let checksStatus: String?
}
