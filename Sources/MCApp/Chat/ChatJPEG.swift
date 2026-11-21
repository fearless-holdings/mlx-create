import Foundation
import ImageIO
import UniformTypeIdentifiers

/// JPEGs for the agent's multimodal messages (D57): the referent image travels as a small JPEG inside the chat request.
enum ChatJPEG {
    /// A JPEG of the image at `fileURL`, longest side at most `longestSide`, or nil on any failure (missing or
    /// unreadable file, encode failure). The thumbnail and encode run off the caller's actor.
    static func make(fileURL: URL, longestSide: Int = 768, quality: Double = 0.85) async -> Data? {
        await Task.detached(priority: .utility) {
            render(fileURL: fileURL, longestSide: longestSide, quality: quality)
        }.value
    }

    /// The ImageIO thumbnail-to-JPEG encode; synchronous so it never lands on the main actor.
    private static func render(fileURL: URL, longestSide: Int, quality: Double) -> Data? {
        guard
            let source = CGImageSourceCreateWithURL(fileURL as CFURL, nil),
            let image = CGImageSourceCreateThumbnailAtIndex(
                source, 0,
                [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: longestSide,
                ] as CFDictionary)
        else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(
            destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }
}
