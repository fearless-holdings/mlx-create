import Foundation
import Testing

@testable import MCApp

@MainActor
@Suite struct WindowModeTests {
    @Test func theCanvasIsTheDefaultAndGalleryModeSurvivesARelaunch() async throws {
        let harness = try await AppHarness.make()
        #expect(!harness.model.showsGalleryOnly)

        harness.model.showsGalleryOnly = true
        let relaunched = try await harness.relaunch()
        #expect(relaunched.model.showsGalleryOnly)

        relaunched.model.showsGalleryOnly = false
        let again = try await relaunched.relaunch()
        #expect(!again.model.showsGalleryOnly)
    }

    @Test func openingAnImageSelectsItAndLeavesGalleryMode() async throws {
        let harness = try await AppHarness.make()
        let model = harness.model
        let image = try await harness.saveImage(prompt: "a lighthouse at dusk")

        model.showsGalleryOnly = true
        model.openInCanvas(image.id)

        #expect(!model.showsGalleryOnly)
        #expect(model.selection == image.id)
    }
}
