import Foundation

/// Controls how tab content views are managed when switching between tabs
enum ContentViewLifecycle: Sendable {
    /// Only the selected tab's content view is rendered. Other tabs' views are
    /// destroyed and recreated when selected. Memory efficient but loses view state.
    case recreateOnSwitch

    /// All tab content views are kept in the view hierarchy, with non-selected tabs
    /// hidden. Preserves all view state (scroll position, @State, focus, etc.)
    /// at the cost of higher memory usage.
    case keepAllAlive
}

/// Controls the position where new tabs are created
enum NewTabPosition: Sendable {
    /// Insert the new tab after the currently focused tab,
    /// or at the end if there are no focused tabs.
    case current

    /// Insert the new tab at the end of the tab list.
    case end
}
