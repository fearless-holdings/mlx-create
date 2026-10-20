import Foundation
import MCEngine
import MCGeneration
import Testing

@testable import MCLibrary

/// KTD17: a queued job whose mode the executor cannot generate fails at the top of `run`, with no engine request.
/// KTD16 / D24: a job with no progress event records its step count as unknown.
@Suite struct UnsupportedModeAndUnknownStepsTests {
    @Test func aQueuedJobInAnUnsupportedModeFailsWithoutAnyEngineRequest() async throws {
        let harness = try await Harness.make { _, _ in
            .init(
                status: 200, body: PNGFixture.sseReply(images: 1, width: 512, height: 512),
                tail: nil)
        }
        let job = try await harness.store.enqueueJob(
            collectionID: harness.collectionID,
            request: JobRequest(
                modelID: kreaModel, family: "krea-2-turbo", prompt: "a lighthouse", width: 512,
                height: 512, steps: 4
            ),
            batchCount: 1,
            seedPolicy: SeedPolicy.random.encoded,
            mode: "i2i"
        )
        // Must return: a job left queued here would make `drain` spin.
        try await harness.executor.drain()
        let failed = try #require(try await harness.store.jobs(status: .failed).first)
        #expect(failed.id == job.id)
        #expect(failed.failure?.message.isEmpty == false)
        #expect(failed.failure?.retryable == false)
        #expect(try await harness.store.jobs(status: .queued).isEmpty)
        #expect(EngineStubProtocol.requests(harness.endpoint).isEmpty)
    }

    @Test func aJobWithNoProgressEventsStoresUnknownStepsAndNoStepsLine() async throws {
        let harness = try await Harness.make { _, _ in
            .init(status: 200, body: PNGFixture.sseTail(width: 512, height: 512), tail: nil)
        }
        _ = try await harness.enqueue(batch: 1, steps: 4)
        try await harness.executor.drain()
        let image = try #require(
            try await harness.store.recentImages(collectionID: harness.collectionID, limit: 1).first)
        #expect(image.settings.steps == nil)
        let png = try Data(contentsOf: await harness.store.paths.url(relativePath: image.filePath))
        let parameters = try #require(try PNGChunks.parse(png).first { $0.type == "tEXt" })
        #expect(!String(decoding: parameters.data, as: UTF8.self).contains("Steps:"))
    }
}
