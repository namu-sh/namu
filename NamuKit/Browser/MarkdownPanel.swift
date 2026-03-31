import Foundation
import Combine

// MARK: - MarkdownPanel

/// A panel that displays Markdown file content with live file watching.
/// Monitors the source file for changes (including atomic renames used by many editors)
/// and reloads content automatically.
final class MarkdownPanel: ObservableObject {

    // MARK: - Identity

    let id: UUID

    // MARK: - Published state

    @Published var title: String
    @Published var content: String
    /// True when the file cannot be read after exhausting all retry attempts.
    /// UI can use this to show an error/unavailable state.
    @Published var isFileUnavailable: Bool = false

    // MARK: - File path

    private(set) var filePath: URL?

    // MARK: - File watching internals

    private var dispatchSource: DispatchSourceFileSystemObject?
    private var fileDescriptor: Int32 = -1

    // MARK: - Retry constants

    /// Maximum number of reattach attempts after a delete/rename event.
    private static let maxRetryAttempts = 6
    /// Delay in seconds between successive reattach attempts.
    private static let retryDelay: Double = 0.5

    // MARK: - Init

    init(id: UUID = UUID()) {
        self.id = id
        self.title = String(localized: "markdown.panel.default.title", defaultValue: "Markdown")
        self.content = ""
    }

    // MARK: - File loading

    /// Load a file at `url` and begin watching it for changes.
    func loadFile(_ url: URL) {
        filePath = url
        title = url.deletingPathExtension().lastPathComponent
        readContent(from: url)
        startWatching(url: url)
    }

    // MARK: - Lifecycle

    /// Cancel file watching and close the file descriptor.
    func close() {
        stopWatching()
    }

    /// Suspend file watching without closing the panel. Use when the panel is not visible
    /// (e.g. a non-zoomed pane while another pane is zoomed) to avoid unnecessary I/O.
    func pauseFileWatching() {
        stopWatching()
    }

    /// Resume file watching for the current file path. Re-reads content immediately.
    func resumeFileWatching() {
        guard let url = filePath else { return }
        readContent(from: url)
        startWatching(url: url)
    }

    // MARK: - Private

    /// Read file content, falling back from UTF-8 to ISO Latin-1 if needed.
    private func readContent(from url: URL) {
        let text: String?
        if let utf8 = try? String(contentsOf: url, encoding: .utf8) {
            text = utf8
        } else if let latin1 = try? String(contentsOf: url, encoding: .isoLatin1) {
            text = latin1
        } else {
            text = nil
        }

        guard let text else { return }
        DispatchQueue.main.async { [weak self] in
            self?.content = text
            self?.isFileUnavailable = false
        }
    }

    private func startWatching(url: URL) {
        stopWatching()

        let fd = Darwin.open(url.path, O_EVTONLY)
        guard fd >= 0 else { return }
        fileDescriptor = fd

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .delete, .rename, .extend],
            queue: DispatchQueue.global(qos: .utility)
        )

        source.setEventHandler { [weak self] in
            guard let self, let path = self.filePath else { return }
            let data = source.data
            if data.contains(.delete) || data.contains(.rename) {
                // File was deleted or renamed — attempt reattach.
                self.reattachWithRetry(url: path, attempt: 1)
            } else {
                // Write or extend — reload content.
                self.readContent(from: path)
            }
        }

        source.setCancelHandler { [weak self] in
            guard let self, self.fileDescriptor >= 0 else { return }
            Darwin.close(self.fileDescriptor)
            self.fileDescriptor = -1
        }

        dispatchSource = source
        source.resume()
    }

    /// Attempt to reattach the file watcher after a delete/rename event.
    /// Retries up to `maxRetryAttempts` times with `retryDelay` seconds between attempts.
    private func reattachWithRetry(url: URL, attempt: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.retryDelay) { [weak self] in
            guard let self else { return }

            // Try to open the file — if successful, restart watching and read content.
            let fd = Darwin.open(url.path, O_EVTONLY)
            if fd >= 0 {
                Darwin.close(fd)
                self.startWatching(url: url)
                self.readContent(from: url)
                return
            }

            // File not yet available — schedule next retry if under the limit.
            if attempt < Self.maxRetryAttempts {
                self.reattachWithRetry(url: url, attempt: attempt + 1)
            } else {
                // Exhausted retries — mark file as unavailable for UI feedback.
                self.isFileUnavailable = true
            }
        }
    }

    private func stopWatching() {
        dispatchSource?.cancel()
        dispatchSource = nil
        // fileDescriptor is closed by the cancel handler
    }
}
