import SwiftUI

// MARK: - UpdatePopoverView

/// Popover shown when the user clicks the update pill / titlebar accessory.
struct UpdatePopoverView: View {
    @ObservedObject var viewModel: UpdateViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            Divider().opacity(0.3)
            versionRow
            stateBody
            controlsRow
        }
        .padding(16)
        .frame(width: 280)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
            Text(String(localized: "update.title", defaultValue: "Software Update"))
                .font(.system(size: 14, weight: .semibold))
        }
    }

    // MARK: - Version row

    private var versionRow: some View {
        HStack {
            Text(String(localized: "update.currentVersion.label", defaultValue: "Current Version"))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Spacer()
            Text(viewModel.currentVersion)
                .font(.system(size: 12, design: .monospaced))
        }
    }

    // MARK: - State-specific body

    @ViewBuilder
    private var stateBody: some View {
        switch viewModel.state {
        case .checking:
            HStack(spacing: 8) {
                ProgressView()
                    .scaleEffect(0.7)
                    .frame(width: 14, height: 14)
                Text(String(localized: "update.checking", defaultValue: "Checking for updates…"))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

        case .updateAvailable(let version):
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: "shippingbox.fill")
                        .foregroundColor(.accentColor)
                    Text(String(localized: "update.available", defaultValue: "Version \(version) is available"))
                        .font(.system(size: 12, weight: .medium))
                }
                if let notes = viewModel.releaseNotes {
                    Text(notes)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(4)
                }
            }

        case .downloading(let progress):
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(String(localized: "update.downloading", defaultValue: "Downloading update…"))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(String(format: "%.0f%%", progress * 100))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                    .animation(.easeInOut(duration: 0.2), value: progress)
            }

        case .installing:
            HStack(spacing: 8) {
                ProgressView()
                    .scaleEffect(0.7)
                    .frame(width: 14, height: 14)
                Text(String(localized: "update.installing", defaultValue: "Installing update…"))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

        case .upToDate:
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text(String(localized: "update.upToDate", defaultValue: "You're up to date"))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

        case .error(let message):
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(message)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }

        case .idle:
            EmptyView()
        }
    }

    // MARK: - Controls

    private var controlsRow: some View {
        HStack(spacing: 8) {
            if case .updateAvailable = viewModel.state {
                Button(String(localized: "update.installButton", defaultValue: "Install Update")) {
                    UpdateController.shared.installUpdate()
                }
                .controlSize(.small)
                .keyboardShortcut(.defaultAction)
            }

            Button(viewModel.isChecking ? String(localized: "update.checkButton.checking", defaultValue: "Checking…") : String(localized: "update.checkButton", defaultValue: "Check Now")) {
                UpdateController.shared.checkForUpdates()
            }
            .disabled(viewModel.isChecking)
            .controlSize(.small)

            Spacer()
        }
    }
}

// MARK: - UpdateStatusPill

/// Compact pill shown in the titlebar / sidebar for update status.
struct UpdateStatusPill: View {
    @ObservedObject var viewModel: UpdateViewModel
    @State private var showPopover = false

    private let textFont = NSFont.systemFont(ofSize: 11, weight: .medium)

    var body: some View {
        if viewModel.showsPill {
            pillButton
                .popover(
                    isPresented: $showPopover,
                    attachmentAnchor: .rect(.bounds),
                    arrowEdge: .top
                ) {
                    UpdatePopoverView(viewModel: viewModel)
                }
                .transition(.opacity.combined(with: .scale(scale: 0.95)))
        }
    }

    @ViewBuilder
    private var pillButton: some View {
        Button {
            if case .upToDate = viewModel.state {
                viewModel.state = .idle
                return
            }
            showPopover.toggle()
        } label: {
            HStack(spacing: 6) {
                UpdateBadge(viewModel: viewModel)
                    .frame(width: 14, height: 14)
                Text(viewModel.statusText)
                    .font(Font(textFont))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Capsule().fill(viewModel.backgroundColor))
            .foregroundColor(viewModel.foregroundColor)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(viewModel.statusText)
        .accessibilityIdentifier("UpdatePill")
    }
}
