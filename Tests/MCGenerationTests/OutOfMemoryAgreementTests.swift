import Foundation
@testable import MCEngine
import MCGeneration
import MCLibrary
import Testing

/// KTD15: every out-of-memory input stores the same message and retryable flag, whichever path reported it.
@Suite struct OutOfMemoryAgreementTests {
    private static func crashFailure(_ kind: CrashKind, detail: String) -> JobFailure {
        FailureMapping.failure(for: EngineCrash(
            kind: kind, message: EngineSupervisor.userMessage(for: kind), detail: detail, exit: nil
        ))
    }

    @Test func the503RefusalAndEveryOutOfMemoryCrashStoreTheSameFailure() {
        let refusal = FailureMapping.failure(for: EngineError.outOfMemory(engineMessage: "needs 17.6 GB"))
        let preflight = CrashClassifier.classify(
            logTail: "Insufficient memory to load model", exit: .code(1), phase: .ready
        )
        let metal = CrashClassifier.classify(
            logTail: "kIOGPUCommandBufferCallbackErrorOutOfMemory", exit: .signal(6), phase: .ready
        )
        #expect(preflight == .outOfMemory)
        #expect(metal == .outOfMemory)
        #expect(refusal.retryable)
        #expect(Self.crashFailure(preflight, detail: "preflight").message == refusal.message)
        #expect(Self.crashFailure(preflight, detail: "preflight").retryable == refusal.retryable)
        #expect(Self.crashFailure(metal, detail: "metal").message == refusal.message)
        #expect(Self.crashFailure(metal, detail: "metal").retryable == refusal.retryable)
    }

    @Test func eachCrashKindUsesTheOutOfMemoryFailureOnlyWhenItIsOutOfMemory() {
        let oom = FailureMapping.failure(for: EngineError.outOfMemory(engineMessage: nil))
        for kind in CrashKind.allCases {
            let failure = Self.crashFailure(kind, detail: "")
            if kind == .outOfMemory {
                #expect(failure.message == oom.message)
                #expect(failure.retryable == oom.retryable)
            } else {
                #expect(failure.message != oom.message)
            }
        }
    }

    /// A connection that drops mid-generation, explained by an out-of-memory crash, fails the job with the shared
    /// message and is retryable. The crash path has no unload step, so no unload request is made.
    @Test func aMidGenerationOutOfMemoryCrashFailsRetryableWithoutUnloading() async throws {
        let harness = try await Harness.make { _, _ in
            .init(status: 200, body: PNGFixture.sseHead(), tail: Data())
        }
        let endpoint = harness.endpoint
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [EngineStubProtocol.self]
        let client = EngineClient(endpoint: { endpoint }, configuration: configuration)
        let crash = EngineCrash(
            kind: .outOfMemory, message: EngineSupervisor.userMessage(for: .outOfMemory),
            detail: "Insufficient memory to load model", exit: nil
        )
        let executor = JobExecutor(
            store: harness.store, modelsRoot: harness.modelsRoot, client: client, queue: harness.queue,
            crashKind: { crash })
        let job = try await harness.enqueue(batch: 1)
        let run = Task { try await executor.drain() }
        try await eventually { harness.requests(to: "v1/images/generations").isEmpty == false }
        EngineStubProtocol.finishHeld(endpoint)
        try await run.value
        let failed = try #require(try await harness.store.jobs(status: .failed).first)
        #expect(failed.id == job.id)
        #expect(failed.failure?.message == OutOfMemoryFailure.message)
        #expect(failed.failure?.retryable == true)
        #expect(harness.requests(to: "v1/unload-model").isEmpty)
    }
}
