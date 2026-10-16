import Foundation
import MCEngine
import MCGeneration
import MCLibrary
import Testing

@Suite struct ExecutorTests {
    @Test func pauseFinishesTheInFlightGenerationThenStartsNothing() async throws {
        let harness = try await Harness.make { _, _ in
            .init(status: 200, body: PNGFixture.sseReply(images: 1, width: 512, height: 512), tail: nil)
        }
        _ = try await harness.enqueue(batch: 3)
        await harness.queue.pause()
        try await harness.executor.drain()
        #expect(harness.generationSeeds().count == 0)
        #expect(try await harness.store.jobs(status: .queued).count == 1)
    }

    @Test func cancelAtGenerationTwoOfFourKeepsImageOneAndSavesNoPartial() async throws {
        let harness = try await Harness.make { number, _ in
            if number == 2 {
                return .init(status: 200, body: PNGFixture.sseHead(), tail: PNGFixture.sseTail(width: 512, height: 512))
            }
            return .init(status: 200, body: PNGFixture.sseReply(images: 1, width: 512, height: 512), tail: nil)
        }
        let job = try await harness.enqueue(batch: 4)
        let run = Task { try await harness.executor.drain() }
        try await eventually { harness.generationSeeds().count == 2 }
        try await harness.executor.cancel(job.id)
        EngineStubProtocol.finishHeld(harness.endpoint)
        try await run.value
        #expect(try await harness.store.jobs(status: .cancelled).count == 1)
        #expect(try await harness.store.savedImageCount(jobID: job.id) == 1)
    }

    @Test func outOfMemoryUnloadsResidentModelsAndRetryResumesTheRemainder() async throws {
        let harness = try await Harness.make(loaded: [otherModel]) { number, _ in
            if number == 1 {
                return .init(status: 503, body: PNGFixture.oomBody(), tail: nil)
            }
            return .init(status: 200, body: PNGFixture.sseReply(images: 1, width: 512, height: 512), tail: nil)
        }
        let job = try await harness.enqueue(batch: 2)
        try await harness.executor.drain()
        let failed = try await harness.store.jobs(status: .failed)
        #expect(failed.count == 1)
        #expect(failed.first?.failure?.retryable == true)
        #expect(harness.requests(to: "v1/unload-model").isEmpty == false)

        try await harness.queue.retry(job.id)
        try await harness.executor.drain()
        #expect(try await harness.store.savedImageCount(jobID: job.id) == 2)
    }

    @Test func modelSwitchUnloadsTheOldModelBeforeLoadingTheNew() async throws {
        let harness = try await Harness.make(loaded: [otherModel]) { _, _ in
            .init(status: 200, body: PNGFixture.sseReply(images: 1, width: 512, height: 512), tail: nil)
        }
        _ = try await harness.enqueue(model: kreaModel, batch: 1)
        try await harness.executor.drain()
        let order = EngineStubProtocol.requests(harness.endpoint)
            .filter { $0.path.hasPrefix("v1/load") || $0.path.hasPrefix("v1/unload") }
            .map(\.path)
        #expect(order == ["v1/unload-model", "v1/load-model"])
    }

    @Test func streamEndingWithoutCompleteFailsAndSavesNothing() async throws {
        let harness = try await Harness.make { _, _ in
            .init(status: 200, body: PNGFixture.sseHead(), tail: Data())
        }
        let job = try await harness.enqueue(batch: 1)
        let run = Task { try await harness.executor.drain() }
        try await eventually { harness.requests(to: "v1/images/generations").isEmpty == false }
        EngineStubProtocol.finishHeld(harness.endpoint)
        try await run.value
        #expect(try await harness.store.jobs(status: .failed).count == 1)
        #expect(try await harness.store.savedImageCount(jobID: job.id) == 0)
    }

    @Test func savedRowRecordsThePNGsRealSizeAndLastProgressTotal() async throws {
        let harness = try await Harness.make { _, _ in
            .init(status: 200, body: PNGFixture.sseReply(images: 1, width: 640, height: 384, steps: 6), tail: nil)
        }
        let job = try await harness.enqueue(batch: 1, width: 512, height: 512, steps: 4)
        try await harness.executor.drain()
        let image = try #require(try await harness.store.recentImages(projectID: harness.projectID, limit: 1).first)
        #expect(image.width == 640)
        #expect(image.height == 384)
        #expect(image.settings.steps == 6)
        #expect(try await harness.store.savedImageCount(jobID: job.id) == 1)
    }

    @Test func incrementSeedsContinueAtBasePlusSavedCount() async throws {
        let harness = try await Harness.make { _, _ in
            .init(status: 200, body: PNGFixture.sseReply(images: 1, width: 512, height: 512), tail: nil)
        }
        _ = try await harness.enqueue(batch: 2, seedPolicy: .increment(base: 100))
        try await harness.executor.drain()
        #expect(harness.generationSeeds() == [100, 101])
    }

    @Test func crashKindOverridesTheDroppedStreamErrorForTheJobFailure() async throws {
        let harness = try await Harness.make { _, _ in
            .init(status: 200, body: PNGFixture.sseHead(), tail: Data())
        }
        let endpoint = harness.endpoint
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [EngineStubProtocol.self]
        let client = EngineClient(endpoint: { endpoint }, configuration: configuration)
        let crash = EngineCrash(
            kind: .missingWeights, message: "The model files are missing.", detail: "MISSING WEIGHT",
            exit: nil, failedJob: nil
        )
        let executor = JobExecutor(store: harness.store, client: client, queue: harness.queue, crashKind: { crash })
        let job = try await harness.enqueue(batch: 1)
        let run = Task { try await executor.drain() }
        try await eventually { harness.requests(to: "v1/images/generations").isEmpty == false }
        EngineStubProtocol.finishHeld(endpoint)
        try await run.value
        let failed = try #require(try await harness.store.jobs(status: .failed).first)
        #expect(failed.id == job.id)
        #expect(failed.failure == JobFailure(message: crash.message, detail: crash.detail, retryable: false))
    }

    @Test func selectModelUnloadsThePreviousModelBeforeLoadingAndIsANoopWhenResident() async throws {
        let harness = try await Harness.make(loaded: [otherModel]) { _, _ in
            .init(status: 200, body: PNGFixture.sseReply(images: 1, width: 512, height: 512), tail: nil)
        }
        try await harness.executor.selectModel(kreaModel)
        try await harness.executor.selectModel(kreaModel)
        let calls = EngineStubProtocol.requests(harness.endpoint)
            .filter { $0.path.hasPrefix("v1/load") || $0.path.hasPrefix("v1/unload") }
        #expect(calls.map(\.path) == ["v1/unload-model", "v1/load-model"])
        let models = calls.map { call in
            (try? JSONSerialization.jsonObject(with: Data(call.body.utf8)) as? [String: Any])?["model"] as? String
        }
        #expect(models == [otherModel, kreaModel])
    }

    @Test func startRunsTheQueueWithoutDrainAndASecondStartWhileRunningStartsNothing() async throws {
        let harness = try await Harness.make { _, _ in
            .init(status: 200, body: PNGFixture.sseHead(), tail: PNGFixture.sseTail(width: 512, height: 512))
        }
        let job = try await harness.enqueue(batch: 3)
        await harness.executor.start()
        await harness.executor.start()
        try await eventually { harness.generationSeeds().count == 1 }
        try await Task.sleep(for: .milliseconds(100))
        #expect(harness.generationSeeds().count == 1)
        for expected in 1...3 {
            try await eventually { harness.generationSeeds().count == expected }
            EngineStubProtocol.finishHeld(harness.endpoint)
        }
        try await eventually { try await harness.store.jobs(status: .done).count == 1 }
        #expect(try await harness.store.savedImageCount(jobID: job.id) == 3)
        #expect(harness.generationSeeds().count == 3)
    }

    @Test func startAfterPauseAndResumeRunsTheRemainder() async throws {
        let harness = try await Harness.make { _, _ in
            .init(status: 200, body: PNGFixture.sseHead(), tail: PNGFixture.sseTail(width: 512, height: 512))
        }
        let job = try await harness.enqueue(batch: 3)
        await harness.executor.start()
        try await eventually { harness.generationSeeds().count == 1 }
        await harness.queue.pause()
        EngineStubProtocol.finishHeld(harness.endpoint)
        try await eventually { try await harness.store.jobs(status: .paused).count == 1 }
        try await harness.queue.resume()
        await harness.executor.start()
        for expected in 2...3 {
            try await eventually { harness.generationSeeds().count == expected }
            EngineStubProtocol.finishHeld(harness.endpoint)
        }
        try await eventually { try await harness.store.jobs(status: .done).count == 1 }
        #expect(try await harness.store.savedImageCount(jobID: job.id) == 3)
        #expect(harness.generationSeeds().count == 3)
    }
}
