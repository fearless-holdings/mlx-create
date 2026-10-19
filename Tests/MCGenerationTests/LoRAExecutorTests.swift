import Foundation
import MCEngine
import MCGeneration
import MCLibrary
import Testing

@Suite("JobExecutor LoRA handling")
struct LoRAExecutorTests {
    private static let fakeImage: @Sendable (Int, EngineStubProtocol.Recorded) -> EngineStubProtocol.Reply = { _, _ in
        EngineStubProtocol.Reply(status: 200, body: PNGFixture.sseReply(images: 1, width: 512, height: 512), tail: nil)
    }

    @Test func savedImageRecordsTheNameQueuedEvenAfterTheLibraryRenamesTheLoRA() async throws {
        let harness = try await Harness.make(script: Self.fakeImage)
        let lora = try await harness.installLoRA(name: "Pixel art", weight: 0.8)
        let job = try await harness.enqueue(batch: 1, loras: [lora])
        try await harness.store.renameLoRA(id: lora.id, name: "Renamed")

        try await harness.executor.drain()

        let image = try #require(try await harness.store.recentImages(projectID: harness.projectID, limit: 1).first)
        #expect(image.settings.loras == [ImageLoRA(name: "Pixel art", sha256: lora.sha256, weight: 0.8)])
        #expect(try await harness.store.savedImageCount(jobID: job.id) == 1)

        let body = try #require(harness.requests(to: "v1/images/generations").first?.body)
        let sent = try #require(try JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any])
        #expect(sent["lora_paths"] as? [String] == [harness.modelsRoot.appending(path: lora.relativePath).path])
        #expect(sent["lora_scales"] as? [Double] == [0.8])
    }

    @Test func aLoRAFileGoneAtRunTimeFailsRetryableAndRetryAfterReimportSucceeds() async throws {
        let harness = try await Harness.make(script: Self.fakeImage)
        let lora = try await harness.installLoRA(name: "Pixel art")
        let job = try await harness.enqueue(batch: 1, loras: [lora])
        let file = harness.modelsRoot.appending(path: lora.relativePath)
        try FileManager.default.removeItem(at: file)

        try await harness.executor.drain()

        let failed = try #require(try await harness.store.jobs(status: .failed).first)
        #expect(failed.id == job.id)
        #expect(failed.failure == JobFailure(
            message: "LoRA Pixel art is no longer on disk. Re-import it and retry.", detail: nil, retryable: true))
        #expect(harness.requests(to: "v1/images/generations").isEmpty)

        try Data("lora".utf8).write(to: file)
        try await harness.queue.retry(job.id)
        try await harness.executor.drain()
        #expect(try await harness.store.savedImageCount(jobID: job.id) == 1)
    }

    @Test func engineRejectingALoRANamesTheLoRAAndModelAndIsNotRetryable() async throws {
        let harness = try await Harness.make { _, _ in
            .init(
                status: 400,
                body: Data(#"{"error":{"message":"no modules matching the model","type":"invalid_request_error"}}"#.utf8),
                tail: nil)
        }
        let lora = try await harness.installLoRA(name: "Pixel art")
        _ = try await harness.enqueue(batch: 1, loras: [lora])

        try await harness.executor.drain()

        let failed = try #require(try await harness.store.jobs(status: .failed).first)
        #expect(failed.failure?.message
            == "The model \(kreaModel) cannot use \"Pixel art\". Remove or replace the LoRA and try again.")
        #expect(failed.failure?.retryable == false)
        #expect(failed.failure?.detail == "no modules matching the model")
    }
}
