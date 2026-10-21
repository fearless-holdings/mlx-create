import Foundation
import MCGeneration
import Testing

@testable import MCLibrary

@Suite struct CollectionJobTests {
    @Test func jobEnqueuedIntoAnotherCollectionSavesThereOnly() async throws {
        let harness = try await Harness.make { _, _ in
            .init(status: 200, body: PNGFixture.sseReply(images: 1, width: 512, height: 512), tail: nil)
        }
        let defaultID = harness.collectionID
        let second = try await harness.store.createCollection(name: "Second")
        _ = try await harness.store.enqueueJob(
            collectionID: second.id,
            request: JobRequest(
                modelID: kreaModel, family: "krea-2-turbo", prompt: "a lighthouse at dusk",
                width: 512, height: 512, steps: 4),
            batchCount: 1,
            seedPolicy: SeedPolicy.random.encoded)

        try await harness.executor.drain()

        let inSecond = try await harness.store.recentImages(collectionID: second.id, limit: 10)
        let inDefault = try await harness.store.recentImages(collectionID: defaultID, limit: 10)
        #expect(inSecond.count == 1)
        #expect(inDefault.isEmpty)
    }
}
