import AppKit
import WebKit
import SwiftUI

// MARK: - BrowserPopupWindowController

/// Manages popup windows created by window.open() in web content.
/// Each popup gets its own floating NSWindow backed by a WKWebView.
///
/// Features:
/// - Max nesting depth (3 levels) to prevent runaway popup chains
/// - Address bar showing current URL
/// - Back/forward navigation buttons in a toolbar
/// - WKUIDelegate for JS alert/confirm/prompt dialogs
/// - Cascading close: closing a popup closes all its children
final class BrowserPopupWindowController: NSObject {

    // MARK: - Constants

    static let maxNestingDepth = 3

    // MARK: - Types

    private final class PopupWindow: NSObject, WKNavigationDelegate, WKUIDelegate, NSWindowDelegate {
        let window: NSWindow
        let webView: WKWebView
        private let urlField: NSTextField
        private let backButton: NSButton
        private let forwardButton: NSButton

        var onClose: (() -> Void)?
        var childPopups: [PopupWindow] = []
        let nestingDepth: Int
        private var urlObservation: NSKeyValueObservation?
        private var titleObservation: NSKeyValueObservation?
        private weak var parentConfiguration: WKWebViewConfiguration?

        init(
            configuration: WKWebViewConfiguration,
            frame: NSRect,
            nestingDepth: Int,
            parentConfiguration: WKWebViewConfiguration?
        ) {
            self.nestingDepth = nestingDepth
            self.parentConfiguration = parentConfiguration

            let wv = WKWebView(frame: .zero, configuration: configuration)
            wv.allowsBackForwardNavigationGestures = true

            // --- Toolbar view ---
            let toolbar = NSView()
            toolbar.translatesAutoresizingMaskIntoConstraints = false

            let back = NSButton(title: "‹", target: nil, action: nil)
            back.bezelStyle = .roundRect
            back.isBordered = false
            back.font = .systemFont(ofSize: 16, weight: .medium)
            back.translatesAutoresizingMaskIntoConstraints = false

            let forward = NSButton(title: "›", target: nil, action: nil)
            forward.bezelStyle = .roundRect
            forward.isBordered = false
            forward.font = .systemFont(ofSize: 16, weight: .medium)
            forward.translatesAutoresizingMaskIntoConstraints = false

            let urlF = NSTextField(string: "")
            urlF.isEditable = false
            urlF.isSelectable = true
            urlF.isBordered = false
            urlF.drawsBackground = false
            urlF.font = .systemFont(ofSize: 11)
            urlF.textColor = .secondaryLabelColor
            urlF.lineBreakMode = .byTruncatingMiddle
            urlF.translatesAutoresizingMaskIntoConstraints = false
            urlF.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

            toolbar.addSubview(back)
            toolbar.addSubview(forward)
            toolbar.addSubview(urlF)

            NSLayoutConstraint.activate([
                back.leadingAnchor.constraint(equalTo: toolbar.leadingAnchor, constant: 6),
                back.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),
                back.widthAnchor.constraint(equalToConstant: 24),

                forward.leadingAnchor.constraint(equalTo: back.trailingAnchor, constant: 2),
                forward.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),
                forward.widthAnchor.constraint(equalToConstant: 24),

                urlF.leadingAnchor.constraint(equalTo: forward.trailingAnchor, constant: 6),
                urlF.trailingAnchor.constraint(equalTo: toolbar.trailingAnchor, constant: -8),
                urlF.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),

                toolbar.heightAnchor.constraint(equalToConstant: 28),
            ])

            let containerView = NSView()
            containerView.addSubview(toolbar)
            containerView.addSubview(wv)
            wv.translatesAutoresizingMaskIntoConstraints = false
            toolbar.translatesAutoresizingMaskIntoConstraints = false

            let win = NSWindow(
                contentRect: frame,
                styleMask: [.titled, .closable, .resizable, .miniaturizable],
                backing: .buffered,
                defer: false
            )
            win.contentView = containerView
            win.isReleasedWhenClosed = false

            NSLayoutConstraint.activate([
                toolbar.topAnchor.constraint(equalTo: containerView.topAnchor),
                toolbar.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
                toolbar.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),

                wv.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
                wv.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
                wv.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),
                wv.bottomAnchor.constraint(equalTo: containerView.bottomAnchor),
            ])

            self.webView = wv
            self.window = win
            self.urlField = urlF
            self.backButton = back
            self.forwardButton = forward

            super.init()

            wv.navigationDelegate = self
            wv.uiDelegate = self
            win.delegate = self

            back.target = self
            back.action = #selector(goBack)
            forward.target = self
            forward.action = #selector(goForward)

            // KVO for URL and title
            urlObservation = wv.observe(\.url, options: [.new]) { [weak self] _, change in
                let urlStr = change.newValue??.absoluteString ?? ""
                DispatchQueue.main.async { self?.urlField.stringValue = urlStr }
            }
            titleObservation = wv.observe(\.title, options: [.new]) { [weak self] _, change in
                guard let title = change.newValue ?? nil, !title.isEmpty else { return }
                DispatchQueue.main.async { self?.window.title = title }
            }
        }

        deinit {
            urlObservation?.invalidate()
            titleObservation?.invalidate()
        }

        @objc private func goBack() { webView.goBack() }
        @objc private func goForward() { webView.goForward() }

        // MARK: - Child popup management

        func addChild(_ child: PopupWindow) { childPopups.append(child) }

        func closeAllChildren() {
            for child in childPopups {
                child.closeAllChildren()
                child.window.close()
            }
            childPopups.removeAll()
        }

        // MARK: - WKNavigationDelegate

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            if let title = webView.title, !title.isEmpty {
                window.title = title
            }
            backButton.isEnabled = webView.canGoBack
            forwardButton.isEnabled = webView.canGoForward
        }

        func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
            backButton.isEnabled = webView.canGoBack
            forwardButton.isEnabled = webView.canGoForward
        }

        // MARK: - WKUIDelegate (JS dialogs + nested popups)

        func webViewDidClose(_ webView: WKWebView) {
            window.close()
        }

        func webView(
            _ webView: WKWebView,
            createWebViewWith configuration: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction,
            windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            let nextDepth = nestingDepth + 1
            guard nextDepth <= BrowserPopupWindowController.maxNestingDepth else { return nil }

            let frame = resolveFrame(from: windowFeatures)
            let child = PopupWindow(
                configuration: configuration,
                frame: frame,
                nestingDepth: nextDepth,
                parentConfiguration: webView.configuration
            )
            child.onClose = { [weak self] in
                self?.childPopups.removeAll { $0 === child }
            }
            addChild(child)
            child.window.title = navigationAction.request.url?.host ?? "Popup"
            child.window.makeKeyAndOrderFront(nil)
            return child.webView
        }

        func webView(
            _ webView: WKWebView,
            runJavaScriptAlertPanelWithMessage message: String,
            initiatedByFrame frame: WKFrameInfo,
            completionHandler: @escaping () -> Void
        ) {
            let alert = NSAlert()
            alert.alertStyle = .informational
            alert.messageText = dialogTitle(for: webView)
            alert.informativeText = message
            alert.addButton(withTitle: "OK")
            presentAlert(alert, for: webView) { _ in completionHandler() }
        }

        func webView(
            _ webView: WKWebView,
            runJavaScriptConfirmPanelWithMessage message: String,
            initiatedByFrame frame: WKFrameInfo,
            completionHandler: @escaping (Bool) -> Void
        ) {
            let alert = NSAlert()
            alert.alertStyle = .informational
            alert.messageText = dialogTitle(for: webView)
            alert.informativeText = message
            alert.addButton(withTitle: "OK")
            alert.addButton(withTitle: "Cancel")
            presentAlert(alert, for: webView) { response in
                completionHandler(response == .alertFirstButtonReturn)
            }
        }

        func webView(
            _ webView: WKWebView,
            runJavaScriptTextInputPanelWithPrompt prompt: String,
            defaultText: String?,
            initiatedByFrame frame: WKFrameInfo,
            completionHandler: @escaping (String?) -> Void
        ) {
            let alert = NSAlert()
            alert.alertStyle = .informational
            alert.messageText = dialogTitle(for: webView)
            alert.informativeText = prompt
            alert.addButton(withTitle: "OK")
            alert.addButton(withTitle: "Cancel")

            let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
            field.stringValue = defaultText ?? ""
            alert.accessoryView = field

            presentAlert(alert, for: webView) { response in
                completionHandler(response == .alertFirstButtonReturn ? field.stringValue : nil)
            }
        }

        // MARK: - NSWindowDelegate

        func windowWillClose(_ notification: Notification) {
            urlObservation?.invalidate()
            urlObservation = nil
            titleObservation?.invalidate()
            titleObservation = nil

            closeAllChildren()

            webView.stopLoading()
            webView.navigationDelegate = nil
            webView.uiDelegate = nil

            onClose?()
        }

        // MARK: - Helpers

        private func dialogTitle(for webView: WKWebView) -> String {
            if let url = webView.url?.absoluteString, !url.isEmpty {
                return "The page at \(url) says:"
            }
            return "This page says:"
        }

        private func presentAlert(
            _ alert: NSAlert,
            for webView: WKWebView,
            completion: @escaping (NSApplication.ModalResponse) -> Void
        ) {
            if let win = webView.window {
                alert.beginSheetModal(for: win, completionHandler: completion)
            } else {
                completion(alert.runModal())
            }
        }

        private func resolveFrame(from features: WKWindowFeatures) -> NSRect {
            let screenFrame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
            let w = features.width.map { CGFloat($0.doubleValue) } ?? 900
            let h = features.height.map { CGFloat($0.doubleValue) } ?? 650
            let x = features.x.map { CGFloat($0.doubleValue) } ?? (screenFrame.midX - w / 2)
            let y = features.y.map { CGFloat($0.doubleValue) } ?? (screenFrame.midY - h / 2)
            return NSRect(
                x: max(screenFrame.minX, x),
                y: max(screenFrame.minY, y),
                width: min(w, screenFrame.width),
                height: min(h, screenFrame.height)
            )
        }
    }

    // MARK: - Properties

    private var popups: [ObjectIdentifier: PopupWindow] = [:]
    private weak var parentConfiguration: WKWebViewConfiguration?

    // MARK: - Init

    init(parentConfiguration: WKWebViewConfiguration) {
        self.parentConfiguration = parentConfiguration
    }

    // MARK: - WKUIDelegate support

    /// Call this from the parent WKWebView's `WKUIDelegate.webView(_:createWebViewWith:for:windowFeatures:)`.
    /// Returns the new WKWebView that should be returned from the delegate method.
    func createPopup(
        with configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        // Top-level popups start at depth 1
        guard 1 <= Self.maxNestingDepth else { return nil }

        let frame = resolveFrame(from: windowFeatures)
        let popup = PopupWindow(
            configuration: configuration,
            frame: frame,
            nestingDepth: 1,
            parentConfiguration: parentConfiguration
        )
        let key = ObjectIdentifier(popup.webView)
        popups[key] = popup

        popup.onClose = { [weak self] in
            self?.popups.removeValue(forKey: key)
        }

        popup.window.title = navigationAction.request.url?.host ?? "Popup"
        popup.window.makeKeyAndOrderFront(nil)
        return popup.webView
    }

    /// Close all open popups (e.g. when the parent panel is closed).
    func closeAll() {
        for popup in popups.values {
            popup.closeAllChildren()
            popup.window.close()
        }
        popups.removeAll()
    }

    // MARK: - Private helpers

    private func resolveFrame(from features: WKWindowFeatures) -> NSRect {
        let screenFrame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        let w = features.width.map { CGFloat($0.doubleValue) } ?? 900
        let h = features.height.map { CGFloat($0.doubleValue) } ?? 650
        let x = features.x.map { CGFloat($0.doubleValue) } ?? (screenFrame.midX - w / 2)
        let y = features.y.map { CGFloat($0.doubleValue) } ?? (screenFrame.midY - h / 2)
        return NSRect(
            x: max(screenFrame.minX, x),
            y: max(screenFrame.minY, y),
            width: min(w, screenFrame.width),
            height: min(h, screenFrame.height)
        )
    }
}
