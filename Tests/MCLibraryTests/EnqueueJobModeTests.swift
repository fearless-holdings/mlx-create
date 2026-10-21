import Foundation
import Testing

@testable import MCLibrary

/// KTD17: `enqueueJob` defaults to the t2i mode, so existing callers keep their behaviour.
@Suite struct EnqueueJobModeTests {
    @Test func enqueueWithoutAModeStoresTextToImage() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mode-\(UUID().uuidString)")
        let store = try LibraryStore(libraryRoot: root, modelsRoot: root.appending(path: "Models"))
        let collection = try await store.defaultCollection()
        let job = try await store.enqueueJob(
            collectionID: collection.id,
            request: JobRequest(modelID: "m", family: "f", prompt: "p", width: 512, height: 512),
            batchCount: 1,
            seedPolicy: "random"
        )
        #expect(job.mode == "t2i")
        #expect(try await store.jobs(status: .queued).first?.mode == "t2i")
    }
}
