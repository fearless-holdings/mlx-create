import CoreGraphics
import Foundation
import ImageIO

/// Builds small real images (no metadata chunks) with CoreGraphics and ImageIO.
enum TestPNG {
    static func make(width: Int, height: Int) throws -> Data {
        try TestImage.encode(width: width, height: height, type: "public.png")
    }
}

enum TestImage {
    /// A solid-colour image of `type` (a UTI such as `public.png` or `public.jpeg`).
    static func encode(width: Int, height: Int, type: String) throws -> Data {
        let space = CGColorSpaceCreateDeviceRGB()
        guard
            let ctx = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        else { throw TestError.failed("context") }
        ctx.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let image = ctx.makeImage() else { throw TestError.failed("image") }
        let out = NSMutableData()
        guard let dst = CGImageDestinationCreateWithData(out, type as CFString, 1, nil) else {
            throw TestError.failed("destination")
        }
        CGImageDestinationAddImage(dst, image, nil)
        guard CGImageDestinationFinalize(dst) else { throw TestError.failed("finalize") }
        return out as Data
    }
}

enum TestError: Error {
    case failed(String)
}
