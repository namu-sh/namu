import SwiftUI
import AppKit

/// Individual tab view with icon, title, close button, and dirty indicator
struct NamuTabItemView: View {
    let tab: TabItem
    let isSelected: Bool
    let showsZoomIndicator: Bool
    let appearance: NamuSplitConfiguration.Appearance
    let saturation: Double
    let onSelect: () -> Void
    let onClose: () -> Void
    let onZoomToggle: () -> Void
    let onContextAction: (TabContextAction) -> Void

    @State private var isHovered = false
    @State private var isCloseHovered = false
    @State private var isZoomHovered = false

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: NamuTabBarMetrics.contentSpacing) {
                iconView
                    .frame(width: NamuTabBarMetrics.iconSize, height: NamuTabBarMetrics.iconSize, alignment: .center)

                Text(tab.title)
                    .font(.system(size: NamuTabBarMetrics.titleFontSize))
                    .lineLimit(1)
                    .foregroundStyle(
                        isSelected
                            ? NamuTabBarColors.activeText(for: appearance)
                            : NamuTabBarColors.inactiveText(for: appearance)
                    )
                    .saturation(saturation)

                if showsZoomIndicator {
                    zoomButton
                }
            }

            Spacer(minLength: 0)

            closeOrDirtyIndicator
        }
        .padding(.horizontal, NamuTabBarMetrics.tabHorizontalPadding)
        .frame(
            minWidth: NamuTabBarMetrics.tabMinWidth,
            maxWidth: NamuTabBarMetrics.tabMaxWidth,
            minHeight: NamuTabBarMetrics.tabHeight - 6,
            maxHeight: NamuTabBarMetrics.tabHeight - 6
        )
        .background(tabBackground.saturation(saturation))
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .onTapGesture { onSelect() }
        .onHover { hovering in isHovered = hovering }
        .contextMenu { contextMenuContent }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(tab.title)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    // MARK: - Icon

    @ViewBuilder
    private var iconView: some View {
        let iconTint = isSelected
            ? NamuTabBarColors.activeText(for: appearance)
            : NamuTabBarColors.inactiveText(for: appearance)

        Group {
            if tab.isLoading {
                NamuTabLoadingSpinner(size: NamuTabBarMetrics.iconSize * 0.86, color: iconTint)
            } else if let iconData = tab.iconImageData, let nsImage = NSImage(data: iconData) {
                Image(nsImage: nsImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else if let iconName = tab.icon {
                Image(systemName: iconName)
                    .font(.system(size: glyphSize(for: iconName)))
                    .foregroundStyle(iconTint)
            }
        }
        .saturation(tab.iconImageData != nil ? 1.0 : saturation)
        .transaction { tx in tx.animation = nil }
    }

    private func glyphSize(for iconName: String) -> CGFloat {
        if iconName == "terminal.fill" || iconName == "terminal" || iconName == "globe" {
            return max(10, NamuTabBarMetrics.iconSize - 2.5)
        }
        return NamuTabBarMetrics.iconSize
    }

    // MARK: - Zoom Button

    @ViewBuilder
    private var zoomButton: some View {
        Button {
            onZoomToggle()
        } label: {
            Image(systemName: "arrow.up.left.and.arrow.down.right")
                .font(.system(size: max(8, NamuTabBarMetrics.titleFontSize - 2), weight: .semibold))
                .foregroundStyle(
                    isZoomHovered
                        ? NamuTabBarColors.activeText(for: appearance)
                        : NamuTabBarColors.inactiveText(for: appearance)
                )
                .frame(width: NamuTabBarMetrics.closeButtonSize, height: NamuTabBarMetrics.closeButtonSize)
                .background(
                    Circle().fill(isZoomHovered ? NamuTabBarColors.hoveredTabBackground(for: appearance) : .clear)
                )
        }
        .buttonStyle(.plain)
        .onHover { hovering in isZoomHovered = hovering }
        .saturation(saturation)
        .accessibilityLabel("Exit zoom")
    }

    // MARK: - Tab Background

    @ViewBuilder
    private var tabBackground: some View {
        if isSelected {
            Color(nsColor: .labelColor).opacity(0.12)
        } else if isHovered {
            Color(nsColor: .labelColor).opacity(0.06)
        } else {
            Color.clear
        }
    }

    // MARK: - Close Button / Dirty Indicator

    @ViewBuilder
    private var closeOrDirtyIndicator: some View {
        ZStack {
            if (!isSelected && !isHovered && !isCloseHovered) && (tab.isDirty || tab.showsNotificationBadge) {
                HStack(spacing: 2) {
                    if tab.showsNotificationBadge {
                        Circle()
                            .fill(NamuTabBarColors.notificationBadge(for: appearance))
                            .frame(width: NamuTabBarMetrics.notificationBadgeSize, height: NamuTabBarMetrics.notificationBadgeSize)
                    }
                    if tab.isDirty {
                        Circle()
                            .fill(NamuTabBarColors.dirtyIndicator(for: appearance))
                            .frame(width: NamuTabBarMetrics.dirtyIndicatorSize, height: NamuTabBarMetrics.dirtyIndicatorSize)
                            .saturation(saturation)
                    }
                }
            }

            if tab.isPinned {
                if isSelected || isHovered || isCloseHovered || (!tab.isDirty && !tab.showsNotificationBadge) {
                    Image(systemName: "pin.fill")
                        .font(.system(size: NamuTabBarMetrics.closeIconSize, weight: .semibold))
                        .foregroundStyle(NamuTabBarColors.inactiveText(for: appearance))
                        .frame(width: NamuTabBarMetrics.closeButtonSize, height: NamuTabBarMetrics.closeButtonSize)
                        .saturation(saturation)
                }
            } else if isSelected || isHovered || isCloseHovered {
                Button {
                    onClose()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: NamuTabBarMetrics.closeIconSize, weight: .semibold))
                        .foregroundStyle(
                            isCloseHovered
                                ? NamuTabBarColors.activeText(for: appearance)
                                : NamuTabBarColors.inactiveText(for: appearance)
                        )
                        .frame(width: NamuTabBarMetrics.closeButtonSize, height: NamuTabBarMetrics.closeButtonSize)
                        .background(
                            Circle().fill(isCloseHovered ? NamuTabBarColors.hoveredTabBackground(for: appearance) : .clear)
                        )
                }
                .buttonStyle(.plain)
                .onHover { hovering in isCloseHovered = hovering }
                .saturation(saturation)
            }
        }
        .frame(width: NamuTabBarMetrics.closeButtonSize, height: NamuTabBarMetrics.closeButtonSize)
        .animation(.easeInOut(duration: NamuTabBarMetrics.hoverDuration), value: isHovered)
        .animation(.easeInOut(duration: NamuTabBarMetrics.hoverDuration), value: isCloseHovered)
    }

    // MARK: - Context Menu

    @ViewBuilder
    private var contextMenuContent: some View {
        Button("Rename Tab...") { onContextAction(.rename) }

        if tab.hasCustomTitle {
            Button("Remove Custom Tab Name") { onContextAction(.clearName) }
        }

        Divider()

        Button("Close Tabs to Left") { onContextAction(.closeToLeft) }
        Button("Close Tabs to Right") { onContextAction(.closeToRight) }
        Button("Close Other Tabs") { onContextAction(.closeOthers) }

        Divider()

        Button("New Terminal Tab to Right") { onContextAction(.newTerminalToRight) }
        Button("New Browser Tab to Right") { onContextAction(.newBrowserToRight) }

        if tab.kind == "browser" {
            Divider()
            Button("Reload Tab") { onContextAction(.reload) }
            Button("Duplicate Tab") { onContextAction(.duplicate) }
        }

        Divider()

        Button(tab.isPinned ? "Unpin Tab" : "Pin Tab") { onContextAction(.togglePin) }

        if tab.showsNotificationBadge {
            Button("Mark Tab as Read") { onContextAction(.markAsRead) }
        } else {
            Button("Mark Tab as Unread") { onContextAction(.markAsUnread) }
        }
    }
}

// MARK: - Loading Spinner

private struct NamuTabLoadingSpinner: View {
    let size: CGFloat
    let color: Color

    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let angle = (t.truncatingRemainder(dividingBy: 0.9) / 0.9) * 360.0

            ZStack {
                Circle().stroke(color.opacity(0.20), lineWidth: ringWidth)
                Circle()
                    .trim(from: 0.0, to: 0.28)
                    .stroke(color, style: StrokeStyle(lineWidth: ringWidth, lineCap: .round))
                    .rotationEffect(.degrees(angle))
            }
            .frame(width: size, height: size)
        }
    }

    private var ringWidth: CGFloat { max(1.6, size * 0.14) }
}
