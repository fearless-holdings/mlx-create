import AppKit
import Foundation
import SwiftUI
import Testing

@testable import MCApp

/// I03: a failure lands where the user is looking, and the card's Try Again recovers from it.
@MainActor
@Suite struct FailureCardTests {
    /// Generation 1 refuses for lack of memory; every later generation answers one 512×512 PNG.
    private static let outOfMemoryThenSuccess: FakeEngine.Script = { number, _ in
        if number == 1 {
            return .init(
                status: 503, body: Data(#"{"error":{"type":"out_of_memory","message":"insufficient memory"}}"#.utf8),
                tail: nil)
        }
        return .init(status: 200, body: PNGFixture.sseReply(width: 512, height: 512), tail: nil)
    }

    /// The app after one Generate whose only job failed for lack of memory.
    private func failedHarness() async throws -> (harness: AppHarness, jobID: UUID) {
        let harness = try await AppHarness.make(script: Self.outOfMemoryThenSuccess)
        let model = harness.model
        await model.start()
        await model.refreshModels()
        model.prompt = "a lighthouse at dusk"

        await model.generate()
        let jobID = try #require(model.selection)
        try await eventually { model.selectedFailedJob?.id == jobID }
        return (harness, jobID)
    }

    @Test func anOutOfMemoryFailureTakesTheCanvasAndCanBeRetried() async throws {
        let (harness, jobID) = try await failedHarness()
        let model = harness.model

        let failed = try #require(model.selectedFailedJob)
        #expect(failed.id == jobID)
        #expect(failed.status == .failed)
        #expect(failed.canRetry)
        #expect(failed.failure?.message.isEmpty == false)

        await model.retry(jobID)
        try await eventually { model.selectedImage != nil }
    }

    @Test func retryingAFailedJobFollowsItAgain() async throws {
        let (harness, jobID) = try await failedHarness()
        let model = harness.model

        // The failure took the canvas and handed it back to the user, so the retried job has to be followed again.
        #expect(!model.canvasFollowedJobs.contains(jobID))

        await model.retry(jobID)
        #expect(model.canvasFollowedJobs.contains(jobID))

        try await eventually { model.selectedImage != nil }
        #expect(model.selection != jobID)
    }

    @Test func renderTheCardForReview() async throws {
        let (harness, _) = try await failedHarness()
        let model = harness.model
        let job = try #require(model.selectedFailedJob)

        for scheme in [ColorScheme.light, .dark] {
            let renderer = ImageRenderer(
                content: FailureCard(model: model, job: job)
                    .frame(width: 460)
                    .background(scheme == .dark ? Color.black : Color.white)
                    .environment(\.colorScheme, scheme))
            renderer.scale = 2
            let image = try #require(renderer.nsImage)
            let tiff = try #require(image.tiffRepresentation)
            let rep = try #require(NSBitmapImageRep(data: tiff))
            let png = try #require(rep.representation(using: .png, properties: [:]))
            try png.write(to: URL(fileURLWithPath: "/tmp/I03_card_\(scheme == .dark ? "dark" : "light").png"))
        }
    }
}
