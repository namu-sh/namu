import SwiftUI

// MARK: - KeyboardHintOverlay

/// Shows available keyboard shortcuts when the user long-presses the Cmd key.
/// Install as a transparent overlay on the main content area.
struct KeyboardHintOverlay: View {

    struct Hint: Identifiable {
        let id = UUID()
        let keys: String
        let description: String
    }

    private let hints: [Hint] = [
        Hint(keys: "⌘K / ⌘P",   description: "Command Palette"),
        Hint(keys: "⌘\\",        description: "Split Horizontal"),
        Hint(keys: "⌘⇧\\",      description: "Split Vertical"),
        Hint(keys: "⌘W",         description: "Close Pane"),
        Hint(keys: "⌘[",         description: "Focus Previous Pane"),
        Hint(keys: "⌘]",         description: "Focus Next Pane"),
        Hint(keys: "⌘T",         description: "New Workspace"),
        Hint(keys: "⌘⇧M",       description: "Toggle Minimal Mode"),
        Hint(keys: "⌘⇧F",       description: "Toggle Find"),
        Hint(keys: "⌘I",         description: "Toggle AI Chat"),
        Hint(keys: "⌘⇧S",       description: "Toggle Sidebar"),
        Hint(keys: "⌘Z",         description: "Zoom Focused Pane"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Keyboard Shortcuts")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.bottom, 8)

            ForEach(hints) { hint in
                HStack(spacing: 12) {
                    Text(hint.keys)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.primary)
                        .frame(width: 80, alignment: .trailing)

                    Text(hint.description)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)

                    Spacer()
                }
                .padding(.vertical, 3)
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.ultraThinMaterial)
                .shadow(color: .black.opacity(0.4), radius: 20, x: 0, y: 8)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
        )
        .frame(width: 280)
    }
}

// MARK: - KeyboardHintModifier

/// View modifier that listens for Cmd-key long press and shows the hint overlay.
struct KeyboardHintModifier: ViewModifier {
    @State private var isVisible = false
    @State private var monitor: Any?

    func body(content: Content) -> some View {
        ZStack(alignment: .bottomTrailing) {
            content
                .onAppear { installMonitor() }
                .onDisappear { removeMonitor() }

            if isVisible {
                KeyboardHintOverlay()
                    .padding(24)
                    .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .bottomTrailing)))
                    .zIndex(200)
            }
        }
        .animation(.easeOut(duration: 0.15), value: isVisible)
    }

    private func installMonitor() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged]) { event in
            let onlyCmdDown = event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command
            DispatchQueue.main.async {
                self.isVisible = onlyCmdDown
            }
            return event
        }
    }

    private func removeMonitor() {
        if let m = monitor { NSEvent.removeMonitor(m) }
        monitor = nil
    }
}

extension View {
    func keyboardHintOverlay() -> some View {
        modifier(KeyboardHintModifier())
    }
}
