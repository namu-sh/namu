import Foundation
import SwiftUI

/// Configuration for the split tab bar appearance and behavior
struct NamuSplitConfiguration: Sendable {

    // MARK: - Behavior

    var allowSplits: Bool
    var allowCloseTabs: Bool
    var allowCloseLastPane: Bool
    var allowTabReordering: Bool
    var allowCrossPaneTabMove: Bool
    var autoCloseEmptyPanes: Bool
    var contentViewLifecycle: ContentViewLifecycle
    var newTabPosition: NewTabPosition

    // MARK: - Appearance

    var appearance: Appearance

    // MARK: - Presets

    static let `default` = NamuSplitConfiguration()

    static let singlePane = NamuSplitConfiguration(
        allowSplits: false,
        allowCloseLastPane: false
    )

    static let readOnly = NamuSplitConfiguration(
        allowSplits: false,
        allowCloseTabs: false,
        allowTabReordering: false,
        allowCrossPaneTabMove: false
    )

    // MARK: - Initializer

    init(
        allowSplits: Bool = true,
        allowCloseTabs: Bool = true,
        allowCloseLastPane: Bool = false,
        allowTabReordering: Bool = true,
        allowCrossPaneTabMove: Bool = true,
        autoCloseEmptyPanes: Bool = true,
        contentViewLifecycle: ContentViewLifecycle = .recreateOnSwitch,
        newTabPosition: NewTabPosition = .current,
        appearance: Appearance = .default
    ) {
        self.allowSplits = allowSplits
        self.allowCloseTabs = allowCloseTabs
        self.allowCloseLastPane = allowCloseLastPane
        self.allowTabReordering = allowTabReordering
        self.allowCrossPaneTabMove = allowCrossPaneTabMove
        self.autoCloseEmptyPanes = autoCloseEmptyPanes
        self.contentViewLifecycle = contentViewLifecycle
        self.newTabPosition = newTabPosition
        self.appearance = appearance
    }
}

// MARK: - Appearance Configuration

extension NamuSplitConfiguration {
    struct SplitButtonTooltips: Sendable, Equatable {
        var newTerminal: String
        var newBrowser: String
        var splitRight: String
        var splitDown: String

        static let `default` = SplitButtonTooltips()

        init(
            newTerminal: String = "New Terminal",
            newBrowser: String = "New Browser",
            splitRight: String = "Split Right",
            splitDown: String = "Split Down"
        ) {
            self.newTerminal = newTerminal
            self.newBrowser = newBrowser
            self.splitRight = splitRight
            self.splitDown = splitDown
        }
    }

    struct Appearance: Sendable {
        struct ChromeColors: Sendable {
            var backgroundHex: String?
            var borderHex: String?

            init(backgroundHex: String? = nil, borderHex: String? = nil) {
                self.backgroundHex = backgroundHex
                self.borderHex = borderHex
            }
        }

        // MARK: - Tab Bar

        var tabBarHeight: CGFloat
        var tabMinWidth: CGFloat
        var tabMaxWidth: CGFloat
        var tabSpacing: CGFloat

        // MARK: - Split View

        var minimumPaneWidth: CGFloat
        var minimumPaneHeight: CGFloat
        var showSplitButtons: Bool
        var splitButtonTooltips: SplitButtonTooltips

        // MARK: - Animations

        var animationDuration: Double
        var enableAnimations: Bool

        // MARK: - Theme Overrides

        var chromeColors: ChromeColors

        // MARK: - Presets

        static let `default` = Appearance()

        static let compact = Appearance(
            tabBarHeight: 28,
            tabMinWidth: 100,
            tabMaxWidth: 160
        )

        static let spacious = Appearance(
            tabBarHeight: 38,
            tabMinWidth: 160,
            tabMaxWidth: 280,
            tabSpacing: 2
        )

        // MARK: - Initializer

        init(
            tabBarHeight: CGFloat = 33,
            tabMinWidth: CGFloat = 140,
            tabMaxWidth: CGFloat = 220,
            tabSpacing: CGFloat = 0,
            minimumPaneWidth: CGFloat = 100,
            minimumPaneHeight: CGFloat = 100,
            showSplitButtons: Bool = true,
            splitButtonTooltips: SplitButtonTooltips = .default,
            animationDuration: Double = 0.15,
            enableAnimations: Bool = true,
            chromeColors: ChromeColors = .init()
        ) {
            self.tabBarHeight = tabBarHeight
            self.tabMinWidth = tabMinWidth
            self.tabMaxWidth = tabMaxWidth
            self.tabSpacing = tabSpacing
            self.minimumPaneWidth = minimumPaneWidth
            self.minimumPaneHeight = minimumPaneHeight
            self.showSplitButtons = showSplitButtons
            self.splitButtonTooltips = splitButtonTooltips
            self.animationDuration = animationDuration
            self.enableAnimations = enableAnimations
            self.chromeColors = chromeColors
        }
    }
}
