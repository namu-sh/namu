import SwiftUI
import WebKit

// MARK: - BrowserPanelView

/// Embeddable browser panel with URL bar and navigation controls.
/// Can be placed as a pane leaf via PaneLeafView when panelType == .browser.
struct BrowserPanelView: View {
    @StateObject private var viewModel = BrowserViewModel()

    var body: some View {
        VStack(spacing: 0) {
            // Omnibar
            HStack(spacing: 6) {
                Button(action: { viewModel.goBack() }) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(viewModel.canGoBack ? .primary : .tertiary)
                .disabled(!viewModel.canGoBack)
                .help("Back")

                Button(action: { viewModel.goForward() }) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(viewModel.canGoForward ? .primary : .tertiary)
                .disabled(!viewModel.canGoForward)
                .help("Forward")

                Button(action: { viewModel.reload() }) {
                    Image(systemName: viewModel.isLoading ? "xmark" : "arrow.clockwise")
                        .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help(viewModel.isLoading ? "Stop" : "Reload")

                TextField("Enter URL...", text: $viewModel.urlText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, design: .monospaced))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color.white.opacity(0.06))
                    )
                    .onSubmit { viewModel.navigate() }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.black.opacity(0.3))

            // Separator
            Rectangle()
                .fill(Color.white.opacity(0.08))
                .frame(height: 1)

            // WebView
            BrowserWebView(viewModel: viewModel)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color.black)
    }
}

// MARK: - BrowserViewModel

final class BrowserViewModel: ObservableObject {
    @Published var urlText: String = "https://www.google.com"
    @Published var canGoBack: Bool = false
    @Published var canGoForward: Bool = false
    @Published var isLoading: Bool = false
    @Published var pageTitle: String = ""

    weak var webView: WKWebView?

    func navigate() {
        var urlString = urlText.trimmingCharacters(in: .whitespaces)
        guard !urlString.isEmpty else { return }

        // Add scheme if missing
        if !urlString.hasPrefix("http://") && !urlString.hasPrefix("https://") {
            if urlString.contains(".") && !urlString.contains(" ") {
                urlString = "https://\(urlString)"
            } else {
                // Treat as search
                urlString = "https://www.google.com/search?q=\(urlString.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? urlString)"
            }
        }

        guard let url = URL(string: urlString) else { return }
        webView?.load(URLRequest(url: url))
    }

    func goBack() {
        webView?.goBack()
    }

    func goForward() {
        webView?.goForward()
    }

    func reload() {
        if isLoading {
            webView?.stopLoading()
        } else {
            webView?.reload()
        }
    }
}

// MARK: - BrowserWebView

struct BrowserWebView: NSViewRepresentable {
    @ObservedObject var viewModel: BrowserViewModel

    func makeCoordinator() -> Coordinator {
        Coordinator(viewModel: viewModel)
    }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.preferences.isElementFullscreenEnabled = true

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
        viewModel.webView = webView

        // Load initial URL
        if let url = URL(string: viewModel.urlText) {
            webView.load(URLRequest(url: url))
        }

        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        context.coordinator.viewModel = viewModel
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var viewModel: BrowserViewModel

        init(viewModel: BrowserViewModel) {
            self.viewModel = viewModel
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            DispatchQueue.main.async { [weak self] in
                self?.viewModel.isLoading = true
                self?.syncState(webView)
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            DispatchQueue.main.async { [weak self] in
                self?.viewModel.isLoading = false
                self?.syncState(webView)
            }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            DispatchQueue.main.async { [weak self] in
                self?.viewModel.isLoading = false
                self?.syncState(webView)
            }
        }

        private func syncState(_ webView: WKWebView) {
            viewModel.canGoBack = webView.canGoBack
            viewModel.canGoForward = webView.canGoForward
            viewModel.pageTitle = webView.title ?? ""
            if let url = webView.url?.absoluteString {
                viewModel.urlText = url
            }
        }
    }
}
