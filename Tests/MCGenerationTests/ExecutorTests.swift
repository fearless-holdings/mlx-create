import Foundation
import MCEngine
import MCGeneration
@testable import MCLibrary
import Testing

private struct InjectedFailure: Error {}

/// Counts calls made from a `@Sendable` closure on any thread.
private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    /// Adds one and returns the new count.
    func next() -> Int {
        lock.withLock {
            value += 1
            return value
        }
    }
}

/// A flag a `@Sendable` closure can set on any thread.
private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var isSet: Bool { lock.withLock { value } }
    func set() { lock.withLock { value = true } }
}

@Suite struct ExecutorTests {
    @Test func pauseFinishesTheInFlightGenerationThenStartsNothing() async throws {
        let harness = try await Harness.make { _, _ in
            .init(status: 200, body: PNGFixture.sseReply(images: 1, width: 512, height: 512), tail: nil)
        }
        _ = try await harness.enqueue(batch: 3)
        await harness.queue.pause()
        try await harness.executor.drain()
        #expect(try harness.generationSeeds().count == 0)
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
        try await eventually { try harness.generationSeeds().count == 2 }
        try await harness.executor.cancel(job.id)
        EngineStubProtocol.finishHeld(harness.endpoint)
        try await run.value
        #expect(try await harness.store.jobs(status: .cancelled).count == 1)
        #expect(try await harness.store.savedImageCount(jobID: job.id) == 1)
    }

    @Test func cancelDuringAModelLoadEndsTheJobCancelledWithNoImage() async throws {
        let harness = try await Harness.make(loaded: [otherModel], holdLoads: true) { _, _ in
            .init(status: 200, body: PNGFixture.sseReply(images: 1, width: 512, height: 512), tail: nil)
        }
        let job = try await harness.enqueue(batch: 2)
        let run = Task { try await harness.executor.drain() }
        try await eventually { harness.requests(to: "v1/load-model").isEmpty == false }
        try await harness.executor.cancel(job.id)
        try await eventually(timeout: .seconds(5)) { try await harness.store.jobs(status: .cancelled).count == 1 }
        try await run.value
        #expect(try await harness.store.savedImageCount(jobID: job.id) == 0)
        #expect(harness.requests(to: "v1/images/generations").isEmpty)
    }

    @Test func cancelWhileWaitingForTheEngineEndsTheJobCancelled() async throws {
        let harness = try await Harness.make { _, _ in
            .init(status: 200, body: PNGFixture.sseReply(images: 1, width: 512, height: 512), tail: nil)
        }
        let endpoint = harness.endpoint
        let waiting = Flag()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [EngineStubProtocol.self]
        // The gate stays closed until the waiting task is cancelled, like an engine that never comes up.
        let client = EngineClient(endpoint: {
            waiting.set()
            try await Task.sleep(for: .seconds(60))
            return endpoint
        }, configuration: configuration)
        let executor = JobExecutor(store: harness.store, client: client, queue: harness.queue)
        let job = try await harness.enqueue(batch: 1)
        let run = Task { try await executor.drain() }
        try await eventually { waiting.isSet }
        try await executor.cancel(job.id)
        try await eventually(timeout: .seconds(5)) { try await harness.store.jobs(status: .cancelled).count == 1 }
        try await run.value
        #expect(try await harness.store.savedImageCount(jobID: job.id) == 0)
    }

    @Test func cancelOfAFinishedJobLeavesItDone() async throws {
        let harness = try await Harness.make { _, _ in
            .init(status: 200, body: PNGFixture.sseReply(images: 1, width: 512, height: 512), tail: nil)
        }
        let job = try await harness.enqueue(batch: 1)
        try await harness.executor.drain()
        try await harness.executor.cancel(job.id)
        #expect(try await harness.store.jobs(status: .done).map(\.id) == [job.id])
        #expect(try await harness.store.jobs(status: .cancelled).isEmpty)
    }

    @Test func aQueuedJobCancelledBeforeItsTurnIsNeverGenerated() async throws {
        let harness = try await Harness.make { _, _ in
            .init(status: 200, body: PNGFixture.sseReply(images: 1, width: 512, height: 512), tail: nil)
        }
        let first = try await harness.enqueue(batch: 1)
        let second = try await harness.enqueue(batch: 1)
        try await harness.executor.cancel(second.id)
        try await harness.executor.drain()
        #expect(try harness.generationSeeds().count == 1)
        #expect(try await harness.store.jobs(status: .done).map(\.id) == [first.id])
        #expect(try await harness.store.jobs(status: .cancelled).map(\.id) == [second.id])
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

    @Test func overlappingModelSwitchesNeverLeaveTwoModelsResident() async throws {
        let harness = try await Harness.make { _, _ in .json("{}") }
        async let first: Void = harness.executor.selectModel(kreaModel)
        async let second: Void = harness.executor.selectModel(otherModel)
        _ = try await (first, second)
        let calls = EngineStubProtocol.requests(harness.endpoint)
            .filter { $0.path.hasPrefix("v1/load") || $0.path.hasPrefix("v1/unload") }
        // Replaying the calls in order: each unload or load must leave at most one model resident.
        var resident: Set<String> = []
        for call in calls {
            let model = Self.model(in: call.body)
            if call.path == "v1/unload-model" {
                resident.remove(model)
            } else {
                resident.insert(model)
            }
            #expect(resident.count <= 1, "two models resident after \(call.path)")
        }
        #expect(resident.count == 1)
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

    @Test func storeFailureMidRunRecordsTheJobAsFailedInsteadOfLeavingItRunning() async throws {
        let harness = try await Harness.make { _, _ in
            .init(status: 200, body: PNGFixture.sseReply(images: 1, width: 512, height: 512), tail: nil)
        }
        _ = try await harness.enqueue(batch: 1)
        // The store refuses the final `done` write, after the image is already saved.
        await harness.store.setJobStatusHook { status in
            if status == .done { throw InjectedFailure() }
        }
        await #expect(throws: InjectedFailure.self) {
            try await harness.executor.drain()
        }
        #expect(try await harness.store.jobs(status: .running).isEmpty)
        let failed = try #require(try await harness.store.jobs(status: .failed).first)
        #expect(failed.failure != nil)
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

    @Test(arguments: [SeedPolicy.random, .fixed(7), .increment(base: 100)])
    func savedSeedsAreTheSeedsTheEngineRequested(policy: SeedPolicy) async throws {
        let harness = try await Harness.make { _, _ in
            .init(status: 200, body: PNGFixture.sseReply(images: 1, width: 512, height: 512), tail: nil)
        }
        _ = try await harness.enqueue(batch: 2, seedPolicy: policy)
        try await harness.executor.drain()
        let requested = try harness.generationSeeds()
        let saved = try await harness.store.recentImages(projectID: harness.projectID, limit: 10)
            .map { UInt32(truncatingIfNeeded: $0.settings.seed) }
        #expect(requested.count == 2)
        #expect(saved.sorted() == requested.sorted())
    }

    @Test func incrementSeedsContinueAtBasePlusSavedCount() async throws {
        let harness = try await Harness.make { _, _ in
            .init(status: 200, body: PNGFixture.sseReply(images: 1, width: 512, height: 512), tail: nil)
        }
        _ = try await harness.enqueue(batch: 2, seedPolicy: .increment(base: 100))
        try await harness.executor.drain()
        #expect(try harness.generationSeeds() == [100, 101])
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
            kind: .missingWeights, message: "The model files are missing.", detail: "MISSING WEIGHT", exit: nil
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

    @Test func connectionLossWaitsBrieflyForTheSupervisorsCrash() async throws {
        let harness = try await Harness.make { _, _ in
            .init(status: 200, body: PNGFixture.sseHead(), tail: Data())
        }
        let endpoint = harness.endpoint
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [EngineStubProtocol.self]
        let client = EngineClient(endpoint: { endpoint }, configuration: configuration)
        let crash = EngineCrash(
            kind: .killedBySystem, message: "macOS stopped the engine because memory ran low.",
            detail: "signal 9", exit: nil
        )
        // The supervisor publishes the crash only on the third look, as it would a moment after the connection drops.
        let looks = Counter()
        let executor = JobExecutor(
            store: harness.store, client: client, queue: harness.queue,
            crashKind: { looks.next() >= 3 ? crash : nil }
        )
        let job = try await harness.enqueue(batch: 1)
        let run = Task { try await executor.drain() }
        try await eventually { harness.requests(to: "v1/images/generations").isEmpty == false }
        EngineStubProtocol.finishHeld(endpoint)
        try await run.value
        let failed = try #require(try await harness.store.jobs(status: .failed).first)
        #expect(failed.id == job.id)
        #expect(failed.failure?.message == crash.message)
        #expect(failed.failure?.detail == crash.detail)
    }

    @Test func savedImagesRecordTheEngineVersionInSettingsAndPNG() async throws {
        let harness = try await Harness.make(engineVersion: "v1.2.3") { _, _ in
            .init(status: 200, body: PNGFixture.sseReply(images: 1, width: 512, height: 512), tail: nil)
        }
        _ = try await harness.enqueue(batch: 1)
        try await harness.executor.drain()
        let image = try #require(try await harness.store.recentImages(projectID: harness.projectID, limit: 1).first)
        #expect(image.settings.engineVersion == "v1.2.3")
        let onDisk = try Data(contentsOf: await harness.store.paths.url(relativePath: image.filePath))
        let embedded = try #require(try MetadataCodec.read(fromPNG: onDisk))
        #expect(embedded.engineVersion == "v1.2.3")
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
        let models = calls.map { Self.model(in: $0.body) }
        #expect(models == [otherModel, kreaModel])
    }

    @Test func startRunsTheQueueWithoutDrainAndASecondStartWhileRunningStartsNothing() async throws {
        let harness = try await Harness.make { _, _ in
            .init(status: 200, body: PNGFixture.sseHead(), tail: PNGFixture.sseTail(width: 512, height: 512))
        }
        let job = try await harness.enqueue(batch: 3)
        await harness.executor.start()
        await harness.executor.start()
        try await eventually { try harness.generationSeeds().count == 1 }
        try await Task.sleep(for: .milliseconds(100))
        #expect(try harness.generationSeeds().count == 1)
        for expected in 1...3 {
            try await eventually { try harness.generationSeeds().count == expected }
            EngineStubProtocol.finishHeld(harness.endpoint)
        }
        try await eventually { try await harness.store.jobs(status: .done).count == 1 }
        #expect(try await harness.store.savedImageCount(jobID: job.id) == 3)
        #expect(try harness.generationSeeds().count == 3)
    }

    @Test func startAfterPauseAndResumeRunsTheRemainder() async throws {
        let harness = try await Harness.make { _, _ in
            .init(status: 200, body: PNGFixture.sseHead(), tail: PNGFixture.sseTail(width: 512, height: 512))
        }
        let job = try await harness.enqueue(batch: 3)
        await harness.executor.start()
        try await eventually { try harness.generationSeeds().count == 1 }
        await harness.queue.pause()
        EngineStubProtocol.finishHeld(harness.endpoint)
        try await eventually { try await harness.store.jobs(status: .paused).count == 1 }
        try await harness.queue.resume()
        await harness.executor.start()
        for expected in 2...3 {
            try await eventually { try harness.generationSeeds().count == expected }
            EngineStubProtocol.finishHeld(harness.endpoint)
        }
        try await eventually { try await harness.store.jobs(status: .done).count == 1 }
        #expect(try await harness.store.savedImageCount(jobID: job.id) == 3)
        #expect(try harness.generationSeeds().count == 3)
    }

    /// The `model` field of a load or unload request body.
    private static func model(in body: String) -> String {
        let object = try? JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any]
        return object?["model"] as? String ?? ""
    }
}
