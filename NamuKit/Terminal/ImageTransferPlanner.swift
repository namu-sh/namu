import Foundation

// MARK: - Types

enum ImageTransferMode { case paste, drop }
enum ImageTransferTarget { case local, remote(DetectedSSHSession) }

struct ImageTransferPlan {
    let mode: ImageTransferMode
    let target: ImageTransferTarget
    let operations: [ImageTransferOperation]
}

struct ImageTransferOperation: Identifiable {
    let id = UUID()
    let fileURL: URL
    let fileName: String
    let isImage: Bool
}

// MARK: - ImageTransferPlanner

@MainActor
final class ImageTransferPlanner {

    /// Plan how to handle dropped/pasted files based on whether we're in a local or SSH session.
    static func plan(
        fileURLs: [URL],
        mode: ImageTransferMode,
        sshSession: DetectedSSHSession?
    ) -> ImageTransferPlan {
        let target: ImageTransferTarget = sshSession.map { .remote($0) } ?? .local
        let ops = fileURLs.map { url in
            let isImage = ["png", "jpg", "jpeg", "gif", "bmp", "tiff", "webp", "svg"]
                .contains(url.pathExtension.lowercased())
            return ImageTransferOperation(fileURL: url, fileName: url.lastPathComponent, isImage: isImage)
        }
        return ImageTransferPlan(mode: mode, target: target, operations: ops)
    }

    /// Execute a transfer plan: for local, insert file paths; for remote, upload via scp.
    static func execute(plan: ImageTransferPlan, sendText: @escaping (String) -> Void) async {
        switch plan.target {
        case .local:
            let paths = plan.operations.map { shellEscape($0.fileURL.path) }.joined(separator: " ")
            sendText(paths)
        case .remote(let session):
            for op in plan.operations {
                let remotePath = "~/\(op.fileName)"
                let args = session.scpArguments(localPath: op.fileURL.path, remotePath: remotePath)
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/scp")
                process.arguments = args
                process.standardInput = FileHandle.nullDevice
                process.standardOutput = FileHandle.nullDevice
                process.standardError = FileHandle.nullDevice
                try? process.run()
                process.waitUntilExit()
                if process.terminationStatus == 0 {
                    sendText(remotePath + " ")
                }
            }
        }
    }

    // MARK: - Private

    private static func shellEscape(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
