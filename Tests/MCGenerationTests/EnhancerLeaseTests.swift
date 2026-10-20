import Foundation
import MCEngine
import MCGeneration
@testable import MCLibrary
import Testing

/// Below 24 GiB: memory tier 1, one model resident.
private let belowTwentyFourGiB = MemoryTier(physicalMemoryBytes: 16 << 30)
/// At or above 24 GiB and below 48 GiB: memory tier 2, two models resident.
private let twentyFourGiBOrMore = MemoryTier(physicalMemoryBytes: 36 << 30)

/// Holds an Enhance body open until the test releases it.
private actor Gate {
    private var released = false
    private var waiter: CheckedContinuation<Void, Never>?

    func wait() async {
        if released { return }
        await withCheckedContinuation { waiter = $0 }
    }

    func release() {
        released = true
        waiter?.resume()
        waiter = nil
    }
}

/// Answers the first generation with a held stream, so a test decides when that job's image finishes.
private func heldFirstImage(_ number: Int, _: EngineStubProtocol.Recorded) -> EngineStubProtocol.Reply {
    if number == 1 {
        return .init(status: 200, body: PNGFixture.sseHead(), tail: PNGFixture.sseTail(width: 512, height: 512))
    }
    return .init(status: 200, body: PNGFixture.sseReply(images: 1, width: 512, height: 512), tail: nil)
}

/// Answers every generation at once, so a job that runs after a lease finishes without the test having to release it.
private let immediateImage: @Sendable (Int, EngineStubProtocol.Recorded) -> EngineStubProtocol.Reply = { _, _ in
    .init(status: 200, body: PNGFixture.sseReply(images: 1, width: 512, height: 512), tail: nil)
}

private let noGeneration: @Sendable (Int, EngineStubProtocol.Recorded) -> EngineStubProtocol.Reply = { _, _ in
    .init(status: 404, body: Data(), tail: nil)
}

@Suite struct EnhancerLeaseTests {
    @Test func aQueuedJobDoesNotStartWhileTheLeaseIsHeld() async throws {
        let harness = try await Harness.make(
            loaded: [kreaModel], known: [kreaModel, otherModel, enhancerModel], memoryTier: belowTwentyFourGiB
        ) { _, _ in
            .init(status: 200, body: PNGFixture.sseReply(images: 1, width: 512, height: 512), tail: nil)
        }
        let gate = Gate()
        let lease = Task {
            try await harness.executor.withEnhancerLease(enhancerModelID: enhancerModel) { () async throws -> String in
                await gate.wait()
                return "enhanced"
            }
        }
        try await eventually { harness.engineCalls().contains("load \(enhancerModel)") }
        _ = try await harness.enqueue(batch: 1, seedPolicy: .increment(base: 100))
        let run = Task { try await harness.executor.drain() }
        try await Task.sleep(for: .milliseconds(100))
        #expect(try harness.generationSeeds().isEmpty)
        await gate.release()
        #expect(try await lease.value == "enhanced")
        try await run.value
        #expect(try harness.generationSeeds() == [100])
    }

    @Test func theLeaseWaitsForTheRunningImageThenProceeds() async throws {
        let harness = try await Harness.make(
            loaded: [kreaModel], known: [kreaModel, otherModel, enhancerModel], memoryTier: belowTwentyFourGiB,
            script: heldFirstImage)
        _ = try await harness.enqueue(batch: 1, seedPolicy: .increment(base: 100))
        let run = Task { try await harness.executor.drain() }
        try await eventually { try harness.generationSeeds() == [100] }
        let lease = Task {
            try await harness.executor.withEnhancerLease(enhancerModelID: enhancerModel) { () async throws -> String in
                "enhanced"
            }
        }
        try await Task.sleep(for: .milliseconds(100))
        #expect(!harness.engineCalls().contains("load \(enhancerModel)"))
        EngineStubProtocol.finishHeld(harness.endpoint)
        #expect(try await lease.value == "enhanced")
        try await run.value
        #expect(harness.engineCalls() == [
            "generate 100", "unload \(kreaModel)", "load \(enhancerModel)", "unload \(enhancerModel)",
            "load \(kreaModel)",
        ])
    }

    @Test func belowTwentyFourGiBTheImageModelSwapsOutAroundTheEnhancer() async throws {
        let harness = try await Harness.make(
            loaded: [kreaModel], known: [kreaModel, otherModel, enhancerModel], memoryTier: belowTwentyFourGiB,
            script: noGeneration)
        let text = try await harness.executor.withEnhancerLease(enhancerModelID: enhancerModel) { () async throws -> String in
            "enhanced"
        }
        #expect(text == "enhanced")
        #expect(harness.engineCalls() == [
            "unload \(kreaModel)", "load \(enhancerModel)", "unload \(enhancerModel)", "load \(kreaModel)",
        ])
    }

    @Test func atTwentyFourGiBOrMoreTheImageModelStaysResident() async throws {
        let harness = try await Harness.make(
            loaded: [kreaModel], known: [kreaModel, otherModel, enhancerModel], memoryTier: twentyFourGiBOrMore,
            script: noGeneration)
        let text = try await harness.executor.withEnhancerLease(enhancerModelID: enhancerModel) { () async throws -> String in
            "enhanced"
        }
        #expect(text == "enhanced")
        #expect(harness.engineCalls() == ["load \(enhancerModel)"])
    }

    @Test func cancellingTheBodyUnloadsTheEnhancerAndRewarmsTheImageModel() async throws {
        let harness = try await Harness.make(
            loaded: [kreaModel], known: [kreaModel, otherModel, enhancerModel], memoryTier: belowTwentyFourGiB,
            script: noGeneration)
        let lease = Task {
            try await harness.executor.withEnhancerLease(enhancerModelID: enhancerModel) { () async throws -> String in
                try await Task.sleep(for: .seconds(60))
                return "unreached"
            }
        }
        try await eventually { harness.engineCalls().contains("load \(enhancerModel)") }
        lease.cancel()
        await #expect(throws: CancellationError.self) { try await lease.value }
        #expect(harness.engineCalls() == [
            "unload \(kreaModel)", "load \(enhancerModel)", "unload \(enhancerModel)", "load \(kreaModel)",
        ])
    }

    @Test func outOfMemoryOnEnhancerLoadReleasesTheLeaseAndRestoresTheImageModel() async throws {
        let harness = try await Harness.make(
            loaded: [kreaModel], known: [kreaModel, otherModel, enhancerModel], refusedLoads: [enhancerModel],
            memoryTier: belowTwentyFourGiB, script: immediateImage)
        var thrown: Error?
        do {
            _ = try await harness.executor.withEnhancerLease(enhancerModelID: enhancerModel) { () async throws -> String in
                "unreached"
            }
        } catch {
            thrown = error
        }
        let error = try #require(thrown as? EngineError)
        switch error {
        case .enhancerOutOfMemory: break
        default: Issue.record("expected enhancerOutOfMemory, got \(error)")
        }
        #expect(harness.engineCalls() == ["unload \(kreaModel)", "load \(enhancerModel)", "load \(kreaModel)"])

        // The lease is released: a queued job now runs.
        _ = try await harness.enqueue(batch: 1, seedPolicy: .increment(base: 100))
        try await harness.executor.drain()
        #expect(try harness.generationSeeds() == [100])
    }

    @Test func aModelSwitchRequestedDuringTheLeaseIsAppliedAfterRelease() async throws {
        let harness = try await Harness.make(
            loaded: [kreaModel], known: [kreaModel, otherModel, enhancerModel], memoryTier: belowTwentyFourGiB,
            script: noGeneration)
        let gate = Gate()
        let lease = Task {
            try await harness.executor.withEnhancerLease(enhancerModelID: enhancerModel) { () async throws -> String in
                await gate.wait()
                return "enhanced"
            }
        }
        try await eventually { harness.engineCalls().contains("load \(enhancerModel)") }
        let switching = Task { try await harness.executor.selectModel(otherModel) }
        try await Task.sleep(for: .milliseconds(100))
        #expect(harness.engineCalls() == ["unload \(kreaModel)", "load \(enhancerModel)"])
        await gate.release()
        #expect(try await lease.value == "enhanced")
        try await switching.value
        // The image model is not re-warmed first, because the switch the user asked for is already waiting.
        #expect(harness.engineCalls() == [
            "unload \(kreaModel)", "load \(enhancerModel)", "unload \(enhancerModel)", "load \(otherModel)",
        ])
    }

    @Test func aLeaseRunsAheadOfTheQueuedJobsWhichKeepTheirOrder() async throws {
        let harness = try await Harness.make(
            loaded: [kreaModel], known: [kreaModel, otherModel, enhancerModel], memoryTier: belowTwentyFourGiB,
            script: heldFirstImage)
        _ = try await harness.enqueue(batch: 1, seedPolicy: .increment(base: 100))
        _ = try await harness.enqueue(batch: 1, seedPolicy: .increment(base: 200))
        _ = try await harness.enqueue(batch: 1, seedPolicy: .increment(base: 300))
        let run = Task { try await harness.executor.drain() }
        try await eventually { try harness.generationSeeds() == [100] }
        let lease = Task {
            try await harness.executor.withEnhancerLease(enhancerModelID: enhancerModel) { () async throws -> String in
                "enhanced"
            }
        }
        try await Task.sleep(for: .milliseconds(100))
        #expect(!harness.engineCalls().contains("load \(enhancerModel)"))
        EngineStubProtocol.finishHeld(harness.endpoint)
        #expect(try await lease.value == "enhanced")
        try await run.value
        #expect(harness.engineCalls() == [
            "generate 100", "unload \(kreaModel)", "load \(enhancerModel)", "unload \(enhancerModel)",
            "load \(kreaModel)", "generate 200", "generate 300",
        ])
    }

    @Test func aRunningJobWithQueuedJobsOnAnotherModelIsNotRewarmedAndTheQueuedJobLoadsItsModelOnce() async throws {
        let harness = try await Harness.make(
            loaded: [kreaModel], known: [kreaModel, otherModel, enhancerModel], memoryTier: belowTwentyFourGiB,
            script: heldFirstImage)
        _ = try await harness.enqueue(model: kreaModel, batch: 1, seedPolicy: .increment(base: 100))
        _ = try await harness.enqueue(model: otherModel, batch: 1, seedPolicy: .increment(base: 200))
        _ = try await harness.enqueue(model: otherModel, batch: 1, seedPolicy: .increment(base: 300))
        let run = Task { try await harness.executor.drain() }
        try await eventually { try harness.generationSeeds() == [100] }
        let lease = Task {
            try await harness.executor.withEnhancerLease(enhancerModelID: enhancerModel) { () async throws -> String in
                "enhanced"
            }
        }
        try await Task.sleep(for: .milliseconds(100))
        EngineStubProtocol.finishHeld(harness.endpoint)
        #expect(try await lease.value == "enhanced")
        try await run.value
        #expect(harness.engineCalls() == [
            "generate 100", "unload \(kreaModel)", "load \(enhancerModel)", "unload \(enhancerModel)",
            "load \(otherModel)", "generate 200", "generate 300",
        ])
    }

    @Test func aPausedQueueDoesNotBlockTheLeaseAndStaysPaused() async throws {
        let harness = try await Harness.make(
            loaded: [kreaModel], known: [kreaModel, otherModel, enhancerModel], memoryTier: belowTwentyFourGiB,
            script: heldFirstImage)
        _ = try await harness.enqueue(batch: 1, seedPolicy: .increment(base: 100))
        await harness.queue.pause()
        let text = try await harness.executor.withEnhancerLease(enhancerModelID: enhancerModel) { () async throws -> String in
            "enhanced"
        }
        #expect(text == "enhanced")
        let paused = await harness.queue.isPauseRequested
        #expect(paused)
        #expect(try await harness.store.jobs(status: .queued).count == 1)
        #expect(try harness.generationSeeds().isEmpty)
        #expect(harness.engineCalls() == ["unload \(kreaModel)", "load \(enhancerModel)", "unload \(enhancerModel)"])
    }

    @Test func cancellingTheRunningJobEndsTheWaitWithoutStartingTheNextJob() async throws {
        let harness = try await Harness.make(
            loaded: [kreaModel], known: [kreaModel, otherModel, enhancerModel], memoryTier: belowTwentyFourGiB,
            script: heldFirstImage)
        let running = try await harness.enqueue(batch: 1, seedPolicy: .increment(base: 100))
        _ = try await harness.enqueue(batch: 1, seedPolicy: .increment(base: 200))
        let run = Task { try await harness.executor.drain() }
        try await eventually { try harness.generationSeeds() == [100] }
        let lease = Task {
            try await harness.executor.withEnhancerLease(enhancerModelID: enhancerModel) { () async throws -> String in
                "enhanced"
            }
        }
        try await Task.sleep(for: .milliseconds(100))
        try await harness.executor.cancel(running.id)
        // The lease proceeds as soon as the running job ends. No further job has started.
        #expect(try await lease.value == "enhanced")
        #expect(try harness.generationSeeds() == [100])
        #expect(try await harness.store.jobs(status: .cancelled).count == 1)
        try await run.value
        #expect(try harness.generationSeeds() == [100, 200])
    }
}
