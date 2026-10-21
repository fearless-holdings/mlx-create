import Foundation
import GRDB
import Testing
@testable import MCLibrary

@Suite struct GalleryStoreActionsTests {
    /// A trash that moves the file into a folder of the test's own, like the real Trash but isolated.
    static func fakeTrash(_ folder: URL) -> TrashFunction {
        { url in
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let target = folder.appending(path: UUID().uuidString + "-" + url.lastPathComponent)
            try FileManager.default.moveItem(at: url, to: target)
            return target
        }
    }

    static func exists(_ store: LibraryStore, _ relative: String) async -> Bool {
        FileManager.default.fileExists(atPath: await store.paths.url(relativePath: relative).path)
    }

    // MARK: Delete

    @Test func deleteTrashesPNGAndThumbnailAndRemovesTheRow() async throws {
        let f = try await GalleryFilterTests.fixture()
        let image = try await GalleryFilterTests.save(f, prompt: "gone", loras: [GalleryFilterTests.x])
        let trash = FileManager.default.temporaryDirectory.appending(path: "mc-trash-\(UUID().uuidString)")

        let outcomes = await f.store.deleteImages(ids: [image.id], trash: Self.fakeTrash(trash))

        #expect(outcomes == [image.id: .deleted])
        #expect(try await f.store.image(id: image.id) == nil)
        #expect(await !Self.exists(f.store, image.filePath))
        #expect(await !Self.exists(f.store, image.thumbPath))
        #expect(try FileManager.default.contentsOfDirectory(atPath: trash.path).count == 2)
        // The prompt index and LoRA rows go with it.
        #expect(try await f.store.matchingImageCount(query: GalleryQuery(collectionID: f.collection.id, search: "gone")) == 0)
        let facets = try await f.store.galleryFacets(query: GalleryQuery(collectionID: f.collection.id))
        #expect(facets.loras.isEmpty)
    }

    @Test func aFailingImageIsLeftIntactAndOthersStillGo() async throws {
        let f = try await GalleryFilterTests.fixture()
        let keep = try await GalleryFilterTests.save(f, prompt: "keep")
        let drop = try await GalleryFilterTests.save(f, prompt: "drop")
        let trash = FileManager.default.temporaryDirectory.appending(path: "mc-trash-\(UUID().uuidString)")
        let real = Self.fakeTrash(trash)
        let keepPNG = await f.store.paths.url(relativePath: keep.filePath)
        let trashFn: TrashFunction = { url in
            if url == keepPNG { throw CocoaError(.featureUnsupported) }
            return try real(url)
        }

        let outcomes = await f.store.deleteImages(ids: [keep.id, drop.id], trash: trashFn)

        guard case .failed(let message) = outcomes[keep.id] else { Issue.record("expected a failure"); return }
        #expect(message.contains("no Trash"))
        #expect(outcomes[drop.id] == .deleted)
        #expect(try await f.store.image(id: keep.id) != nil)
        #expect(await Self.exists(f.store, keep.filePath))
    }

    @Test func aFailureAfterThePNGWasTrashedPutsThePNGBack() async throws {
        let f = try await GalleryFilterTests.fixture()
        let image = try await GalleryFilterTests.save(f, prompt: "half")
        let trash = FileManager.default.temporaryDirectory.appending(path: "mc-trash-\(UUID().uuidString)")
        let real = Self.fakeTrash(trash)
        let thumb = await f.store.paths.url(relativePath: image.thumbPath)
        let trashFn: TrashFunction = { url in
            if url == thumb { throw CocoaError(.fileWriteNoPermission) }
            return try real(url)
        }

        let outcomes = await f.store.deleteImages(ids: [image.id], trash: trashFn)

        guard case .failed = outcomes[image.id] else { Issue.record("expected a failure"); return }
        #expect(try await f.store.image(id: image.id) != nil)
        #expect(await Self.exists(f.store, image.filePath))
    }

    @Test func aFileAlreadyMissingStillLetsTheRowGo() async throws {
        let f = try await GalleryFilterTests.fixture()
        let image = try await GalleryFilterTests.save(f, prompt: "lost")
        try FileManager.default.removeItem(at: await f.store.paths.url(relativePath: image.filePath))
        let trash = FileManager.default.temporaryDirectory.appending(path: "mc-trash-\(UUID().uuidString)")

        let outcomes = await f.store.deleteImages(ids: [image.id], trash: Self.fakeTrash(trash))

        #expect(outcomes == [image.id: .deleted])
        #expect(try await f.store.image(id: image.id) == nil)
    }

    @Test func imagesOfAnUnfinishedJobAreSkippedButFinishedOnesGo() async throws {
        let f = try await GalleryFilterTests.fixture()
        let job = try await f.store.enqueueJob(collectionID: f.collection.id, request: LibraryStoreTests.request(), batchCount: 2, seedPolicy: "{}")
        func saveFor(_ job: Job) async throws -> LibraryImage {
            try await f.store.saveImage(NewImage(
                collectionID: f.collection.id, jobID: job.id, pngData: try TestPNG.make(width: 16, height: 16),
                settings: LibraryStoreTests.settings()))
        }
        let trash = FileManager.default.temporaryDirectory.appending(path: "mc-trash-\(UUID().uuidString)")

        for status in [JobStatus.queued, .running, .paused] {
            try await f.store.setJobStatus(job.id, status)
            let image = try await saveFor(job)
            #expect(await f.store.deleteImages(ids: [image.id], trash: Self.fakeTrash(trash)) == [image.id: .skippedActiveJob])
            #expect(try await f.store.image(id: image.id) != nil)
        }

        try await f.store.setJobStatus(job.id, .done)
        let finished = try await saveFor(job)
        #expect(await f.store.deleteImages(ids: [finished.id], trash: Self.fakeTrash(trash)) == [finished.id: .deleted])
        // Deleting an image of a finished job leaves the job finished.
        #expect(try await f.store.jobs(status: .done).map(\.id) == [job.id])
    }

    // MARK: Move

    @Test func moveImagesMovesAllOrNone() async throws {
        let f = try await GalleryFilterTests.fixture()
        let target = try await f.store.createCollection(name: "Target")
        let a = try await GalleryFilterTests.save(f, prompt: "a")
        let b = try await GalleryFilterTests.save(f, prompt: "b")

        try await f.store.moveImages(ids: [a.id, b.id], toCollection: target.id)
        #expect(try await f.store.recentImages(collectionID: target.id, limit: 10).count == 2)

        let c = try await GalleryFilterTests.save(f, prompt: "c")
        do {
            try await f.store.moveImages(ids: [c.id, UUID()], toCollection: target.id)
            Issue.record("expected the move to fail")
        } catch {
            #expect(error as? LibraryError == .notFound)
        }
        #expect(try await f.store.image(id: c.id)?.collectionID == f.collection.id)
        // The prompt index follows a moved image into its new collection.
        #expect(try await f.store.matchingImageCount(query: GalleryQuery(collectionID: target.id, search: "a")) == 1)
    }

    // MARK: Export

    @Test func exportCopiesBytesKeepsMetadataAndNeverOverwrites() async throws {
        let f = try await GalleryFilterTests.fixture()
        let image = try await GalleryFilterTests.save(f, prompt: "a lighthouse at dusk")
        let folder = FileManager.default.temporaryDirectory.appending(path: "mc-export-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let first = await f.store.exportImages(ids: [image.id], to: folder)
        let second = await f.store.exportImages(ids: [image.id], to: folder)

        guard case .exported(let one)? = first[image.id], case .exported(let two)? = second[image.id] else {
            Issue.record("expected both exports to succeed"); return
        }
        #expect(one != two)
        let original = try Data(contentsOf: await f.store.paths.url(relativePath: image.filePath))
        #expect(try Data(contentsOf: one) == original)
        #expect(try Data(contentsOf: two) == original)
        let restored = try #require(try MetadataCodec.read(fromPNG: try Data(contentsOf: one)))
        #expect(restored.prompt == "a lighthouse at dusk")
    }

    @Test func aChosenExportNameCannotLeaveTheFolderOrDoublePngExtension() async throws {
        let f = try await GalleryFilterTests.fixture()
        let image = try await GalleryFilterTests.save(f, prompt: "a lighthouse at dusk")
        let root = FileManager.default.temporaryDirectory.appending(path: "mc-export-\(UUID().uuidString)", directoryHint: .isDirectory)
        let folder = root.appending(path: "out", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        _ = await f.store.exportImages(ids: [image.id], to: folder, baseName: "../escaped.png")
        _ = await f.store.exportImages(ids: [image.id], to: folder, baseName: "..")

        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == ["out"])
        let files = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
        #expect(files.contains("escaped.png"))
        #expect(files.count == 2)
    }

    @Test func exportOfAnUnknownImageFailsWithoutAFile() async throws {
        let f = try await GalleryFilterTests.fixture()
        let folder = FileManager.default.temporaryDirectory.appending(path: "mc-export-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let ghost = UUID()
        let outcomes = await f.store.exportImages(ids: [ghost], to: folder)
        guard case .failed? = outcomes[ghost] else { Issue.record("expected a failure"); return }
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty)
    }
}
