import Foundation
import ImageIO
import Synchronization
import Testing

@testable import MCLibrary

@Suite struct LibraryStoreTests {
    struct InjectedFailure: Error {}

    static func tempRoot() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "mc-library-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func settings(prompt: String = "a cat") -> ImageSettings {
        ImageSettings(
            prompt: prompt, negativePrompt: nil, modelID: "ddalcu/Krea-2-Turbo", family: "krea2",
            requestedWidth: 1024, requestedHeight: 768, requestedSteps: nil, guidance: nil,
            seed: 42, width: 0, height: 0, steps: 5, engineVersion: "26.10.2"
        )
    }

    static func request() -> JobRequest {
        JobRequest(
            modelID: "ddalcu/Krea-2-Turbo", family: "krea2", prompt: "a cat", negativePrompt: nil,
            width: 64, height: 48, steps: nil, guidance: nil
        )
    }

    static func files(under url: URL) -> [String] {
        guard let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil) else { return [] }
        var names: [String] = []
        for case let f as URL in e where !f.hasDirectoryPath { names.append(f.lastPathComponent) }
        return names
    }

    @Test func firstLaunchCreatesOneDefaultCollectionAndSecondLaunchKeepsIt() async throws {
        let root = try Self.tempRoot()
        let first = try LibraryStore(libraryRoot: root, modelsRoot: root.appending(path: "Models"))
        let collectionID = try await first.defaultCollection().id
        let second = try LibraryStore(libraryRoot: root, modelsRoot: root.appending(path: "Models"))
        #expect(try await second.defaultCollection().id == collectionID)
    }

    @Test func saveImageWritesPNGThumbnailAndRow() async throws {
        let root = try Self.tempRoot()
        let store = try LibraryStore(libraryRoot: root, modelsRoot: root.appending(path: "Models"))
        let collection = try await store.defaultCollection()
        let job = try await store.enqueueJob(collectionID: collection.id, request: Self.request(), batchCount: 1, seedPolicy: "{}")

        let png = try TestPNG.make(width: 64, height: 48)
        let record = try await store.saveImage(
            NewImage(
                collectionID: collection.id, jobID: job.id, pngData: png, settings: Self.settings()
            ))

        #expect(record.width == 64)
        #expect(record.height == 48)
        #expect(record.steps == 5)
        let pngURL = root.appending(path: record.filePath)
        let thumbURL = root.appending(path: record.thumbPath)
        #expect(FileManager.default.fileExists(atPath: pngURL.path))
        #expect(FileManager.default.fileExists(atPath: thumbURL.path))

        let recent = try await store.recentImages(collectionID: collection.id, limit: 10)
        #expect(recent.map(\.id) == [record.id])
        #expect(try await store.imageSettings(id: record.id)?.prompt == "a cat")
        #expect(try await store.savedImageCount(jobID: job.id) == 1)
    }

    @Test func failureBeforeRowInsertLeavesNoFilesOrRow() async throws {
        let root = try Self.tempRoot()
        let store = try LibraryStore(libraryRoot: root, modelsRoot: root.appending(path: "Models"))
        let collection = try await store.defaultCollection()
        await store.setBeforeRowInsertHook { throw InjectedFailure() }

        await #expect(throws: InjectedFailure.self) {
            _ = try await store.saveImage(
                NewImage(
                    collectionID: collection.id, jobID: nil, pngData: try TestPNG.make(width: 32, height: 32),
                    settings: Self.settings()
                ))
        }
        #expect(Self.files(under: root.appending(path: "Collections")).isEmpty)
        #expect(Self.files(under: root.appending(path: "Thumbnails")).isEmpty)
        #expect(try await store.recentImages(collectionID: collection.id, limit: 10).isEmpty)
    }

    @Test func leftoverPartialFilesAreSweptAtLaunch() throws {
        let root = try Self.tempRoot()
        _ = try LibraryStore(libraryRoot: root, modelsRoot: root.appending(path: "Models"))
        let dir = root.appending(path: "Collections/abc/2026-10", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let partial = dir.appending(path: "junk.png.partial")
        try Data("x".utf8).write(to: partial)

        _ = try LibraryStore(libraryRoot: root, modelsRoot: root.appending(path: "Models"))
        #expect(!FileManager.default.fileExists(atPath: partial.path))
    }

    @Test func asyncOpenCreatesTheSchemaAndSweepsPartialsOffTheMainThread() async throws {
        let root = try Self.tempRoot()
        let dir = root.appending(path: "Collections/abc/2026-10", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let partial = dir.appending(path: "junk.png.partial")
        try Data("x".utf8).write(to: partial)
        let openedOnMain = Mutex<Bool?>(nil)

        let store = try await LibraryStore.openOffActor(libraryRoot: root, modelsRoot: root.appending(path: "Models")) { onMain in
            openedOnMain.withLock { $0 = onMain }
        }

        #expect(FileManager.default.fileExists(atPath: LibraryPaths(root: root, modelsRoot: root.appending(path: "Models")).database.path))
        #expect(!FileManager.default.fileExists(atPath: partial.path))
        #expect(try await store.defaultCollection().name == "Default")
        #expect(openedOnMain.withLock { $0 } == false)
    }

    @Test func asyncOpenReusesAnExistingDefaultCollection() async throws {
        let root = try Self.tempRoot()
        let first = try await LibraryStore.open(libraryRoot: root, modelsRoot: root.appending(path: "Models"))
        let collectionID = try await first.defaultCollection().id
        let second = try await LibraryStore.open(libraryRoot: root, modelsRoot: root.appending(path: "Models"))
        #expect(try await second.defaultCollection().id == collectionID)
    }

    @Test func embeddedMetadataRecordsTheRealPixelSizeNotTheRequest() async throws {
        let store = try LibraryStore(libraryRoot: try Self.tempRoot(), modelsRoot: try Self.tempRoot())
        let collection = try await store.defaultCollection()
        let job = try await store.enqueueJob(collectionID: collection.id, request: Self.request(), batchCount: 1, seedPolicy: "random")
        let saved = try await store.saveImage(
            NewImage(
                collectionID: collection.id, jobID: job.id, pngData: try TestPNG.make(width: 40, height: 24), settings: Self.settings()))

        #expect(saved.settings.width == 40 && saved.settings.height == 24)
        let onDisk = try Data(contentsOf: await store.paths.url(relativePath: saved.filePath))
        let embedded = try #require(try MetadataCodec.read(fromPNG: onDisk))
        #expect(embedded.width == 40 && embedded.height == 24)
    }

    @Test func failureSurvivesReopenAndRetryClearsIt() async throws {
        let root = try Self.tempRoot()
        let store = try LibraryStore(libraryRoot: root, modelsRoot: root.appending(path: "Models"))
        let collection = try await store.defaultCollection()
        let job = try await store.enqueueJob(collectionID: collection.id, request: Self.request(), batchCount: 2, seedPolicy: "random")
        let failure = JobFailure(message: "Not enough memory", detail: "engine said x", retryable: true)
        try await store.setJobStatus(job.id, .failed, failure: failure)

        let reopened = try LibraryStore(libraryRoot: root, modelsRoot: root.appending(path: "Models"))
        #expect(try await reopened.jobs(status: .failed).first?.failure == failure)

        try await reopened.setJobStatus(job.id, .queued)
        #expect(try await reopened.jobs(status: .queued).first?.failure == nil)
    }

    @Test func queueOrdersJobsAndRejectsMovingNonQueued() async throws {
        let root = try Self.tempRoot()
        let store = try LibraryStore(libraryRoot: root, modelsRoot: root.appending(path: "Models"))
        let collection = try await store.defaultCollection()
        let a = try await store.enqueueJob(collectionID: collection.id, request: Self.request(), batchCount: 1, seedPolicy: "a")
        let b = try await store.enqueueJob(collectionID: collection.id, request: Self.request(), batchCount: 1, seedPolicy: "b")
        let c = try await store.enqueueJob(collectionID: collection.id, request: Self.request(), batchCount: 1, seedPolicy: "c")

        #expect(try await store.nextQueuedJob()?.id == a.id)
        try await store.moveQueuedJob(c.id, by: -1)
        #expect(try await store.jobs(status: .queued).map(\.id) == [a.id, c.id, b.id])

        try await store.moveQueuedJob(b.id, by: -5)
        #expect(try await store.jobs(status: .queued).map(\.id) == [b.id, a.id, c.id])
        try await store.moveQueuedJob(b.id, by: 99)
        #expect(try await store.jobs(status: .queued).map(\.id) == [a.id, c.id, b.id])

        try await store.setJobStatus(a.id, .running)
        #expect(try await store.nextQueuedJob()?.id == c.id)
        await #expect(throws: LibraryError.notQueued) {
            try await store.moveQueuedJob(a.id, by: 1)
        }
    }

    /// A job requeued after a pause keeps its position, which a job enqueued meanwhile can share; the lower id runs first.
    @Test func tiedQueuePositionsRunInIDOrder() async throws {
        let root = try Self.tempRoot()
        let store = try LibraryStore(libraryRoot: root, modelsRoot: root.appending(path: "Models"))
        let collection = try await store.defaultCollection()
        let a = try await store.enqueueJob(collectionID: collection.id, request: Self.request(), batchCount: 2, seedPolicy: "a")
        try await store.setJobStatus(a.id, .running)
        let b = try await store.enqueueJob(collectionID: collection.id, request: Self.request(), batchCount: 1, seedPolicy: "b")
        try await store.setJobStatus(a.id, .paused)
        try await store.setJobStatus(a.id, .queued)
        #expect(a.position == b.position)

        let idOrder = [a.id, b.id].sorted { $0.uuidString < $1.uuidString }
        #expect(try await store.jobs(status: .queued).map(\.id) == idOrder)
        #expect(try await store.nextQueuedJob()?.id == idOrder[0])
    }

    @Test func failedPNGWriteLeavesNoPartialFile() async throws {
        let root = try Self.tempRoot()
        let store = try LibraryStore(libraryRoot: root, modelsRoot: root.appending(path: "Models"))
        let collection = try await store.defaultCollection()
        // The hook writes the partial file and then fails, as a write cut short by a full disk would.
        await store.setBeforePartialWriteHook { url in
            try Data("torn".utf8).write(to: url)
            throw InjectedFailure()
        }

        await #expect(throws: InjectedFailure.self) {
            _ = try await store.saveImage(
                NewImage(
                    collectionID: collection.id, jobID: nil, pngData: try TestPNG.make(width: 32, height: 32),
                    settings: Self.settings()
                ))
        }
        #expect(Self.files(under: root.appending(path: "Collections")).isEmpty)
    }

    @Test func transitionChangesOnlyAJobStillInAnAllowedStatus() async throws {
        let root = try Self.tempRoot()
        let store = try LibraryStore(libraryRoot: root, modelsRoot: root.appending(path: "Models"))
        let collection = try await store.defaultCollection()
        let cancelled = try await store.enqueueJob(
            collectionID: collection.id, request: Self.request(), batchCount: 1, seedPolicy: "random")
        try await store.setJobStatus(cancelled.id, .cancelled)
        let finished = try await store.enqueueJob(collectionID: collection.id, request: Self.request(), batchCount: 1, seedPolicy: "random")
        try await store.setJobStatus(finished.id, .done)

        // A cancelled job cannot be started, and a finished job cannot be cancelled.
        #expect(try await store.transitionJob(cancelled.id, from: [.queued], to: .running) == false)
        #expect(try await store.transitionJob(finished.id, from: [.queued, .paused], to: .cancelled) == false)
        #expect(try await store.jobs(status: .cancelled).map(\.id) == [cancelled.id])
        #expect(try await store.jobs(status: .done).map(\.id) == [finished.id])
        #expect(try await store.jobs(status: .running).isEmpty)
    }
}
