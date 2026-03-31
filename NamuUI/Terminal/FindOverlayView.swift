import SwiftUI
import AppKit

// MARK: - Corner

private enum Corner: CaseIterable {
    case topLeft, topRight, bottomLeft, bottomRight
}

// MARK: - SearchNativeTextField

/// NSTextField subclass that guards CJK IME composition before acting on
/// Escape / Return, preventing the overlay from closing mid-composition.
private final class SearchNativeTextField: NSTextField {

    var onTextChange: ((String) -> Void)?
    var onCommit: (() -> Void)?
    var onClose: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        // Block Escape / Return while IME is composing.
        // currentEditor() returns NSText; cast to NSTextView (NSTextInputClient)
        // to call hasMarkedText() which reflects CJK IME composition state.
        if let editor = currentEditor() as? NSTextView, editor.hasMarkedText() {
            super.keyDown(with: event)
            return
        }
        switch event.keyCode {
        case 53: // Escape
            onClose?()
        case 36, 76: // Return / Enter
            onCommit?()
        default:
            super.keyDown(with: event)
        }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // Don't steal key equivalents while IME is composing.
        if let editor = currentEditor() as? NSTextView, editor.hasMarkedText() {
            return super.performKeyEquivalent(with: event)
        }
        return super.performKeyEquivalent(with: event)
    }
}

// MARK: - SearchNativeTextField: NSViewRepresentable

private struct SearchTextField: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    let onCommit: () -> Void
    let onClose: () -> Void
    let onTextChange: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> SearchNativeTextField {
        let field = SearchNativeTextField()
        field.placeholderString = placeholder
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = NSFont.systemFont(ofSize: 13)
        field.textColor = NSColor.labelColor
        field.delegate = context.coordinator
        field.onCommit = onCommit
        field.onClose = onClose
        field.onTextChange = onTextChange

        // Become first responder on next runloop tick so SwiftUI layout settles first.
        DispatchQueue.main.async {
            field.window?.makeFirstResponder(field)
        }

        // Re-focus the search field whenever the window regains key status
        // (e.g. user clicks away and returns while the find overlay is still open).
        context.coordinator.installWindowFocusObserver(for: field)

        return field
    }

    func updateNSView(_ nsView: SearchNativeTextField, context: Context) {
        if nsView.stringValue != text {
            nsView.stringValue = text
        }
        nsView.onCommit = onCommit
        nsView.onClose = onClose
        nsView.onTextChange = onTextChange
    }

    static func dismantleNSView(_ nsView: SearchNativeTextField, coordinator: Coordinator) {
        coordinator.removeWindowFocusObserver()
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: SearchTextField
        private var windowObserver: Any?
        /// Guards against multiple simultaneous async focus attempts racing.
        private var pendingFocusRequest: Bool = false

        init(_ parent: SearchTextField) {
            self.parent = parent
        }

        deinit {
            if let obs = windowObserver {
                NotificationCenter.default.removeObserver(obs)
            }
        }

        /// Remove the window focus observer. Called from dismantleNSView on teardown.
        func removeWindowFocusObserver() {
            if let obs = windowObserver {
                NotificationCenter.default.removeObserver(obs)
                windowObserver = nil
            }
        }

        /// Install a NSWindow.didBecomeKeyNotification observer so the search
        /// field reclaims first responder when the window regains focus.
        func installWindowFocusObserver(for field: SearchNativeTextField) {
            guard windowObserver == nil else { return }
            windowObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didBecomeKeyNotification,
                object: nil,
                queue: .main
            ) { [weak self, weak field] notification in
                guard let self, let field,
                      let window = field.window,
                      notification.object as? NSWindow === window else { return }

                // Triple first-responder check before issuing a focus request:
                // (1) field is already firstResponder — nothing to do.
                guard window.firstResponder !== field else { return }
                // (2) field's currentEditor is active — IME or inline editing is live.
                if field.currentEditor() != nil { return }
                // (3) delegate chain intact — field still belongs to this coordinator.
                guard (field.delegate as? Coordinator) === self else { return }

                // Prevent multiple async requests from racing.
                guard !self.pendingFocusRequest else { return }
                self.pendingFocusRequest = true
                DispatchQueue.main.async { [weak self, weak field, weak window] in
                    self?.pendingFocusRequest = false
                    guard let field, let window else { return }
                    window.makeFirstResponder(field)
                }
            }
        }

        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSTextField else { return }
            let newValue = field.stringValue
            parent.text = newValue
            parent.onTextChange(newValue)
        }
    }
}

// MARK: - FindOverlayView

/// Cmd+F search overlay for the terminal surface.
/// Displays a floating search bar with next/previous navigation and match count.
/// The overlay can be dragged and snaps to the nearest corner of its parent container.
struct FindOverlayView: View {
    @Binding var isVisible: Bool
    @Binding var searchText: String
    let matchIndex: Int?
    let matchTotal: Int?
    let onNext: () -> Void
    let onPrevious: () -> Void
    /// Called after the overlay is dismissed (Escape or × button).
    /// Use this to restore first responder to the terminal surface.
    var onDismiss: (() -> Void)? = nil

    // Corner tracking — default to topRight to preserve existing behavior.
    @State private var corner: Corner = .topRight
    // Drag offset while gesture is in flight.
    @State private var dragOffset: CGSize = .zero

    private func dismiss() {
        isVisible = false
        onDismiss?()
    }

    var body: some View {
        GeometryReader { geo in
            overlayContent
                .position(position(for: corner, in: geo.size))
                .offset(dragOffset)
                .gesture(
                    DragGesture()
                        .onChanged { value in
                            dragOffset = value.translation
                        }
                        .onEnded { value in
                            // Compute absolute position after drag.
                            let base = position(for: corner, in: geo.size)
                            let finalX = base.x + value.translation.width
                            let finalY = base.y + value.translation.height
                            corner = nearestCorner(
                                for: CGPoint(x: finalX, y: finalY),
                                in: geo.size
                            )
                            dragOffset = .zero
                        }
                )
        }
    }

    // MARK: - Overlay content

    private var overlayContent: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)

            SearchTextField(
                text: $searchText,
                placeholder: String(localized: "find.placeholder", defaultValue: "Find in terminal..."),
                onCommit: onNext,
                onClose: { dismiss() },
                onTextChange: { _ in }
            )
            .frame(width: 160, height: 20)

            // Match count display
            if let total = matchTotal {
                if let index = matchIndex {
                    Text("\(index + 1)/\(total)")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                } else {
                    Text("-/\(total)")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }

            Button(action: onPrevious) {
                Image(systemName: "chevron.up")
                    .font(.system(size: 11, weight: .medium))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help(String(localized: "find.previousMatch.tooltip", defaultValue: "Previous match (Shift+Enter)"))

            Button(action: onNext) {
                Image(systemName: "chevron.down")
                    .font(.system(size: 11, weight: .medium))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help(String(localized: "find.nextMatch.tooltip", defaultValue: "Next match (Enter)"))

            Button(action: { dismiss() }) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .medium))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help(String(localized: "find.close.tooltip", defaultValue: "Close (Esc)"))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(FindOverlayBackgroundView())
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .shadow(color: .black.opacity(0.3), radius: 6, x: 0, y: 2)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("namu-find-overlay")
    }

    // MARK: - Corner geometry

    /// Width/height estimate for the overlay so it stays inset from edges.
    private let overlayWidth: CGFloat = 360
    private let overlayHeight: CGFloat = 36
    private let edgePadding: CGFloat = 8

    private func position(for corner: Corner, in size: CGSize) -> CGPoint {
        let halfW = overlayWidth / 2 + edgePadding
        let halfH = overlayHeight / 2 + edgePadding
        switch corner {
        case .topLeft:
            return CGPoint(x: halfW, y: halfH)
        case .topRight:
            return CGPoint(x: size.width - halfW, y: halfH)
        case .bottomLeft:
            return CGPoint(x: halfW, y: size.height - halfH)
        case .bottomRight:
            return CGPoint(x: size.width - halfW, y: size.height - halfH)
        }
    }

    private func nearestCorner(for point: CGPoint, in size: CGSize) -> Corner {
        Corner.allCases.min(by: { a, b in
            distance(point, position(for: a, in: size)) < distance(point, position(for: b, in: size))
        }) ?? .topRight
    }

    private func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = a.x - b.x
        let dy = a.y - b.y
        return sqrt(dx * dx + dy * dy)
    }
}

// MARK: - Background

private struct FindOverlayBackgroundView: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}
