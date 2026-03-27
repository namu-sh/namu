import AppKit
import SwiftUI
import Combine

// MARK: - UpdateTitlebarAccessory

/// Attaches a pill-shaped update indicator to the window titlebar.
///
/// Usage:
///   let accessory = UpdateTitlebarAccessory(viewModel: UpdateController.shared.viewModel)
///   accessory.attach(to: window)
@MainActor
final class UpdateTitlebarAccessory {
    private let viewModel: UpdateViewModel
    private var titlebarAccessory: NSTitlebarAccessoryViewController?
    private var cancellable: AnyCancellable?

    init(viewModel: UpdateViewModel) {
        self.viewModel = viewModel
    }

    // MARK: Public

    func attach(to window: NSWindow) {
        let hostingView = NonDraggableTitlebarHostingView(
            rootView: TitlebarUpdatePill(viewModel: viewModel)
        )
        hostingView.translatesAutoresizingMaskIntoConstraints = false

        let accessoryVC = NSTitlebarAccessoryViewController()
        accessoryVC.view = hostingView
        accessoryVC.layoutAttribute = .right

        window.addTitlebarAccessoryViewController(accessoryVC)
        self.titlebarAccessory = accessoryVC

        // Show/hide the accessory based on whether the pill should be visible.
        cancellable = viewModel.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak accessoryVC] state in
                switch state {
                case .idle:
                    accessoryVC?.view.isHidden = true
                default:
                    accessoryVC?.view.isHidden = false
                }
            }
    }

    func detach() {
        titlebarAccessory?.removeFromParent()
        titlebarAccessory = nil
        cancellable = nil
    }
}

// MARK: - TitlebarUpdatePill

/// SwiftUI view rendered inside the titlebar accessory.
private struct TitlebarUpdatePill: View {
    @ObservedObject var viewModel: UpdateViewModel
    @State private var showPopover = false

    var body: some View {
        Group {
            if viewModel.showsPill {
                Button {
                    showPopover.toggle()
                } label: {
                    HStack(spacing: 5) {
                        UpdateBadge(viewModel: viewModel)
                            .frame(width: 12, height: 12)
                        Text(viewModel.statusText)
                            .font(.system(size: 10, weight: .medium))
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(viewModel.backgroundColor))
                    .foregroundColor(viewModel.foregroundColor)
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .popover(isPresented: $showPopover, arrowEdge: .bottom) {
                    UpdatePopoverView(viewModel: viewModel)
                }
                .transition(.opacity.combined(with: .scale(scale: 0.9)))
                .animation(.easeInOut(duration: 0.18), value: viewModel.showsPill)
            }
        }
        .padding(.trailing, 8)
        .frame(height: 22)
    }
}

// MARK: - NonDraggableTitlebarHostingView

/// Prevents the titlebar pill from triggering window drag.
private final class NonDraggableTitlebarHostingView<Content: View>: NSHostingView<Content> {
    override var mouseDownCanMoveWindow: Bool { false }
}
