import Foundation
import ImageIO
import Testing

@testable import MCLibrary

@Suite struct ThumbnailTests {
    @Test func heicThumbnailHasLongSideOf512() throws {
        let png = try TestPNG.make(width: 1024, height: 768)
        let heic = try Thumbnails.makeHEIC(fromPNG: png, maxPixelSize: 512)

        let source = try #require(CGImageSourceCreateWithData(heic as CFData, nil))
        #expect(CGImageSourceGetType(source) as String? == "public.heic")
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(max(image.width, image.height) == 512)
    }

    @Test func pixelSizeReadsPNGHeader() throws {
        let png = try TestPNG.make(width: 320, height: 200)
        let size = try Thumbnails.pixelSize(ofPNG: png)
        #expect(size.width == 320)
        #expect(size.height == 200)
    }
}
