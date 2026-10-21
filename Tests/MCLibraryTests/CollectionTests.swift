import Foundation
import GRDB
import Testing
@testable import MCLibrary

@Suite struct CollectionTests {
    static func root() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "mc-collections-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func open(_ root: URL) throws -> LibraryStore {
        try LibraryStore(libraryRoot: root, modelsRoot: root.appending(path: "Models"))
    }

    static func caughtError(_ body: () async throws -> Void) async -> Error? {
        do {
            try await body()
            return nil
        } catch {
            return error
        }
    }

    static func write(_ text: String, at url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    static func summary(_ store: LibraryStore, _ id: UUID) async throws -> CollectionSummary? {
        try await store.collections().first { $0.id == id }
    }

    // MARK: Migration from v5 (U1)

    @Test func v5LibraryOpensAtV6WithRowsReadableAndFilesMovedToCollections() async throws {
        let root = try Self.root()
        let paths = LibraryPaths(root: root, modelsRoot: root.appending(path: "Models"))
        let collectionID = UUID()
        let jobID = UUID()
        let imageID = UUID()
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let legacyPath = "Projects/\(collectionID.uuidString)/2026-10/\(imageID.uuidString).png"
        let newPath = "Collections/\(collectionID.uuidString)/2026-10/\(imageID.uuidString).png"

        do {
            let queue = try DatabaseQueue(path: paths.database.path)
            try LibraryStore.migrator.migrate(queue, upTo: "v5-lora-source")
            let settings = try JSONCoding.encode(LibraryStoreTests.settings())
            let request = try JSONCoding.encode(LibraryStoreTests.request())
            try await queue.write { db in
                try db.execute(
                    sql: "INSERT INTO project (id, name, is_default, created_at) VALUES (?, 'Default', 1, ?)",
                    arguments: [collectionID.uuidString, now])
                try db.execute(
                    sql: """
                        INSERT INTO job (id, project_id, mode, request, batch_count, seed_policy, status, position)
                        VALUES (?, ?, 't2i', ?, 1, 'random', 'queued', 1)
                        """,
                    arguments: [jobID.uuidString, collectionID.uuidString, request])
                try db.execute(
                    sql: """
                        INSERT INTO image (id, project_id, job_id, media_type, file_path, thumb_path, width, height,
                                           seed, settings, prompt, created_at)
                        VALUES (?, ?, ?, 'image', ?, 'Thumbnails/a.heic', 512, 512, 7, ?, 'a cat', ?)
                        """,
                    arguments: [imageID.uuidString, collectionID.uuidString, jobID.uuidString, legacyPath, settings, now])
            }
        }
        try Self.write("png", at: root.appending(path: legacyPath))

        let store = try Self.open(root)
        let collection = try await store.defaultCollection()
        #expect(collection.id == collectionID)
        #expect(collection.isDefault)
        #expect(try await store.jobs(status: .queued).map(\.id) == [jobID])

        let recent = try await store.recentImages(collectionID: collectionID, limit: 10)
        #expect(recent.map(\.id) == [imageID])
        #expect(recent.first?.filePath == newPath)
        #expect(try Data(contentsOf: root.appending(path: newPath)) == Data("png".utf8))
        #expect(!FileManager.default.fileExists(atPath: root.appending(path: "Projects").path))
        #expect(!FileManager.default.fileExists(atPath: paths.url(relativePath: legacyPath).path))
    }

    @Test func reconcileConvergesWhenAFileIsAlreadyInBothFolders() async throws {
        let root = try Self.root()
        _ = try Self.open(root)
        let folder = UUID().uuidString
        let both = "\(folder)/2026-10/both.png"
        let onlyLegacy = "\(folder)/2026-10/legacy.png"
        try Self.write("legacy-copy", at: root.appending(path: "Projects/\(both)"))
        try Self.write("collections-copy", at: root.appending(path: "Collections/\(both)"))
        try Self.write("moved", at: root.appending(path: "Projects/\(onlyLegacy)"))

        _ = try Self.open(root)
        #expect(try Data(contentsOf: root.appending(path: "Collections/\(both)")) == Data("collections-copy".utf8))
        #expect(try Data(contentsOf: root.appending(path: "Collections/\(onlyLegacy)")) == Data("moved".utf8))
        #expect(!FileManager.default.fileExists(atPath: root.appending(path: "Projects").path))

        // A second open has nothing left to move and must not lose the Collections copy.
        _ = try Self.open(root)
        #expect(try Data(contentsOf: root.appending(path: "Collections/\(both)")) == Data("collections-copy".utf8))
        #expect(try Data(contentsOf: root.appending(path: "Collections/\(onlyLegacy)")) == Data("moved".utf8))
    }

    // MARK: Names (U2, R14)

    @Test func createRejectsBlankAndCaseInsensitiveDuplicateNames() async throws {
        let store = try Self.open(try Self.root())
        let blank = await Self.caughtError { _ = try await store.createCollection(name: "   ") }
        #expect(blank as? LibraryError == .invalidName)

        let defaultClash = await Self.caughtError { _ = try await store.createCollection(name: "default") }
        #expect(defaultClash as? LibraryError == .duplicateCollectionName)

        _ = try await store.createCollection(name: "Work")
        let workClash = await Self.caughtError { _ = try await store.createCollection(name: " WORK ") }
        #expect(workClash as? LibraryError == .duplicateCollectionName)
    }

    @Test func renameToACaseVariantOfItsOwnNameSucceeds() async throws {
        let store = try Self.open(try Self.root())
        let work = try await store.createCollection(name: "work")
        try await store.renameCollection(id: work.id, to: "Work")
        #expect(try await store.collection(id: work.id)?.name == "Work")
    }

    // MARK: Delete (U2, R6-R8)

    @Test func deleteRefusesDefaultNonEmptyAndBusyCollectionsAndAllowsAnEmptyOne() async throws {
        let store = try Self.open(try Self.root())
        let home = try await store.defaultCollection()
        let defaultError = await Self.caughtError { try await store.deleteCollection(id: home.id) }
        #expect(defaultError as? LibraryError == .defaultCollectionCannotBeDeleted)

        let shots = try await store.createCollection(name: "Shots")
        _ = try await store.saveImage(NewImage(
            collectionID: shots.id, jobID: nil, pngData: try TestPNG.make(width: 16, height: 16),
            settings: LibraryStoreTests.settings()))
        let imageError = await Self.caughtError { try await store.deleteCollection(id: shots.id) }
        #expect(imageError as? LibraryError == .collectionHasImages(count: 1))

        let queue = try await store.createCollection(name: "Queue")
        _ = try await store.enqueueJob(
            collectionID: queue.id, request: LibraryStoreTests.request(), batchCount: 1, seedPolicy: "random")
        let jobError = await Self.caughtError { try await store.deleteCollection(id: queue.id) }
        #expect(jobError as? LibraryError == .collectionHasJobs(count: 1))

        let empty = try await store.createCollection(name: "Empty")
        try await store.deleteCollection(id: empty.id)
        #expect(try await store.collection(id: empty.id) == nil)
        #expect(try await store.collection(id: shots.id) != nil)
        #expect(try await store.collection(id: queue.id) != nil)
    }

    // MARK: Queue order (R12)

    @Test func movingAQueuedJobSwapsWithItsNeighbourInTheSameCollectionAndLeavesOthersPut() async throws {
        let store = try Self.open(try Self.root())
        let home = try await store.defaultCollection()
        let other = try await store.createCollection(name: "Other")
        func enqueue(_ collectionID: UUID) async throws -> UUID {
            try await store.enqueueJob(
                collectionID: collectionID, request: LibraryStoreTests.request(), batchCount: 1, seedPolicy: "random").id
        }
        let a1 = try await enqueue(home.id)
        let b1 = try await enqueue(other.id)
        let a2 = try await enqueue(home.id)

        try await store.moveQueuedJob(a2, by: -1)
        #expect(try await store.jobs(status: .queued).map(\.id) == [a2, b1, a1])

        try await store.moveQueuedJob(a2, by: -1)
        #expect(try await store.jobs(status: .queued).map(\.id) == [a2, b1, a1])
    }

    // MARK: Move (U2, R4, R5, KTD3)

    @Test func moveUpdatesCountsAndPagesAndTheFileSurvivesDeletingTheEmptiedSource() async throws {
        let store = try Self.open(try Self.root())
        let home = try await store.defaultCollection()
        let source = try await store.createCollection(name: "Source")
        let saved = try await store.saveImage(NewImage(
            collectionID: source.id, jobID: nil, pngData: try TestPNG.make(width: 16, height: 16),
            settings: LibraryStoreTests.settings()))

        try await store.moveImages(ids: [saved.id], toCollection: home.id)
        #expect(try await Self.summary(store, source.id)?.imageCount == 0)
        #expect(try await Self.summary(store, home.id)?.imageCount == 1)
        #expect(try await store.recentImages(collectionID: source.id, limit: 10).isEmpty)
        #expect(try await store.recentImages(collectionID: home.id, limit: 10).map(\.id) == [saved.id])
        #expect(try await store.recentImages(collectionID: home.id, limit: 10, offset: 1).isEmpty)

        // Moving to the collection it already belongs to changes nothing.
        try await store.moveImages(ids: [saved.id], toCollection: home.id)
        #expect(try await Self.summary(store, home.id)?.imageCount == 1)

        try await store.deleteCollection(id: source.id)
        #expect(try await store.collection(id: source.id) == nil)
        let stored = try await store.image(id: saved.id)
        #expect(stored?.collectionID == home.id)
        #expect(stored?.filePath.hasPrefix("Collections/\(source.id.uuidString)/") == true)
        let file = await store.paths.url(relativePath: try #require(stored?.filePath))
        #expect(FileManager.default.fileExists(atPath: file.path))
    }

    // MARK: Defaults (U2, R9, KTD6)

    @Test func defaultsRoundTripThroughTheStoreAndSurviveReopening() async throws {
        let root = try Self.root()
        let store = try Self.open(root)
        let collection = try await store.createCollection(name: "Portraits")
        let defaults = CollectionDefaults(
            modelID: "krea", width: 768, height: 1024, steps: 6, guidance: 1.5, negativePrompt: "blurry",
            loras: [ImageLoRA(name: "Pixel", sha256: String(repeating: "a", count: 64), weight: 0.8)])

        try await store.setCollectionDefaults(id: collection.id, defaults)
        #expect(try await Self.summary(store, collection.id)?.collection.defaults == defaults)
        #expect(try await Self.summary(try Self.open(root), collection.id)?.collection.defaults == defaults)

        try await store.setCollectionDefaults(id: collection.id, nil)
        #expect(try await Self.summary(store, collection.id)?.collection.defaults == nil)
    }

    @Test func storedDefaultsWithOnlyAModelIDStillDecode() async throws {
        let store = try Self.open(try Self.root())
        let home = try await store.defaultCollection()
        try await store.dbQueue.write { db in
            try db.execute(
                sql: "UPDATE collection SET defaults = ? WHERE id = ?",
                arguments: [#"{"modelID":"m"}"#, home.id.uuidString])
        }

        let stored = try await Self.summary(store, home.id)?.collection.defaults
        #expect(stored?.modelID == "m")
        #expect(stored?.width == nil)
        #expect(stored?.loras == [])
        let decoded = try JSONDecoder().decode(CollectionDefaults.self, from: Data(#"{"modelID":"m"}"#.utf8))
        #expect(decoded == CollectionDefaults(modelID: "m"))
    }
}
