import SwiftUI

/// A single row in the notification panel.
struct NotificationRow: View {
    let notification: InAppNotification
    let workspaceName: String?
    let onOpen: () -> Void
    let onRemove: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            // Tappable main content
            Button(action: onOpen) {
                HStack(alignment: .top, spacing: 10) {
                    // Unread dot
                    Circle()
                        .fill(notification.isRead ? Color.clear : Color.accentColor)
                        .frame(width: 8, height: 8)
                        .overlay(
                            Circle()
                                .stroke(Color.accentColor.opacity(notification.isRead ? 0.25 : 1), lineWidth: 1)
                        )
                        .padding(.top, 5)

                    VStack(alignment: .leading, spacing: 4) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(notification.title)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                            Spacer(minLength: 4)
                            Text(notification.createdAt, format: .dateTime.hour().minute())
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }

                        if !notification.body.isEmpty {
                            Text(notification.body)
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                                .lineLimit(3)
                        }

                        if let name = workspaceName {
                            Text(name)
                                .font(.system(size: 11))
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            // Remove button
            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help(String(localized: "notifications.row.remove.tooltip", defaultValue: "Remove notification"))
            .accessibilityLabel(String(localized: "notifications.row.remove.accessibility", defaultValue: "Remove notification"))
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(NamuColors.hoverBackground)
        )
    }
}
