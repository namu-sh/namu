import SwiftUI

// MARK: - UpdateBadge

/// Icon/indicator displayed inside the update pill showing the current state.
struct UpdateBadge: View {
    @ObservedObject var viewModel: UpdateViewModel

    var body: some View {
        badgeContent
            .accessibilityLabel(viewModel.statusText)
    }

    @ViewBuilder
    private var badgeContent: some View {
        switch viewModel.state {
        case .checking:
            SpinnerView(size: 14, color: viewModel.foregroundColor)

        case .downloading(let progress):
            ProgressRingView(progress: max(0, min(1, progress)))

        case .installing:
            SpinnerView(size: 14, color: viewModel.foregroundColor)

        default:
            if let name = viewModel.iconName {
                Image(systemName: name)
                    .foregroundStyle(viewModel.iconColor)
            }
        }
    }
}

// MARK: - ProgressRingView

private struct ProgressRingView: View {
    let progress: Double
    private let lineWidth: CGFloat = 2

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.primary.opacity(0.2), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: progress)
                .stroke(Color.primary, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeInOut(duration: 0.2), value: progress)
        }
    }
}

// MARK: - SpinnerView

private struct SpinnerView: View {
    let size: CGFloat
    let color: Color

    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let angle = (t.truncatingRemainder(dividingBy: 0.9) / 0.9) * 360.0
            ZStack {
                Circle()
                    .stroke(color.opacity(0.20), lineWidth: ringWidth)
                Circle()
                    .trim(from: 0, to: 0.28)
                    .stroke(color, style: StrokeStyle(lineWidth: ringWidth, lineCap: .round))
                    .rotationEffect(.degrees(angle))
            }
            .frame(width: size, height: size)
        }
    }

    private var ringWidth: CGFloat { max(1.6, size * 0.14) }
}

// MARK: - DockUpdateBadge

/// Applies a Dock tile badge when an update is pending.
/// Call `DockUpdateBadge.update(viewModel:)` from the app delegate.
enum DockUpdateBadge {
    static func apply(for state: UpdateState) {
        switch state {
        case .updateAvailable(let version):
            NSApp.dockTile.badgeLabel = version.isEmpty ? "!" : version
        default:
            NSApp.dockTile.badgeLabel = nil
        }
    }
}
