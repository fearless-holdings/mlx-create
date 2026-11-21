import Foundation
import Testing

@testable import MCApp

@MainActor
@Suite struct WindowModeTests {
    @Test func nothingStoredMeansChatAndAChosenModeSurvivesARelaunch() async throws {
        let harness = try await AppHarness.make()
        // R1: Chat is the mode on first launch and whenever no mode is stored.
        #expect(harness.model.windowMode == .chat)

        harness.model.windowMode = .gallery
        let relaunched = try await harness.relaunch()
        #expect(relaunched.model.windowMode == .gallery)

        relaunched.model.windowMode = .canvas
        let again = try await relaunched.relaunch()
        #expect(again.model.windowMode == .canvas)
    }

    @Test func aStoredLegacyBooleanMapsToGalleryOrCanvas() async throws {
        // KTD9: builds that stored `showsGalleryOnly` left a Bool under the same key; true was Gallery.
        let galleryDefaults = UserDefaults(suiteName: UUID().uuidString)!
        galleryDefaults.set(true, forKey: AppModel.windowModeDefaultsKey)
        let gallery = try await AppHarness.make(defaults: galleryDefaults)
        #expect(gallery.model.windowMode == .gallery)

        let canvasDefaults = UserDefaults(suiteName: UUID().uuidString)!
        canvasDefaults.set(false, forKey: AppModel.windowModeDefaultsKey)
        let canvas = try await AppHarness.make(defaults: canvasDefaults)
        #expect(canvas.model.windowMode == .canvas)
    }

    @Test func openingAnImageSelectsItAndLeavesForCanvas() async throws {
        let harness = try await AppHarness.make()
        let model = harness.model
        let image = try await harness.saveImage(prompt: "a lighthouse at dusk")

        model.windowMode = .gallery
        model.openInCanvas(image.id)

        #expect(model.windowMode == .canvas)
        #expect(model.selection == image.id)
    }
}
