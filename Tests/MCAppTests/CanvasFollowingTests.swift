import Foundation
import Testing

@testable import MCApp

/// I02 edge cases found in review: when the canvas stops following a run, and what it shows after the user empties it.
@MainActor
@Suite struct CanvasFollowingTests {
    /// Generation 1 answers an image at once; every later generation waits for `EngineStubProtocol.finishHeld`.
    private static func heldAfterTheFirstImage() async throws -> AppHarness {
        try await AppHarness.make(script: { number, _ in
            if number == 1 {
                return .init(status: 200, body: PNGFixture.sseReply(width: 512, height: 512), tail: nil)
            }
            return .init(status: 200, body: PNGFixture.sseHead(steps: 2), tail: PNGFixture.sseTail(width: 512, height: 512))
        })
    }

    @Test func aCommandClickBeforeTheFirstImageKeepsTheCanvasOnTheImageItShows() async throws {
        let harness = try await Self.heldAfterTheFirstImage()
        let model = harness.model
        await model.start()
        await model.refreshModels()
        let older = try await harness.saveImage(prompt: "an older image")
        await model.reload()

        model.prompt = "a lighthouse at dusk"
        await model.generate()
        try await eventually { model.selectedImage != nil }
        let shownID = try #require(model.selectedImage?.id)

        // The second job is selected as a placeholder, and the canvas keeps the first image while it runs.
        model.prompt = "a lighthouse at noon"
        await model.generate()
        try await harness.engineHasReceived("v1/images/generations", count: 2)
        #expect(model.canvasImage?.id == shownID)

        model.selectGalleryImage(older.id, click: .toggle)
        #expect(model.canvasImage?.id == shownID)

        EngineStubProtocol.finishHeld(harness.endpoint)
        try await eventually { imageCount(model) == 3 }
        #expect(model.canvasImage?.id == shownID)
    }

    @Test func movingTheShownImageAwayLeavesAnEmptyCanvasNotTheKeptOne() async throws {
        let harness = try await AppHarness.make()
        let model = harness.model
        await model.start()
        let target = try await harness.store.createCollection(name: "Keepers")
        let kept = try await harness.saveImage(prompt: "kept before the last Generate")
        let shown = try await harness.saveImage(prompt: "shown now")
        await model.reload()
        model.canvasFallbackImageID = kept.id
        model.selectGalleryImage(shown.id, click: .plain)

        await model.moveImages(ids: [shown.id], to: target.id)

        #expect(model.selection == nil)
        #expect(model.canvasImage == nil)
    }

    @Test func aRetryMakesAnInFlightQueueReadReadAgain() async throws {
        // Generation 1 fails for lack of memory; the retry waits on the engine, so nothing else bumps the revision.
        let harness = try await AppHarness.make(script: { number, _ in
            if number == 1 {
                return .init(
                    status: 503, body: Data(#"{"error":{"type":"out_of_memory","message":"insufficient memory"}}"#.utf8),
                    tail: nil)
            }
            return .init(status: 200, body: PNGFixture.sseHead(steps: 2), tail: PNGFixture.sseTail(width: 512, height: 512))
        })
        let model = harness.model
        await model.start()
        await model.refreshModels()
        model.prompt = "a lighthouse at dusk"
        await model.generate()
        let jobID = try #require(model.selection)
        try await eventually { model.selectedFailedJob?.id == jobID }

        let before = model.galleryRevision
        await model.retry(jobID)

        #expect(model.galleryRevision > before)
        #expect(model.canvasFollowedJobs.contains(jobID))
        EngineStubProtocol.finishHeld(harness.endpoint)
    }
}
