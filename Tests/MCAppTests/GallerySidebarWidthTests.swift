import Testing

@testable import MCApp

struct GallerySidebarWidthTests {
    @Test func galleryFirstLaunchUsesComposerDefault() {
        var width = GallerySidebarWidth()
        width.record(1100, galleryOnly: true)
        #expect(width.composerWidth == 260)
    }

    @Test func fullWindowResizesDoNotReplaceComposerWidth() {
        var width = GallerySidebarWidth()
        width.record(354, galleryOnly: false)
        for fullWidth in [1100.0, 1250, 1100] {
            width.record(fullWidth, galleryOnly: true)
            #expect(width.composerWidth == 354)
        }
        width.record(300, galleryOnly: false)
        #expect(width.composerWidth == 300)
    }

    @Test func invalidMeasurementsKeepLastWidth() {
        var width = GallerySidebarWidth()
        for invalid in [0.0, -1, 199, .nan, .infinity] {
            width.record(invalid, galleryOnly: false)
            #expect(width.composerWidth == 260)
        }
        width.record(200, galleryOnly: false)
        #expect(width.composerWidth == 200)
    }
}
