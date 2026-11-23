import Foundation
import MCEngine
import MCGeneration
import Testing

@testable import MCLibrary

/// Below 24 GiB: memory tier 1, one model resident.
private let belowTwentyFourGiB = MemoryTier(physicalMemoryBytes: 16 << 30)
/// At or above 24 GiB and below 48 GiB: memory tier 2, two models resident.
private let twentyFourGiBOrMore = MemoryTier(physicalMemoryBytes: 36 << 30)

private let noGeneration: @Sendable (Int, EngineStubProtocol.Recorded) -> EngineStubProtocol.Reply = { _, _ in
    .init(status: 404, body: Data(), tail: nil)
}

private let immediateImage: @Sendable (Int, EngineStubProtocol.Recorded) -> EngineStubProtocol.Reply = { _, _ in
    .init(status: 200, body: PNGFixture.sseReply(images: 1, width: 512, height: 512), tail: nil)
}

/// Answers the first generation request with a 503 out-of-memory refusal, then generates.
private let refusedFirstImage: @Sendable (Int, EngineStubProtocol.Recorded) -> EngineStubProtocol.Reply = { number, _ in
    number == 1
        ? .init(status: 503, body: PNGFixture.oomBody(), tail: nil)
        : .init(status: 200, body: PNGFixture.sseReply(images: 1, width: 512, height: 512), tail: nil)
}

/// KTD5/KTD6: the agent's lease flags and the kept-resident chat models (docs/lld/agent.md §7).
@Suite struct AgentResidencyTests {
    @Test func rewarmsDisplacedFalseReleasesAtOnceAndDoesNotReloadTheImageModel() async throws {
        let harness = try await Harness.make(
            loaded: [kreaModel], known: [kreaModel, otherModel, enhancerModel], memoryTier: belowTwentyFourGiB,
            script: immediateImage)
        let text = try await harness.executor.withEnhancerLease(
            enhancerModelID: enhancerModel, rewarmsDisplaced: false
        ) { () async throws -> String in
            "planned"
        }
        #expect(text == "planned")
        // The enhancer is unloaded, the displaced image model stays out, and no re-warm is coming.
        #expect(harness.engineCalls() == ["unload \(kreaModel)", "load \(enhancerModel)", "unload \(enhancerModel)"])

        // The flag is already released: a model switch and a queued job run without waiting.
        try await harness.executor.selectModel(otherModel)
        _ = try await harness.enqueue(batch: 1, seedPolicy: .increment(base: 100))
        try await harness.executor.drain()
        #expect(try harness.generationSeeds() == [100])
        // The job's model is Krea, so the run switches back off the selected FLUX.2 klein.
        #expect(
            harness.engineCalls() == [
                "unload \(kreaModel)", "load \(enhancerModel)", "unload \(enhancerModel)",
                "load \(otherModel)", "unload \(otherModel)", "load \(kreaModel)", "generate 100",
            ])
    }

    @Test func aRefusedLLMLoadEvictsResidentsAndRetriesWhenTheFlagIsSet() async throws {
        let harness = try await Harness.make(
            loaded: [kreaModel], known: [kreaModel, enhancerModel], refusedLoadCounts: [enhancerModel: 1],
            memoryTier: twentyFourGiBOrMore, script: noGeneration)
        let text = try await harness.executor.withEnhancerLease(
            enhancerModelID: enhancerModel, retriesLoadAfterMemoryRefusal: true
        ) { () async throws -> String in
            "planned"
        }
        #expect(text == "planned")
        #expect(harness.engineCalls() == ["load \(enhancerModel)", "unload \(kreaModel)", "load \(enhancerModel)"])
    }

    @Test func aSecondRefusalOfTheLLMLoadFailsTheLease() async throws {
        let harness = try await Harness.make(
            loaded: [kreaModel], known: [kreaModel, enhancerModel], refusedLoadCounts: [enhancerModel: 2],
            memoryTier: twentyFourGiBOrMore, script: noGeneration)
        var thrown: Error?
        do {
            _ = try await harness.executor.withEnhancerLease(
                enhancerModelID: enhancerModel, retriesLoadAfterMemoryRefusal: true
            ) { () async throws -> String in
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
        #expect(harness.engineCalls() == ["load \(enhancerModel)", "unload \(kreaModel)", "load \(enhancerModel)"])
    }

    @Test func aRefusedLLMLoadWithoutTheRetryFlagBehavesAsBefore() async throws {
        let harness = try await Harness.make(
            loaded: [kreaModel], known: [kreaModel, enhancerModel], refusedLoadCounts: [enhancerModel: 1],
            memoryTier: twentyFourGiBOrMore, script: noGeneration)
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
        #expect(harness.engineCalls() == ["load \(enhancerModel)", "unload \(kreaModel)"])
    }

    @Test func aModelSwitchLeavesTheKeptModelLoadedAtTierTwo() async throws {
        let harness = try await Harness.make(
            loaded: [kreaModel, enhancerModel], known: [kreaModel, otherModel, enhancerModel],
            memoryTier: twentyFourGiBOrMore, script: noGeneration)
        await harness.executor.setKeptResidentModels([enhancerModel])
        try await harness.executor.selectModel(otherModel)
        #expect(harness.engineCalls() == ["unload \(kreaModel)", "load \(otherModel)"])
    }

    @Test func aModelSwitchKeepsNothingAtTierOne() async throws {
        let harness = try await Harness.make(
            loaded: [kreaModel, enhancerModel], known: [kreaModel, otherModel, enhancerModel],
            memoryTier: belowTwentyFourGiB, script: noGeneration)
        await harness.executor.setKeptResidentModels([enhancerModel])
        try await harness.executor.selectModel(otherModel)
        #expect(
            harness.engineCalls() == ["unload \(kreaModel)", "unload \(enhancerModel)", "load \(otherModel)"])
    }

    @Test func aRefusedModelSwitchEvictsTheKeptModelAndRetries() async throws {
        let harness = try await Harness.make(
            loaded: [kreaModel, enhancerModel], known: [kreaModel, otherModel, enhancerModel],
            refusedLoadCounts: [otherModel: 1], memoryTier: twentyFourGiBOrMore, script: noGeneration)
        await harness.executor.setKeptResidentModels([enhancerModel])
        try await harness.executor.selectModel(otherModel)
        #expect(
            harness.engineCalls() == [
                "unload \(kreaModel)", "load \(otherModel)", "unload \(enhancerModel)", "load \(otherModel)",
            ])
    }

    @Test func aRefusedModelSwitchWithNoKeptModelLoadedFailsAsBefore() async throws {
        let harness = try await Harness.make(
            loaded: [kreaModel], known: [kreaModel, otherModel, enhancerModel],
            refusedLoadCounts: [otherModel: 1], memoryTier: twentyFourGiBOrMore, script: noGeneration)
        await harness.executor.setKeptResidentModels([enhancerModel])
        var thrown: Error?
        do {
            try await harness.executor.selectModel(otherModel)
        } catch {
            thrown = error
        }
        let error = try #require(thrown as? EngineError)
        switch error {
        case .outOfMemory: break
        default: Issue.record("expected outOfMemory, got \(error)")
        }
        #expect(harness.engineCalls() == ["unload \(kreaModel)", "load \(otherModel)"])
    }

    @Test func aRefusedGenerationEvictsTheKeptModelAndRetriesTheAttempt() async throws {
        let harness = try await Harness.make(
            loaded: [enhancerModel], known: [kreaModel, enhancerModel],
            memoryTier: twentyFourGiBOrMore, script: refusedFirstImage)
        await harness.executor.setKeptResidentModels([enhancerModel])
        _ = try await harness.enqueue(batch: 1, seedPolicy: .increment(base: 100))
        try await harness.executor.drain()
        #expect(try harness.generationSeeds() == [100, 100])
        #expect(
            harness.engineCalls() == [
                "load \(kreaModel)", "generate 100", "unload \(enhancerModel)", "generate 100",
            ])
        #expect(try await harness.store.jobs(status: .done).count == 1)
    }

    @Test func aRefusedGenerationWithNoKeptModelLoadedFailsAsBefore() async throws {
        let harness = try await Harness.make(
            loaded: [kreaModel], known: [kreaModel, enhancerModel],
            memoryTier: twentyFourGiBOrMore, script: refusedFirstImage)
        // The kept set names a model that is not resident, so there is nothing to evict for a retry.
        await harness.executor.setKeptResidentModels([enhancerModel])
        _ = try await harness.enqueue(batch: 1, seedPolicy: .increment(base: 100))
        try await harness.executor.drain()
        #expect(try harness.generationSeeds() == [100])
        #expect(harness.engineCalls() == ["generate 100", "unload \(kreaModel)"])
        #expect(try await harness.store.jobs(status: .failed).count == 1)
    }
}
