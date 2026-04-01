import AppKit
import SwiftUI

/// NSHostingView subclass that reports zero safe area insets.
/// This forces SwiftUI content to fill the entire view frame,
/// ignoring the titlebar safe area that AppKit normally reports.
final class SafeAreaFreeHostingView<T: View>: NSHostingView<T> {
    private lazy var zeroLayoutGuide: NSLayoutGuide = {
        let guide = NSLayoutGuide()
        addLayoutGuide(guide)
        NSLayoutConstraint.activate([
            leadingAnchor.constraint(equalTo: guide.leadingAnchor),
            topAnchor.constraint(equalTo: guide.topAnchor),
            trailingAnchor.constraint(equalTo: guide.trailingAnchor),
            bottomAnchor.constraint(equalTo: guide.bottomAnchor),
        ])
        return guide
    }()

    @MainActor required init(rootView: T) {
        super.init(rootView: rootView)
        _ = zeroLayoutGuide // force lazy init
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var safeAreaRect: NSRect { frame }

    override var safeAreaInsets: NSEdgeInsets {
        NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
    }

    override var safeAreaLayoutGuide: NSLayoutGuide { zeroLayoutGuide }

    override var additionalSafeAreaInsets: NSEdgeInsets {
        get { NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0) }
        set {}
    }
}

/// NSViewRepresentable that wraps SwiftUI content in a SafeAreaFreeHostingView,
/// effectively zeroing the safe area for all children.
struct SafeAreaFreeView<Content: View>: NSViewRepresentable {
    let content: () -> Content

    init(@ViewBuilder content: @escaping () -> Content) {
        self.content = content
    }

    func makeNSView(context: Context) -> SafeAreaFreeHostingView<Content> {
        SafeAreaFreeHostingView(rootView: content())
    }

    func updateNSView(_ nsView: SafeAreaFreeHostingView<Content>, context: Context) {
        nsView.rootView = content()
    }
}
