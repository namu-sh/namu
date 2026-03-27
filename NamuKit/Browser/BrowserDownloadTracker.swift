import Foundation
import WebKit

// MARK: - BrowserDownloadTracker

/// Tracks WKDownload lifecycle events and provides async waiting for completion.
@MainActor
final class BrowserDownloadTracker: NSObject {

    // MARK: - Types

    struct DownloadEvent {
        enum Outcome { case completed, failed }
        let outcome: Outcome
        let filename: String?
        let fileURL: URL?
        let error: Error?
    }

    // MARK: - Shared instance

    static let shared = BrowserDownloadTracker()

    // MARK: - Properties

    /// Each waiter gets a unique token so timeout and dispatch never double-resume.
    private var waiters: [UUID: CheckedContinuation<DownloadEvent, Error>] = [:]
    private var activeDownloads: [ObjectIdentifier: WKDownload] = [:]

    // MARK: - Init

    override private init() {}

    // MARK: - Public API

    func trackDownload(_ download: WKDownload) {
        download.delegate = self
        activeDownloads[ObjectIdentifier(download)] = download
    }

    func waitForDownload(timeout: TimeInterval = 30) async throws -> DownloadEvent {
        let token = UUID()
        return try await withCheckedThrowingContinuation { continuation in
            waiters[token] = continuation
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                guard let self else { return }
                // Only resume if this specific waiter is still pending.
                if let cont = self.waiters.removeValue(forKey: token) {
                    cont.resume(throwing: BrowserError.timeout("waitForDownload"))
                }
            }
        }
    }

    // MARK: - Internal dispatch

    private func dispatch(event: DownloadEvent, for download: WKDownload) {
        activeDownloads.removeValue(forKey: ObjectIdentifier(download))
        // Resume the oldest waiter (FIFO).
        guard let firstKey = waiters.keys.sorted(by: { $0.uuidString < $1.uuidString }).first,
              let continuation = waiters.removeValue(forKey: firstKey) else { return }
        continuation.resume(returning: event)
    }
}

// MARK: - WKDownloadDelegate

extension BrowserDownloadTracker: WKDownloadDelegate {

    nonisolated func download(
        _ download: WKDownload,
        decideDestinationUsing response: URLResponse,
        suggestedFilename: String,
        completionHandler: @escaping (URL?) -> Void
    ) {
        let downloadsURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        let destination = downloadsURL?.appendingPathComponent(suggestedFilename)
        completionHandler(destination)
    }

    nonisolated func downloadDidFinish(_ download: WKDownload) {
        Task { @MainActor in
            let filename = download.originalRequest?.url?.lastPathComponent
            let event = DownloadEvent(
                outcome: .completed,
                filename: filename,
                fileURL: nil,
                error: nil
            )
            self.dispatch(event: event, for: download)
        }
    }

    nonisolated func download(
        _ download: WKDownload,
        didFailWithError error: Error,
        resumeData: Data?
    ) {
        Task { @MainActor in
            let filename = download.originalRequest?.url?.lastPathComponent
            let event = DownloadEvent(
                outcome: .failed,
                filename: filename,
                fileURL: nil,
                error: error
            )
            self.dispatch(event: event, for: download)
        }
    }
}
