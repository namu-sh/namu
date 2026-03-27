import Foundation
import AppKit

// MARK: - ImageTransferResult

enum ImageTransferResult {
    case kittyInline(apcSequence: String)   // APC escape sequence for local Kitty display
    case remotePath(String)                  // Remote path after scp upload
    case localPath(String)                   // Local file path pasted as text
    case failure(String)                     // Error message
}

// MARK: - ImageTransfer

/// Handles image and file transfer into terminal sessions.
///
/// - Local terminal + image: encodes as Kitty graphics protocol APC sequence
/// - SSH terminal + image/file: uploads via scp, returns remote path
/// - Local terminal + non-image file: returns the local file path as text
final class ImageTransfer {

    // MARK: - Public API

    /// Transfer a file (or image) into a terminal session.
    /// - Parameters:
    ///   - url: Local file URL to transfer.
    ///   - session: The target terminal session.
    ///   - progressHandler: Called with 0.0…1.0 progress during scp upload.
    ///   - completion: Called with the transfer result on the main queue.
    static func transfer(
        url: URL,
        session: TerminalSession,
        progressHandler: ((Double) -> Void)? = nil,
        completion: @escaping (ImageTransferResult) -> Void
    ) {
        let isImage = isImageFile(url)
        let sshInfo = session.detectSSHSession()

        if let ssh = sshInfo {
            // SSH terminal: upload via scp
            uploadViaSCP(url: url, ssh: ssh, progressHandler: progressHandler) { result in
                DispatchQueue.main.async { completion(result) }
            }
        } else if isImage {
            // Local terminal + image: encode as Kitty graphics protocol
            DispatchQueue.global(qos: .userInitiated).async {
                let result = encodeKittyImage(url: url)
                DispatchQueue.main.async { completion(result) }
            }
        } else {
            // Local terminal + non-image: paste the path
            completion(.localPath(url.path))
        }
    }

    /// Transfer an image from the clipboard into a terminal session.
    static func transferClipboardImage(
        session: TerminalSession,
        completion: @escaping (ImageTransferResult) -> Void
    ) {
        guard let image = NSPasteboard.general.readObjects(
            forClasses: [NSImage.self], options: nil
        )?.first as? NSImage else {
            completion(.failure("No image in clipboard"))
            return
        }

        // Write to a temp file then use the normal transfer path
        guard let tempURL = writeImageToTemp(image) else {
            completion(.failure("Failed to write clipboard image to temp file"))
            return
        }

        let sshInfo = session.detectSSHSession()
        if let ssh = sshInfo {
            uploadViaSCP(url: tempURL, ssh: ssh, progressHandler: nil) { result in
                try? FileManager.default.removeItem(at: tempURL)
                DispatchQueue.main.async { completion(result) }
            }
        } else {
            DispatchQueue.global(qos: .userInitiated).async {
                let result = encodeKittyImage(url: tempURL)
                try? FileManager.default.removeItem(at: tempURL)
                DispatchQueue.main.async { completion(result) }
            }
        }
    }

    // MARK: - Kitty Graphics Protocol

    /// Encode an image file as a Kitty graphics protocol APC sequence.
    /// Uses the base64-chunked transmission format (action=T, format=PNG/JPEG).
    static func encodeKittyImage(url: URL) -> ImageTransferResult {
        guard let data = try? Data(contentsOf: url) else {
            return .failure("Cannot read image file: \(url.path)")
        }

        // Convert to PNG for consistent encoding
        let pngData: Data
        if let img = NSImage(data: data), let tiff = img.tiffRepresentation,
           let rep = NSBitmapImageRep(data: tiff),
           let png = rep.representation(using: .png, properties: [:]) {
            pngData = png
        } else {
            pngData = data
        }

        let base64 = pngData.base64EncodedString()

        // Kitty graphics protocol: chunk into 4096-byte base64 pieces
        // Format: APC Gaction=T,format=100,medium=d,size=<n>,width=<w>,height=<h>;<chunk> ST
        // For simplicity use action=T (transmit+display), format=100 (PNG), medium=d (direct)
        let chunkSize = 4096
        var chunks: [String] = []
        var offset = base64.startIndex
        while offset < base64.endIndex {
            let end = base64.index(offset, offsetBy: chunkSize, limitedBy: base64.endIndex) ?? base64.endIndex
            chunks.append(String(base64[offset..<end]))
            offset = end
        }

        var sequence = ""
        for (i, chunk) in chunks.enumerated() {
            let isLast = i == chunks.count - 1
            let more = isLast ? 0 : 1
            if i == 0 {
                // First chunk: include format parameters
                sequence += "\u{1B}_Ga=T,f=100,m=\(more);\(chunk)\u{1B}\\"
            } else {
                // Continuation chunks
                sequence += "\u{1B}_Gm=\(more);\(chunk)\u{1B}\\"
            }
        }

        // Append a newline so the cursor moves past the image
        sequence += "\n"
        return .kittyInline(apcSequence: sequence)
    }

    // MARK: - SCP Upload

    /// Upload a file to a remote host via scp.
    /// The remote path is /tmp/<filename> by default.
    static func uploadViaSCP(
        url: URL,
        ssh: DetectedSSHSession,
        progressHandler: ((Double) -> Void)?,
        completion: @escaping (ImageTransferResult) -> Void
    ) {
        let filename = url.lastPathComponent
        let remotePath = "/tmp/\(filename)"
        let args = ssh.scpArguments(localPath: url.path, remotePath: remotePath)

        progressHandler?(0.1)

        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/scp")
            process.arguments = args

            let errPipe = Pipe()
            process.standardError = errPipe

            do {
                try process.run()
                // Poll progress (scp -q gives no progress, so fake it)
                progressHandler?(0.5)
                process.waitUntilExit()
            } catch {
                completion(.failure("scp launch failed: \(error.localizedDescription)"))
                return
            }

            if process.terminationStatus == 0 {
                progressHandler?(1.0)
                completion(.remotePath(remotePath))
            } else {
                let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                let errMsg = String(data: errData, encoding: .utf8) ?? "scp failed"
                completion(.failure(errMsg.trimmingCharacters(in: .whitespacesAndNewlines)))
            }
        }
    }

    // MARK: - Helpers

    private static func isImageFile(_ url: URL) -> Bool {
        let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "bmp", "tiff", "tif", "heic", "heif"]
        return imageExtensions.contains(url.pathExtension.lowercased())
    }

    private static func writeImageToTemp(_ image: NSImage) -> URL? {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return nil }

        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("namu-clipboard-\(UUID().uuidString).png")
        do {
            try png.write(to: url)
            return url
        } catch {
            return nil
        }
    }
}
