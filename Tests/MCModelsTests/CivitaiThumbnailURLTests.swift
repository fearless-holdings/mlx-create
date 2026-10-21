import Foundation
import Testing

@testable import MCModels

@Suite struct CivitaiThumbnailURLTests {
    private let cdn = "https://image.civitai.com/key/uuid"

    @Test func originalImageAndVideoURLsBecomeSmallStills() {
        let image = URL(string: "\(cdn)/original=true/1.jpeg")!
        let video = URL(string: "\(cdn)/original=true/2.mp4")!
        #expect(CivitaiImage.thumbnailURL(image, width: 128).absoluteString == "\(cdn)/anim=false,width=128/1.jpeg")
        #expect(CivitaiImage.thumbnailURL(video, width: 128).absoluteString == "\(cdn)/anim=false,width=128/2.mp4")
    }

    @Test func rewritingTwiceKeepsTheLastWidth() {
        let url = URL(string: "\(cdn)/original=true/1.jpeg")!
        let twice = CivitaiImage.thumbnailURL(CivitaiImage.thumbnailURL(url, width: 256), width: 128)
        #expect(twice.absoluteString == "\(cdn)/anim=false,width=128/1.jpeg")
    }

    @Test func otherHostsAndUntransformedPathsAreLeftAlone() {
        let other = URL(string: "https://example.com/key/uuid/original=true/1.jpeg")!
        let plain = URL(string: "https://image.civitai.com/1.jpeg")!
        #expect(CivitaiImage.thumbnailURL(other, width: 128) == other)
        #expect(CivitaiImage.thumbnailURL(plain, width: 128) == plain)
    }
}
