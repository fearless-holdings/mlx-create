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
        let harness = try await AppHarness.make(script: { _, _ in
            .init(status: 200, body: PNGFixture.sseHead(steps: 2), tail: PNGFixture.sseTail(width: 512, height: 512))
        })
        let model = harness.model
        await model.start()
        await model.refreshModels()
        model.prompt = "a lighthouse at dusk"
        await model.generate()
        let jobID = try #require(model.selection)
        try await eventually { model.runningProgress == RunningProgress(jobID: jobID, step: 2, total: 2) }
        EngineStubProtocol.finishHeld(harness.endpoint)
        try await eventually { model.selectedImage != nil }
        let image = try #require(model.selectedImage)

        model.showsGalleryOnly = true
        model.selection = nil
        model.openInCanvas(image.id)

        #expect(!model.showsGalleryOnly)
        #expect(model.selection == image.id)
        #expect(harness.defaults.string(forKey: AppModel.windowModeDefaultsKey) == "canvas")
    }
}
