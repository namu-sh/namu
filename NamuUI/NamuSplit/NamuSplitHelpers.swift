import SwiftUI
import AppKit

// MARK: - Tab Bar Metrics

enum NamuTabBarMetrics {
    static let barHeight: CGFloat = 33
    static let tabHeight: CGFloat = 33
    static let tabMinWidth: CGFloat = 140
    static let tabMaxWidth: CGFloat = 220
    static let tabSpacing: CGFloat = 2
    static let barPadding: CGFloat = 4
    static let contentSpacing: CGFloat = 6
    static let tabHorizontalPadding: CGFloat = 8
    static let iconSize: CGFloat = 14
    static let titleFontSize: CGFloat = 12
    static let closeButtonSize: CGFloat = 18
    static let closeIconSize: CGFloat = 9
    static let dirtyIndicatorSize: CGFloat = 7
    static let notificationBadgeSize: CGFloat = 7
    static let hoverDuration: CGFloat = 0.12
    static let splitButtonSize: CGFloat = 28
}

// MARK: - Tab Bar Colors

enum NamuTabBarColors {
    static func paneBackground(for appearance: NamuSplitConfiguration.Appearance) -> Color {
        if let hex = appearance.chromeColors.backgroundHex {
            return Color(nsColor: NSColor.fromHex(hex) ?? .windowBackgroundColor)
        }
        return Color(nsColor: .windowBackgroundColor)
    }

    static func tabBarBackground(for appearance: NamuSplitConfiguration.Appearance) -> Color {
        if let hex = appearance.chromeColors.backgroundHex {
            return Color(nsColor: NSColor.fromHex(hex) ?? .windowBackgroundColor)
        }
        return Color(nsColor: .windowBackgroundColor)
    }

    static func separator(for appearance: NamuSplitConfiguration.Appearance) -> Color {
        if let hex = appearance.chromeColors.borderHex {
            return Color(nsColor: NSColor.fromHex(hex) ?? .separatorColor)
        }
        return Color(nsColor: .separatorColor)
    }

    static func nsColorSeparator(for appearance: NamuSplitConfiguration.Appearance) -> NSColor? {
        if let hex = appearance.chromeColors.borderHex {
            return NSColor.fromHex(hex)
        }
        return nil
    }

    static func activeText(for appearance: NamuSplitConfiguration.Appearance) -> Color {
        Color(nsColor: .labelColor)
    }

    static func inactiveText(for appearance: NamuSplitConfiguration.Appearance) -> Color {
        Color(nsColor: .secondaryLabelColor)
    }

    static func hoveredTabBackground(for appearance: NamuSplitConfiguration.Appearance) -> Color {
        Color(nsColor: .labelColor).opacity(0.08)
    }

    static func dirtyIndicator(for appearance: NamuSplitConfiguration.Appearance) -> Color {
        Color(nsColor: .systemOrange)
    }

    static func notificationBadge(for appearance: NamuSplitConfiguration.Appearance) -> Color {
        Color.accentColor
    }
}

// MARK: - NSColor Hex

private extension NSColor {
    static func fromHex(_ hex: String) -> NSColor? {
        var hexString = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if hexString.hasPrefix("#") { hexString.removeFirst() }

        var rgbValue: UInt64 = 0
        guard Scanner(string: hexString).scanHexInt64(&rgbValue) else { return nil }

        if hexString.count == 8 {
            return NSColor(
                red: CGFloat((rgbValue >> 24) & 0xFF) / 255.0,
                green: CGFloat((rgbValue >> 16) & 0xFF) / 255.0,
                blue: CGFloat((rgbValue >> 8) & 0xFF) / 255.0,
                alpha: CGFloat(rgbValue & 0xFF) / 255.0
            )
        } else if hexString.count == 6 {
            return NSColor(
                red: CGFloat((rgbValue >> 16) & 0xFF) / 255.0,
                green: CGFloat((rgbValue >> 8) & 0xFF) / 255.0,
                blue: CGFloat(rgbValue & 0xFF) / 255.0,
                alpha: 1.0
            )
        }
        return nil
    }
}

// MARK: - Drop Zone

/// Drop zone positions for creating splits
enum NamuDropZone: Equatable {
    case center
    case left
    case right
    case top
    case bottom

    var orientation: SplitOrientation? {
        switch self {
        case .left, .right: return .horizontal
        case .top, .bottom: return .vertical
        case .center: return nil
        }
    }

    var insertsFirst: Bool {
        switch self {
        case .left, .top: return true
        default: return false
        }
    }
}

// MARK: - Environment key for portal-hosted views

private struct ActiveDropZoneKey: EnvironmentKey {
    static let defaultValue: NamuDropZone? = nil
}

extension EnvironmentValues {
    var namuPaneDropZone: NamuDropZone? {
        get { self[ActiveDropZoneKey.self] }
        set { self[ActiveDropZoneKey.self] = newValue }
    }
}

// MARK: - Split Animator

/// Animates NSSplitView divider position using CADisplayLink
final class NamuSplitAnimator {
    static let shared = NamuSplitAnimator()

    private var displayLink: CVDisplayLink?
    private var animation: AnimationState?

    private struct AnimationState {
        weak var splitView: NSSplitView?
        let from: CGFloat
        let to: CGFloat
        let duration: TimeInterval
        let startTime: CFTimeInterval
        let completion: () -> Void
    }

    func animate(splitView: NSSplitView, from: CGFloat, to: CGFloat,
                 duration: TimeInterval, completion: @escaping () -> Void) {
        stop()

        let state = AnimationState(
            splitView: splitView, from: from, to: to,
            duration: duration, startTime: CACurrentMediaTime(),
            completion: completion
        )
        animation = state

        var link: CVDisplayLink?
        CVDisplayLinkCreateWithActiveCGDisplays(&link)
        guard let link else {
            splitView.setPosition(to, ofDividerAt: 0)
            completion()
            return
        }
        displayLink = link

        let callback: CVDisplayLinkOutputCallback = { _, _, _, _, _, userInfo -> CVReturn in
            let animator = Unmanaged<NamuSplitAnimator>.fromOpaque(userInfo!).takeUnretainedValue()
            DispatchQueue.main.async { animator.tick() }
            return kCVReturnSuccess
        }

        CVDisplayLinkSetOutputCallback(link, callback, Unmanaged.passUnretained(self).toOpaque())
        CVDisplayLinkStart(link)
    }

    private func tick() {
        guard let state = animation, let splitView = state.splitView else {
            stop()
            return
        }

        let elapsed = CACurrentMediaTime() - state.startTime
        let progress = min(elapsed / state.duration, 1.0)

        // Ease-out cubic
        let t = 1.0 - pow(1.0 - progress, 3)
        let position = state.from + (state.to - state.from) * CGFloat(t)

        splitView.setPosition(position, ofDividerAt: 0)
        splitView.layoutSubtreeIfNeeded()

        if progress >= 1.0 {
            let completion = state.completion
            stop()
            completion()
        }
    }

    private func stop() {
        if let link = displayLink {
            CVDisplayLinkStop(link)
        }
        displayLink = nil
        animation = nil
    }
}
