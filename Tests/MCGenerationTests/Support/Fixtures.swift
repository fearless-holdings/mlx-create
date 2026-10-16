import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Builds real PNG bytes (so the store reads a genuine header) and engine SSE replies in the upstream wire shape.
enum PNGFixture {
    static func make(width: Int, height: Int) -> Data {
        let space = CGColorSpaceCreateDeviceRGB()
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let output = NSMutableData()
        let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        CGImageDestinationFinalize(destination)
        return output as Data
    }

    /// A complete SSE reply: progress events followed by the completion event carrying the PNG.
    static func sseReply(images: Int, width: Int, height: Int, steps: Int = 4) -> Data {
        _ = images
        return sseHead(steps: steps) + sseTail(width: width, height: height)
    }

    /// The start of a generation: progress events, no image yet.
    static func sseHead(steps: Int = 4) -> Data {
        var text = ""
        for step in 1...steps {
            text += "data: {\"type\":\"progress\",\"stage\":\"Generating\",\"step\":\(step),\"total\":\(steps)}\n\n"
        }
        return Data(text.utf8)
    }

    /// The end of a generation: the completion event with the PNG as base64 in `data[0].b64_json`.
    static func sseTail(width: Int, height: Int) -> Data {
        let base64 = make(width: width, height: height).base64EncodedString()
        let text = "data: {\"type\":\"complete\",\"data\":[{\"b64_json\":\"\(base64)\"}]}\n\n"
        return Data(text.utf8)
    }

    static func oomBody() -> Data {
        Data(#"{"error":{"message":"Not enough memory","type":"out_of_memory"}}"#.utf8)
    }
}
