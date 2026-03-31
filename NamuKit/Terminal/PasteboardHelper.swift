import AppKit
import Foundation
import UniformTypeIdentifiers

/// Intelligent clipboard reader that extracts the best text representation
/// from the pasteboard, handling rich text, URLs, and images.
enum PasteboardHelper {

    /// Maximum image size allowed for paste (10 MB).
    static let maximumImageBytes = 10 * 1024 * 1024

    // MARK: - Text extraction

    /// Extract the best text representation from the pasteboard.
    /// Priority: URL (shell-escaped) > plain string > HTML (converted) > RTF (converted).
    /// Returns nil if the pasteboard contains only image data.
    static func stringContents(from pasteboard: NSPasteboard) -> String? {
        // 1. Check for file URLs — shell-escape them
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [
            .urlReadingFileURLsOnly: true
        ]) as? [URL], !urls.isEmpty {
            return urls.map { shellEscapePath($0.path) }.joined(separator: " ")
        }

        // 2. Plain string
        if let str = pasteboard.string(forType: .string), !str.isEmpty {
            return str
        }

        // 3. UTF-8 plain text
        if let data = pasteboard.data(forType: NSPasteboard.PasteboardType("public.utf8-plain-text")),
           let str = String(data: data, encoding: .utf8), !str.isEmpty {
            return str
        }

        // 4. HTML — convert to plain text via NSAttributedString
        if let data = pasteboard.data(forType: .html),
           let attributed = NSAttributedString(html: data, documentAttributes: nil),
           !attributed.string.isEmpty {
            return attributed.string
        }

        // 5. RTF — convert to plain text
        if let data = pasteboard.data(forType: .rtf),
           let attributed = try? NSAttributedString(data: data, options: [
               .documentType: NSAttributedString.DocumentType.rtf
           ], documentAttributes: nil),
           !attributed.string.isEmpty {
            return attributed.string
        }

        // 6. RTFD — check for text content (not just images)
        if let data = pasteboard.data(forType: .rtfd),
           let attributed = try? NSAttributedString(data: data, options: [
               .documentType: NSAttributedString.DocumentType.rtfd
           ], documentAttributes: nil),
           !attributed.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // RTFD may contain only an image attachment with no real text.
            // Filter out the attachment character (U+FFFC).
            let cleaned = attributed.string.replacingOccurrences(of: "\u{FFFC}", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !cleaned.isEmpty {
                return cleaned
            }
        }

        return nil
    }

    // MARK: - Image detection

    /// Returns true if the pasteboard contains ONLY image data (no usable text).
    static func hasImageOnly(from pasteboard: NSPasteboard) -> Bool {
        // If we found text, it's not image-only.
        if stringContents(from: pasteboard) != nil {
            return false
        }
        return hasImageData(from: pasteboard)
    }

    /// Returns true if the pasteboard has any image data.
    static func hasImageData(from pasteboard: NSPasteboard) -> Bool {
        // Check for direct image types
        let imageTypes: [NSPasteboard.PasteboardType] = [.tiff, .png]
        for type in imageTypes {
            if pasteboard.data(forType: type) != nil {
                return true
            }
        }

        // Check UTType-based image types
        if let types = pasteboard.types {
            for type in types {
                if let utType = UTType(type.rawValue), utType.conforms(to: .image) {
                    return true
                }
            }
        }

        // Check if NSImage can read it
        if NSImage.canInit(with: pasteboard) {
            return true
        }

        return false
    }

    /// Extract image data as PNG from the pasteboard.
    /// Returns nil if no image or image exceeds size limit.
    static func imageAsPNG(from pasteboard: NSPasteboard) -> Data? {
        // Try direct PNG first
        if let pngData = pasteboard.data(forType: .png) {
            guard pngData.count <= maximumImageBytes else { return nil }
            return pngData
        }

        // Try TIFF and convert to PNG
        if let tiffData = pasteboard.data(forType: .tiff),
           let rep = NSBitmapImageRep(data: tiffData),
           let pngData = rep.representation(using: .png, properties: [:]) {
            guard pngData.count <= maximumImageBytes else { return nil }
            return pngData
        }

        // Try RTFD attachment images
        if let data = pasteboard.data(forType: .rtfd),
           let attributed = try? NSAttributedString(data: data, options: [
               .documentType: NSAttributedString.DocumentType.rtfd
           ], documentAttributes: nil) {
            // Walk attachments looking for image
            var imageData: Data?
            attributed.enumerateAttribute(.attachment, in: NSRange(location: 0, length: attributed.length)) { value, _, stop in
                guard let attachment = value as? NSTextAttachment,
                      let fileWrapper = attachment.fileWrapper,
                      let data = fileWrapper.regularFileContents else { return }
                if let rep = NSBitmapImageRep(data: data),
                   let png = rep.representation(using: .png, properties: [:]),
                   png.count <= maximumImageBytes {
                    imageData = png
                    stop.pointee = true
                }
            }
            if let imageData { return imageData }
        }

        // Fallback: NSImage
        if let image = NSImage(pasteboard: pasteboard),
           let tiff = image.tiffRepresentation,
           let rep = NSBitmapImageRep(data: tiff),
           let pngData = rep.representation(using: .png, properties: [:]) {
            guard pngData.count <= maximumImageBytes else { return nil }
            return pngData
        }

        return nil
    }

    // MARK: - Helpers

    /// Shell-escape a file path for safe pasting into a terminal.
    private static func shellEscapePath(_ path: String) -> String {
        // Use single-quote escaping: wrap in single quotes, escape internal single quotes.
        "'" + path.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }
}
