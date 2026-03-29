import SwiftUI

// MARK: - FindOverlayView

/// Cmd+F search overlay for the terminal surface.
/// Displays a floating search bar with next/previous navigation and match count.
struct FindOverlayView: View {
    @Binding var isVisible: Bool
    @Binding var searchText: String
    let matchIndex: Int?
    let matchTotal: Int?
    let onNext: () -> Void
    let onPrevious: () -> Void

    @FocusState private var isFieldFocused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)

            TextField("Find in terminal...", text: $searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($isFieldFocused)
                .onSubmit { onNext() }
                .frame(width: 160)

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
            .help("Previous match (Shift+Enter)")

            Button(action: onNext) {
                Image(systemName: "chevron.down")
                    .font(.system(size: 11, weight: .medium))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Next match (Enter)")

            Button(action: { isVisible = false }) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .medium))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Close (Esc)")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(FindOverlayBackgroundView())
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .shadow(color: .black.opacity(0.3), radius: 6, x: 0, y: 2)
        .padding(8)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("namu-find-overlay")
        .onAppear { isFieldFocused = true }
        .onKeyPress(.escape) {
            isVisible = false
            return .handled
        }
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
