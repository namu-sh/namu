import SwiftUI

/// Full notification panel shown when the bell icon is active in the sidebar.
struct NotificationPanelView: View {
    @ObservedObject var notificationService: NotificationService
    @ObservedObject var workspaceManager: WorkspaceManager
    /// Called when the user taps a notification to navigate to its workspace.
    let onSelectWorkspace: (UUID) -> Void
    /// Called when the user taps "Jump to Latest Unread" — should navigate to unread and switch back to workspaces.
    var onJumpToUnread: (() -> Void)?

    /// Keyboard focus state: nil = no focused row, non-nil = focused notification ID.
    @FocusState private var focusedNotificationID: UUID?

    /// Ordered (newest-first) list used for both display and keyboard navigation.
    private var orderedNotifications: [InAppNotification] {
        notificationService.allNotifications.reversed()
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
                .opacity(0.3)

            if notificationService.allNotifications.isEmpty {
                emptyState
            } else {
                ScrollViewReader { proxy in
                    ScrollView(.vertical, showsIndicators: false) {
                        LazyVStack(spacing: 6) {
                            ForEach(orderedNotifications) { notification in
                                NotificationRow(
                                    notification: notification,
                                    workspaceName: workspaceName(for: notification.workspaceID),
                                    onOpen: {
                                        openNotification(notification)
                                    },
                                    onRemove: {
                                        notificationService.remove(id: notification.id)
                                    }
                                )
                                .id(notification.id)
                                .focused($focusedNotificationID, equals: notification.id)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8)
                                        .stroke(Color.accentColor.opacity(focusedNotificationID == notification.id ? 0.6 : 0), lineWidth: 2)
                                )
                            }
                        }
                        .padding(12)
                    }
                    .onKeyPress(.upArrow)   { moveFocus(by: -1, proxy: proxy); return .handled }
                    .onKeyPress(.downArrow) { moveFocus(by: +1, proxy: proxy); return .handled }
                    .onKeyPress(.return)    { openFocused(); return .handled }
                    .onKeyPress(.delete)    { deleteFocused(); return .handled }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Keyboard navigation helpers

    private func moveFocus(by delta: Int, proxy: ScrollViewProxy) {
        let items = orderedNotifications
        guard !items.isEmpty else { return }
        let currentIndex = items.firstIndex(where: { $0.id == focusedNotificationID }) ?? -1
        let nextIndex = (currentIndex + delta).clamped(to: 0...(items.count - 1))
        let targetID = items[nextIndex].id
        focusedNotificationID = targetID
        withAnimation { proxy.scrollTo(targetID, anchor: .center) }
    }

    private func openFocused() {
        guard let id = focusedNotificationID,
              let notification = orderedNotifications.first(where: { $0.id == id }) else { return }
        openNotification(notification)
    }

    private func deleteFocused() {
        guard let id = focusedNotificationID else { return }
        let items = orderedNotifications
        // Move focus to adjacent row before removing.
        if let idx = items.firstIndex(where: { $0.id == id }) {
            let nextIdx: Int?
            if idx < items.count - 1 {
                nextIdx = idx + 1
            } else if idx > 0 {
                nextIdx = idx - 1
            } else {
                nextIdx = nil
            }
            focusedNotificationID = nextIdx.map { items[$0].id }
        }
        notificationService.remove(id: id)
    }

    private func openNotification(_ notification: InAppNotification) {
        notificationService.markRead(id: notification.id)
        if let wsID = notification.workspaceID {
            onSelectWorkspace(wsID)
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Text(String(localized: "notifications.title", defaultValue: "Notifications"))
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.primary)

            if notificationService.unreadCount > 0 {
                Text("\(notificationService.unreadCount)")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(Color.accentColor, in: Capsule())
            }

            Spacer()

            HStack(spacing: 5) {
                Button(String(localized: "notifications.jumpToLatestUnread", defaultValue: "Jump to Latest Unread")) {
                    onJumpToUnread?()
                }
                .font(.system(size: 11))
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .disabled(notificationService.unreadCount == 0)

                Text(KeyboardShortcutSettings.shortcut(for: .jumpToUnread).displayString)
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(RoundedRectangle(cornerRadius: 5).fill(Color(nsColor: .controlBackgroundColor)))
                    .foregroundStyle(.secondary)
            }

            if !notificationService.allNotifications.isEmpty {
                Button(String(localized: "notifications.clearAll", defaultValue: "Clear All")) {
                    notificationService.clearAll(workspaceID: nil)
                }
                .font(.system(size: 11))
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "bell.slash")
                .font(.system(size: 28))
                .foregroundStyle(.secondary)
            Text(String(localized: "notifications.empty.title", defaultValue: "No notifications yet"))
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Helpers

    private func workspaceName(for workspaceID: UUID?) -> String? {
        guard let id = workspaceID else { return nil }
        return workspaceManager.workspaces.first(where: { $0.id == id })?.title
    }
}
