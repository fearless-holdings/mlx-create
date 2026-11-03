import Foundation
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

    /// Generation 1 saves one image; generation 2 refuses for lack of memory.
    private static let outOfMemoryThenSuccess2: FakeEngine.Script = { number, _ in
        if number == 2 {
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

    @Test func dismissingTheCardReturnsTheCanvasToTheKeptImage() async throws {
        let harness = try await AppHarness.make(script: Self.outOfMemoryThenSuccess2)
        let model = harness.model
        await model.start()
        await model.refreshModels()
        model.prompt = "a lighthouse at dusk"
        await model.generate()
        try await eventually { model.selectedImage != nil }
        let keptID = try #require(model.selectedImage?.id)

        model.prompt = "a lighthouse at noon"
        await model.generate()
        let failedID = try #require(model.selection)
        try await eventually { model.selectedFailedJob?.id == failedID }

        model.dismissFailureCard()
        #expect(model.selectedFailedJob == nil)
        #expect(model.canvasImage?.id == keptID)
    }

    @Test func dismissingTheCardWithNothingKeptShowsTheEmptyCanvas() async throws {
        let (harness, _) = try await failedHarness()
        let model = harness.model
        #expect(model.selectedFailedJob != nil)

        model.dismissFailureCard()
        #expect(model.selectedFailedJob == nil)
        #expect(model.canvasImage == nil)
    }

    @Test func dismissingTheCardAfterTheKeptImageWasDeletedShowsTheEmptyCanvas() async throws {
        let harness = try await AppHarness.make(script: Self.outOfMemoryThenSuccess2)
        let model = harness.model
        await model.start()
        await model.refreshModels()
        model.prompt = "a lighthouse at dusk"
        await model.generate()
        try await eventually { model.selectedImage != nil }
        let keptID = try #require(model.selectedImage?.id)

        model.prompt = "a lighthouse at noon"
        await model.generate()
        let failedID = try #require(model.selection)
        try await eventually { model.selectedFailedJob?.id == failedID }

        // The kept image left the gallery (deleted or moved) while the card was up.
        model.galleryImages.removeAll { $0.id == keptID }
        model.dismissFailureCard()
        #expect(model.selection == nil)
        #expect(model.canvasImage == nil)
    }

    // MARK: LoRA rejection

    /// The engine refuses every generation as a LoRA mismatch (HTTP 400 "no modules matching").
    private static let rejectsLoRAs: FakeEngine.Script = { _, _ in
        .init(
            status: 400,
            body: Data(#"{"error":{"message":"no modules matching","type":"invalid_request_error"}}"#.utf8),
            tail: nil)
    }

    /// Generation 1 saves one image; generation 2 is refused as a LoRA mismatch.
    private static let savesThenRejectsLoRAs: FakeEngine.Script = { number, _ in
        if number == 1 {
            return .init(status: 200, body: PNGFixture.sseReply(width: 512, height: 512), tail: nil)
        }
        return .init(
            status: 400,
            body: Data(#"{"error":{"message":"no modules matching","type":"invalid_request_error"}}"#.utf8),
            tail: nil)
    }

    /// Stacks each named LoRA, generates once and waits for the engine's refusal to reach the canvas.
    private func rejectedLoRAHarness(_ loraNames: [String]) async throws -> (harness: AppHarness, failed: JobItem) {
        let harness = try await AppHarness.make(script: Self.rejectsLoRAs)
        let model = harness.model
        await model.start()
        await model.refreshModels()
        for name in loraNames {
            let record = try await importLoRA(harness, .krea, name: name)
            model.addToLoRAStack(id: record.id)
        }
        model.prompt = "a lighthouse at dusk"
        await model.generate()
        let jobID = try #require(model.selection)
        try await eventually { model.selectedFailedJob?.id == jobID }
        return (harness, try #require(model.selectedFailedJob))
    }

    @Test func aRejectedLoRAIsListedOnTheFailedJob() async throws {
        let harness = try await AppHarness.make(script: Self.rejectsLoRAs)
        let model = harness.model
        await model.start()
        await model.refreshModels()
        let lora = try await importLoRA(harness, .krea, name: "Pixel Art")
        model.addToLoRAStack(id: lora.id)
        model.prompt = "a lighthouse at dusk"

        await model.generate()
        let jobID = try #require(model.selection)
        try await eventually { model.selectedFailedJob?.id == jobID }

        let failed = try #require(model.selectedFailedJob)
        #expect(failed.canRetry == false)
        #expect(failed.loraIDs == [lora.id])
        #expect(failed.loraNames == ["Pixel Art"])

        model.removeFromLoRAStack(id: lora.id)
        #expect(model.loraStack.isEmpty)
    }

    @Test func removeLoRAsFromStackTakesEveryLoRATheJobCarriedAndNamesThem() async throws {
        let harness = try await AppHarness.make(script: Self.savesThenRejectsLoRAs)
        let model = harness.model
        await model.start()
        await model.refreshModels()
        let pixel = try await importLoRA(harness, .krea, name: "Pixel Art")
        let ink = try await importLoRA(harness, .krea, name: "Ink Wash")
        model.addToLoRAStack(id: pixel.id)
        model.addToLoRAStack(id: ink.id)
        model.prompt = "a lighthouse at dusk"
        await model.generate()
        try await eventually { model.selectedImage != nil }
        let keptID = try #require(model.selectedImage?.id)

        model.prompt = "a lighthouse at noon"
        await model.generate()
        let failedID = try #require(model.selection)
        try await eventually { model.selectedFailedJob?.id == failedID }
        let failed = try #require(model.selectedFailedJob)
        #expect(model.offersRemoveRejectedLoRAs(for: failed))

        // The engine's refusal does not say which LoRA it rejected, so every one the job carried leaves the stack.
        model.removeRejectedLoRAs(from: failed)
        #expect(model.loraStack.isEmpty)
        #expect(model.loraNotice?.contains("\"Pixel Art\"") == true)
        #expect(model.loraNotice?.contains("\"Ink Wash\"") == true)
        #expect(model.canvasImage?.id == keptID)
    }

    @Test func aFailureThatCarriedNoLoRAsOffersNoStackRemoval() async throws {
        let (harness, failed) = try await rejectedLoRAHarness([])
        let model = harness.model
        #expect(failed.loraIDs.isEmpty)
        #expect(failed.canRetry == false)
        #expect(model.offersRemoveRejectedLoRAs(for: failed) == false)
    }

    @Test func aRetryableFailureOffersTryAgainAndNoStackRemoval() async throws {
        let harness = try await AppHarness.make(script: Self.outOfMemoryThenSuccess)
        let model = harness.model
        await model.start()
        await model.refreshModels()
        let lora = try await importLoRA(harness, .krea, name: "Pixel Art")
        model.addToLoRAStack(id: lora.id)
        model.prompt = "a lighthouse at dusk"

        await model.generate()
        let jobID = try #require(model.selection)
        try await eventually { model.selectedFailedJob?.id == jobID }

        let failed = try #require(model.selectedFailedJob)
        #expect(failed.canRetry)
        #expect(failed.loraIDs == [lora.id])
        #expect(model.offersRemoveRejectedLoRAs(for: failed) == false)
    }

    @Test func removingTheLoRAByHandTakesTheStackRemovalAway() async throws {
        let (harness, failed) = try await rejectedLoRAHarness(["Pixel Art"])
        let model = harness.model
        #expect(model.offersRemoveRejectedLoRAs(for: failed))

        guard let loraID = failed.loraIDs.first else {
            Issue.record("the failed job listed no LoRAs")
            return
        }
        model.removeFromLoRAStack(id: loraID)
        #expect(model.offersRemoveRejectedLoRAs(for: failed) == false)

        // Nothing is left to remove, so taking the action anyway says nothing rather than "Removed  from the stack."
        model.removeRejectedLoRAs(from: failed)
        #expect(model.loraNotice == nil)
    }
}
