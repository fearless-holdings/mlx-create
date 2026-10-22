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

        let image = try #require(try await harness.store.recentImages(collectionID: harness.collectionID, limit: 1).first)
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
        let failure = try #require(failed.failure)
        #expect(failure.message.contains("Pixel art"))
        #expect(failure.message.contains(kreaModel))
        #expect(failure.retryable)
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
        let failure = try #require(failed.failure)
        #expect(failure.message.contains("Pixel art"))
        #expect(failure.message.contains(kreaModel))
        #expect(failure.retryable == false)
    }

    @Test func aLoRAFileChangedSinceImportFailsNonRetryablyBeforeTheEngineIsAsked() async throws {
        let harness = try await Harness.make(script: Self.fakeImage)
        let lora = try await harness.installLoRA(name: "Pixel art")
        _ = try await harness.enqueue(batch: 1, loras: [lora])
        // The import recorded 4 bytes; a different size means the file is no longer the one that was imported.
        try Data("changed lora bytes".utf8).write(to: harness.modelsRoot.appending(path: lora.relativePath))

        try await harness.executor.drain()

        let failed = try #require(try await harness.store.jobs(status: .failed).first)
        let failure = try #require(failed.failure)
        #expect(failure.message.contains("Pixel art"))
        #expect(failure.message.contains(kreaModel))
        #expect(failure.retryable == false)
        #expect(harness.requests(to: "v1/images/generations").isEmpty)
    }

    @Test func aTamperedStackEntryFailsTheJobBeforeTheEngineIsAsked() async throws {
        let harness = try await Harness.make(script: Self.fakeImage)
        let lora = try await harness.installLoRA(name: "Pixel art")
        // A file that the traversal path would reach if the executor trusted the stored path.
        let outside = harness.modelsRoot.deletingLastPathComponent().appending(path: "escape.safetensors")
        try Data("x".utf8).write(to: outside)
        let tampered = LoRAStackEntry(
            id: lora.id, name: lora.name, sha256: lora.sha256, weight: 0.8, relativePath: "LoRAs/../../escape.safetensors")
        let job = try await harness.insertQueuedJobSkippingChecks(
            JobRequest(
                modelID: kreaModel, family: "krea-2", prompt: "a lighthouse at dusk", width: 512, height: 512, steps: 4,
                loras: [tampered]))

        try await harness.executor.drain()

        let failed = try #require(try await harness.store.jobs(status: .failed).first)
        #expect(failed.id == job.id)
        #expect(failed.failure?.retryable == true)
        #expect(harness.requests(to: "v1/images/generations").isEmpty)
    }

    @Test func aJobCarryingMoreLoRAsThanTheFamilysCapFailsBeforeTheEngineIsAsked() async throws {
        let harness = try await Harness.make(script: Self.fakeImage)
        let alwaysOn = try await harness.installLoRA(name: "Always on")
        try await harness.store.setAlwaysOn(id: alwaysOn.id, scale: 0.6)
        var entries: [LoRAStackEntry] = []
        for number in 1...8 {
            entries.append(try await harness.installLoRA(name: "Style \(number)"))
        }
        let job = try await harness.insertQueuedJobSkippingChecks(
            JobRequest(
                modelID: kreaModel, family: "krea-2", prompt: "a lighthouse at dusk", width: 512, height: 512, steps: 4,
                loras: entries))

        try await harness.executor.drain()

        let failed = try #require(try await harness.store.jobs(status: .failed).first)
        #expect(failed.id == job.id)
        let failure = try #require(failed.failure)
        #expect(failure.message.contains("7"))
        #expect(failure.retryable == false)
        #expect(harness.requests(to: "v1/images/generations").isEmpty)
    }

    /// D44: the engine gets the always-on file and scale, and nothing in the saved image names it.
    @Test func anAlwaysOnLoRAReachesTheEngineButNeverTheSavedImage() async throws {
        let harness = try await Harness.make(script: Self.fakeImage)
        let user = try await harness.installLoRA(name: "Pixel art", weight: 0.8)
        let hidden = try await harness.installLoRA(name: "Hidden one")
        try await harness.store.setAlwaysOn(id: hidden.id, scale: 0.6)
        let job = try await harness.insertQueuedJobSkippingChecks(
            JobRequest(
                modelID: kreaModel, family: "krea-2", prompt: "a lighthouse at dusk", width: 512, height: 512, steps: 4,
                loras: [user]))

        try await harness.executor.drain()

        let body = try #require(harness.requests(to: "v1/images/generations").first?.body)
        let sent = try #require(try JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any])
        #expect(
            sent["lora_paths"] as? [String] == [
                harness.modelsRoot.appending(path: user.relativePath).path,
                harness.modelsRoot.appending(path: hidden.relativePath).path,
            ])
        #expect(sent["lora_scales"] as? [Double] == [0.8, 0.6])
        let image = try #require(try await harness.store.recentImages(collectionID: harness.collectionID, limit: 1).first)
        #expect(image.settings.loras == [ImageLoRA(name: "Pixel art", sha256: user.sha256, weight: 0.8)])
        #expect(try await harness.store.savedImageCount(jobID: job.id) == 1)
        let png = try Data(contentsOf: await harness.store.paths.url(relativePath: image.filePath))
        let text = String(decoding: png, as: UTF8.self)
        #expect(text.contains(hidden.sha256) == false)
        #expect(text.contains("Hidden one") == false)
    }

    /// R13: an engine that cannot apply the always-on set gets one retry without it, and the image still saves.
    @Test func anEngineRejectionWithAlwaysOnRetriesOnceWithoutIt() async throws {
        let harness = try await Harness.make { call, recorded in
            let sent = (try? JSONSerialization.jsonObject(with: Data(recorded.body.utf8)) as? [String: Any]) ?? [:]
            if (sent["lora_paths"] as? [String])?.count == 1 {
                return .init(status: 400, body: Data(#"{"error":{"message":"no modules matching the model"}}"#.utf8), tail: nil)
            }
            return .init(status: 200, body: PNGFixture.sseReply(images: 1, width: 512, height: 512), tail: nil)
        }
        let hidden = try await harness.installLoRA(name: "Hidden one")
        try await harness.store.setAlwaysOn(id: hidden.id, scale: 0.6)
        let job = try await harness.insertQueuedJobSkippingChecks(
            JobRequest(modelID: kreaModel, family: "krea-2", prompt: "a lighthouse at dusk", width: 512, height: 512, steps: 4))

        try await harness.executor.drain()

        #expect(try await harness.store.savedImageCount(jobID: job.id) == 1)
        let sent = harness.requests(to: "v1/images/generations").map(\.body)
        #expect(sent.count == 2)
        #expect(sent[0].contains("lora_paths"))
        #expect(sent[1].contains("lora_paths") == false)
    }

    /// A second rejection is the user's own LoRA: the job fails naming only the stack.
    @Test func aSecondRejectionFailsNamingOnlyTheUsersLoRAs() async throws {
        let harness = try await Harness.make { _, _ in
            .init(status: 400, body: Data(#"{"error":{"message":"no modules matching the model"}}"#.utf8), tail: nil)
        }
        let user = try await harness.installLoRA(name: "Pixel art")
        let hidden = try await harness.installLoRA(name: "Hidden one")
        try await harness.store.setAlwaysOn(id: hidden.id, scale: 0.6)
        _ = try await harness.insertQueuedJobSkippingChecks(
            JobRequest(
                modelID: kreaModel, family: "krea-2", prompt: "a lighthouse at dusk", width: 512, height: 512, steps: 4,
                loras: [user]))

        try await harness.executor.drain()

        let failed = try #require(try await harness.store.jobs(status: .failed).first)
        let failure = try #require(failed.failure)
        #expect(failure.message.contains("Pixel art"))
        #expect(failure.message.contains("Hidden one") == false)
        #expect(harness.requests(to: "v1/images/generations").count == 2)
    }
}
