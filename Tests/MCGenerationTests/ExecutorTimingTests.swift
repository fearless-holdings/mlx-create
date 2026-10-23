import Foundation
import MCEngine
import MCGeneration
import MCLibrary
import Testing

@testable import MCLibrary

@Suite("JobExecutor timing samples") struct ExecutorTimingTests {
    private static let version = "26.10.3"

    private static func key(steps: Int, loraCount: Int) -> TimingSampleKey {
        TimingSampleKey(
            engineVersion: version, modelID: kreaModel, width: 512, height: 512, steps: steps, loraCount: loraCount)
    }

    /// A generation whose stream reports 3 steps as its total, whatever the request asked for.
    private static let succeeding: @Sendable (Int, EngineStubProtocol.Recorded) -> EngineStubProtocol.Reply = { _, _ in
        .init(status: 200, body: PNGFixture.sseReply(images: 1, width: 512, height: 512, steps: 3), tail: nil)
    }

    private static func request(loras: [LoRAStackEntry]? = nil) -> JobRequest {
        JobRequest(
            modelID: kreaModel, family: "krea-2", prompt: "a lighthouse at dusk", width: 512, height: 512, steps: 4,
            loras: loras)
    }

    @Test func completedGenerationWritesOneSampleKeyedByStreamTotalAndFilesSent() async throws {
        let harness = try await Harness.make(engineVersion: Self.version, script: Self.succeeding)
        let user = try await harness.installLoRA(name: "Pixel art", weight: 0.8)
        let hidden = try await harness.installLoRA(name: "Hidden one")
        try await harness.store.setAlwaysOn(id: hidden.id, scale: 0.6)
        let queued = try await harness.insertQueuedJobSkippingChecks(Self.request(loras: [user]))

        try await harness.executor.drain()

        #expect(try await harness.store.savedImageCount(jobID: queued.id) == 1)
        let sent = try #require(harness.requests(to: "v1/images/generations").first?.body)
        let object = try #require(try JSONSerialization.jsonObject(with: Data(sent.utf8)) as? [String: Any])
        #expect((object["lora_paths"] as? [String])?.count == 2)

        // The request asked for 4 steps but the stream reports 3, so the key carries the stream's total and the
        // two LoRA files the engine received: the user's and the always-on one.
        #expect(try await harness.store.recentTimings(key: Self.key(steps: 3, loraCount: 2)).count == 1)
        #expect(try await harness.store.recentTimings(key: Self.key(steps: 4, loraCount: 2)).isEmpty)
        #expect(try await harness.store.recentTimings(key: Self.key(steps: 3, loraCount: 1)).isEmpty)
    }

    @Test func cancelledGenerationWritesNothing() async throws {
        let harness = try await Harness.make(engineVersion: Self.version) { _, _ in
            // Progress arrives and the completion never does, so the generation is still open when it is cancelled.
            .init(status: 200, body: PNGFixture.sseHead(steps: 4), tail: Data())
        }
        let queued = try await harness.insertQueuedJobSkippingChecks(Self.request())
        let run = Task { try await harness.executor.drain() }

        try await eventually { harness.requests(to: "v1/images/generations").count == 1 }
        try await harness.executor.cancel(queued.id)
        EngineStubProtocol.finishHeld(harness.endpoint)
        try await run.value

        #expect(try await harness.store.jobs(status: .cancelled).count == 1)
        #expect(try await harness.store.recentTimings(key: Self.key(steps: 4, loraCount: 0)).isEmpty)
    }

    @Test func failedGenerationWritesNothing() async throws {
        let harness = try await Harness.make(engineVersion: Self.version) { _, _ in
            .init(
                status: 400,
                body: Data(#"{"error":{"message":"bad request","type":"invalid_request_error"}}"#.utf8), tail: nil)
        }
        _ = try await harness.insertQueuedJobSkippingChecks(Self.request())

        try await harness.executor.drain()

        #expect(try await harness.store.jobs(status: .failed).count == 1)
        #expect(try await harness.store.recentTimings(key: Self.key(steps: 4, loraCount: 0)).isEmpty)
    }

    /// The rejected attempt's reply stays open for 1.5 s before the engine answers it, and the retry answers at once.
    /// A sample that timed the rejected attempt too would read at least 1.5 s. The bound below separates the two.
    @Test func loraRejectedThenRetriedRecordsOnlyTheRetrysSeconds() async throws {
        let harness = try await Harness.make(engineVersion: Self.version) { call, recorded in
            if call == 1 {
                return .init(
                    status: 400,
                    body: Data(#"{"error":{"message":"no modules matching the model"}}"#.utf8), tail: Data())
            }
            return Self.succeeding(call, recorded)
        }
        let hidden = try await harness.installLoRA(name: "Hidden one")
        try await harness.store.setAlwaysOn(id: hidden.id, scale: 0.6)
        let queued = try await harness.insertQueuedJobSkippingChecks(Self.request())
        let run = Task { try await harness.executor.drain() }

        try await eventually { harness.requests(to: "v1/images/generations").count == 1 }
        try await Task.sleep(for: .milliseconds(1500))
        EngineStubProtocol.finishHeld(harness.endpoint)
        try await run.value

        #expect(harness.requests(to: "v1/images/generations").count == 2)
        #expect(try await harness.store.savedImageCount(jobID: queued.id) == 1)
        // The retry sends the user's stack only, which is empty here, so its sample lands under loraCount 0.
        let samples = try await harness.store.recentTimings(key: Self.key(steps: 3, loraCount: 0))
        #expect(samples.count == 1)
        #expect((samples.first ?? .infinity) < 1.0)
    }

    @Test func engineVersionNilWritesNothing() async throws {
        let harness = try await Harness.make(script: Self.succeeding)
        let queued = try await harness.insertQueuedJobSkippingChecks(Self.request())

        try await harness.executor.drain()

        #expect(try await harness.store.savedImageCount(jobID: queued.id) == 1)
        #expect(try await harness.store.recentTimings(key: Self.key(steps: 3, loraCount: 0)).isEmpty)
    }

    /// The sample write is best-effort, so an image already saved still completes its job.
    @Test func aFailingSampleWriteDoesNotFailTheJob() async throws {
        let harness = try await Harness.make(engineVersion: Self.version, script: Self.succeeding)
        let queued = try await harness.insertQueuedJobSkippingChecks(Self.request())
        try await harness.store.dbQueue.write { db in try db.execute(sql: "DROP TABLE generation_timing") }

        try await harness.executor.drain()

        #expect(try await harness.store.savedImageCount(jobID: queued.id) == 1)
        #expect(try await harness.store.jobs(status: .failed).isEmpty)
        #expect(try await harness.store.jobs(status: .done).count == 1)
    }
}
