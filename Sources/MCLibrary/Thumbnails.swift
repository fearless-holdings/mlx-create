import Foundation
import ImageIO

/// ImageIO helpers for the library: PNG pixel size and HEIC thumbnails.
public enum Thumbnails {
    /// Pixel size from the PNG header. This is the engine's real output size (D24).
    public static func pixelSize(ofPNG png: Data) throws -> (width: Int, height: Int) {
        guard let source = CGImageSourceCreateWithData(png as CFData, nil),
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
            let width = properties[kCGImagePropertyPixelWidth] as? Int,
            let height = properties[kCGImagePropertyPixelHeight] as? Int
        else {
            throw LibraryError.unreadableImage
        }
        return (width, height)
    }

    /// A HEIC thumbnail whose longer side is at most `maxPixelSize`, from a PNG.
    public static func makeHEIC(fromPNG png: Data, maxPixelSize: Int) throws -> Data {
        try makeHEIC(fromImageData: png, maxPixelSize: maxPixelSize)
    }

    /// A HEIC thumbnail whose longer side is at most `maxPixelSize`, from any format ImageIO can read (PNG, JPEG, WebP…).
    /// Throws ``LibraryError/unreadableImage`` when the bytes are not an image.
    public static func makeHEIC(fromImageData data: Data, maxPixelSize: Int) throws -> Data {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            throw LibraryError.unreadableImage
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw LibraryError.unreadableImage
        }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, "public.heic" as CFString, 1, nil) else {
            throw LibraryError.encodingFailed
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw LibraryError.encodingFailed
        }
        return output as Data
    }
}
