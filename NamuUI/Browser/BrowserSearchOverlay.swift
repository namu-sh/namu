import SwiftUI
import WebKit

// MARK: - BrowserSearchOverlay

/// Find-in-page overlay that floats over the browser panel.
/// Matches are highlighted via WKWebView's built-in find API on macOS 13+,
/// with a JS fallback for older systems.
struct BrowserSearchOverlay: View {

    // MARK: - State

    @Binding var isVisible: Bool
    let webView: WKWebView

    @State private var query: String = ""
    @State private var matchCount: Int = 0
    @State private var currentMatch: Int = 0
    @FocusState private var fieldFocused: Bool

    // MARK: - Body

    var body: some View {
        if isVisible {
            HStack(spacing: 8) {
                // Search field
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)

                    TextField(String(localized: "browser.findInPage.fieldPlaceholder", defaultValue: "Find in page"), text: $query)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13))
                        .focused($fieldFocused)
                        .onSubmit { navigateMatch(forward: true) }
                        .onChange(of: query) { _ in performSearch() }

                    if !query.isEmpty {
                        Text(matchSummary)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .fixedSize()

                        Button(action: { clearSearch() }) {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(.regularMaterial)
                )
                .frame(minWidth: 200, maxWidth: 320)

                // Prev / Next
                HStack(spacing: 2) {
                    Button(action: { navigateMatch(forward: false) }) {
                        Image(systemName: "chevron.up")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .buttonStyle(.plain)
                    .disabled(query.isEmpty || matchCount == 0)
                    .keyboardShortcut("g", modifiers: [.command, .shift])
                    .help(String(localized: "browser.findInPage.previous.tooltip", defaultValue: "Previous match (⌘⇧G)"))
                    .accessibilityLabel(String(localized: "browser.findInPage.previous.accessibility", defaultValue: "Previous match"))

                    Button(action: { navigateMatch(forward: true) }) {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .buttonStyle(.plain)
                    .disabled(query.isEmpty || matchCount == 0)
                    .keyboardShortcut("g", modifiers: .command)
                    .help(String(localized: "browser.findInPage.next.tooltip", defaultValue: "Next match (⌘G)"))
                    .accessibilityLabel(String(localized: "browser.findInPage.next.accessibility", defaultValue: "Next match"))
                }
                .padding(4)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(.regularMaterial)
                )

                // Close
                Button(action: { dismiss() }) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.escape, modifiers: [])
                .help(String(localized: "browser.findInPage.close.tooltip", defaultValue: "Close find bar (Esc)"))
                .accessibilityLabel(String(localized: "browser.findInPage.close.accessibility", defaultValue: "Close"))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(.ultraThinMaterial)
                    .shadow(color: .black.opacity(0.25), radius: 8, y: 4)
            )
            .transition(.move(edge: .top).combined(with: .opacity))
            .onAppear { fieldFocused = true }
        }
    }

    // MARK: - Computed

    private var matchSummary: String {
        if matchCount == 0 { return String(localized: "browser.findInPage.noResults", defaultValue: "No results") }
        return "\(currentMatch)/\(matchCount)"
    }

    // MARK: - Actions

    private func performSearch() {
        guard !query.isEmpty else {
            clearHighlights()
            matchCount = 0
            currentMatch = 0
            return
        }
        if #available(macOS 13.0, *) {
            webView.find(query) { result in
                // WKFindResult only tells us found/not-found, not the count.
                self.matchCount = result.matchFound ? 1 : 0
                self.currentMatch = result.matchFound ? 1 : 0
            }
        } else {
            jsHighlight(query: query)
        }
    }

    private func navigateMatch(forward: Bool) {
        guard !query.isEmpty else { return }
        if #available(macOS 13.0, *) {
            if forward {
                webView.find(query) { result in
                    self.matchCount = result.matchFound ? max(1, self.matchCount) : 0
                    if result.matchFound { self.currentMatch = self.currentMatch % self.matchCount + 1 }
                }
            } else {
                // Reverse search: use JS fallback which supports direction
                jsFind(query: query, forward: false)
            }
        } else {
            jsFind(query: query, forward: forward)
        }
    }

    private func dismiss() {
        clearSearch()
        withAnimation(.easeOut(duration: 0.15)) { isVisible = false }
    }

    private func clearSearch() {
        query = ""
        matchCount = 0
        currentMatch = 0
        clearHighlights()
    }

    // MARK: - JS helpers (macOS 12 fallback)

    private func jsHighlight(query: String) {
        let escaped = query
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")

        let script = """
        (function() {
            window.__namuFind = window.__namuFind || {};
            // Remove previous highlights
            document.querySelectorAll('.__namu_highlight').forEach(function(el) {
                var parent = el.parentNode;
                parent.replaceChild(document.createTextNode(el.textContent), el);
                parent.normalize();
            });
            if (!"\(escaped)") return 0;
            var count = 0;
            var regex = new RegExp("\(escaped)", "gi");
            function walk(node) {
                if (node.nodeType === 3) {
                    var text = node.nodeValue;
                    var match;
                    var last = 0;
                    var frag = document.createDocumentFragment();
                    while ((match = regex.exec(text)) !== null) {
                        frag.appendChild(document.createTextNode(text.slice(last, match.index)));
                        var span = document.createElement('span');
                        span.className = '__namu_highlight';
                        span.style.cssText = 'background:#ffdd57;color:#000;border-radius:2px;';
                        span.textContent = match[0];
                        frag.appendChild(span);
                        last = match.index + match[0].length;
                        count++;
                    }
                    if (count > 0) {
                        frag.appendChild(document.createTextNode(text.slice(last)));
                        node.parentNode.replaceChild(frag, node);
                    }
                } else if (node.nodeType === 1 && !['SCRIPT','STYLE','NOSCRIPT'].includes(node.tagName)) {
                    Array.from(node.childNodes).forEach(walk);
                }
            }
            walk(document.body);
            return count;
        })();
        """
        webView.evaluateJavaScript(script) { result, _ in
            if let n = result as? Int { self.matchCount = n; self.currentMatch = n > 0 ? 1 : 0 }
        }
    }

    private func jsFind(query: String, forward: Bool) {
        // window.find is broadly supported and handles direction
        let dir = forward ? "false" : "true"
        let escaped = query
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        webView.evaluateJavaScript("window.find(\"\(escaped)\", false, \(dir));", completionHandler: nil)
    }

    private func clearHighlights() {
        let script = """
        document.querySelectorAll('.__namu_highlight').forEach(function(el) {
            var parent = el.parentNode;
            parent.replaceChild(document.createTextNode(el.textContent), el);
            parent.normalize();
        });
        """
        webView.evaluateJavaScript(script, completionHandler: nil)
    }
}
