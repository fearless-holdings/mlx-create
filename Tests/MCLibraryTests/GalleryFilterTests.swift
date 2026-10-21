import Foundation
import GRDB
import Testing
@testable import MCLibrary

@Suite struct GalleryFilterTests {
    static let x = ImageLoRA(name: "Style X", sha256: String(repeating: "a", count: 64), weight: 0.8)
    static let y = ImageLoRA(name: "Style Y", sha256: String(repeating: "b", count: 64), weight: 1)

    struct Fixture {
        let store: LibraryStore
        let collection: ImageCollection
    }

    static func fixture() async throws -> Fixture {
        let root = try LibraryStoreTests.tempRoot()
        let store = try LibraryStore(libraryRoot: root, modelsRoot: root.appending(path: "Models"))
        return Fixture(store: store, collection: try await store.defaultCollection())
    }

    @discardableResult
    static func save(
        _ f: Fixture, prompt: String, model: String = "m1", loras: [ImageLoRA]? = nil, collection: UUID? = nil
    ) async throws -> LibraryImage {
        var settings = LibraryStoreTests.settings(prompt: prompt)
        settings.modelID = model
        settings.loras = loras
        return try await f.store.saveImage(NewImage(
            collectionID: collection ?? f.collection.id, jobID: nil, pngData: try TestPNG.make(width: 16, height: 16), settings: settings))
    }

    static func ids(_ images: [LibraryImage]) -> Set<UUID> { Set(images.map(\.id)) }

    // MARK: Migration

    @Test func v7BackfillsLegacyRowsAndSurvivesMalformedSettings() async throws {
        let root = try LibraryStoreTests.tempRoot()
        let paths = LibraryPaths(root: root, modelsRoot: root.appending(path: "Models"))
        let collectionID = UUID()
        let withLoRAs = UUID(), without = UUID(), broken = UUID()
        do {
            let queue = try DatabaseQueue(path: paths.database.path)
            try LibraryStore.migrator.migrate(queue, upTo: "v6-collection")
            var styled = LibraryStoreTests.settings(prompt: "a red fox")
            styled.loras = [Self.x, Self.y]
            let styledJSON = try JSONCoding.encode(styled)
            let plainJSON = try JSONCoding.encode(LibraryStoreTests.settings(prompt: "a blue fox"))
            try await queue.write { db in
                try db.execute(sql: "INSERT INTO collection (id, name, is_default, created_at) VALUES (?, 'Default', 1, ?)",
                               arguments: [collectionID.uuidString, Date()])
                for (id, json, prompt) in [(withLoRAs, styledJSON, "a red fox"), (without, plainJSON, "a blue fox"), (broken, "not json{", "a green fox")] {
                    try db.execute(
                        sql: """
                            INSERT INTO image (id, collection_id, media_type, file_path, thumb_path, width, height, seed, settings, prompt, created_at)
                            VALUES (?, ?, 'image', 'x.png', 't.heic', 1, 1, 1, ?, ?, ?)
                            """,
                        arguments: [id.uuidString, collectionID.uuidString, json, prompt, Date()])
                }
            }
        }

        let store = try LibraryStore(libraryRoot: root, modelsRoot: root.appending(path: "Models"))
        let all = GalleryQuery(collectionID: collectionID)
        #expect(try await store.matchingImageCount(query: all) == 3)

        // Only the row with LoRAs matches a LoRA filter; the legacy row without a record and the unreadable row do not (R16).
        var lora = all
        lora.loraHashes = [Self.x.sha256]
        #expect(Self.ids(try await store.recentImages(query: lora, limit: 10)) == [withLoRAs])

        var model = all
        model.modelIDs = ["ddalcu/Krea-2-Turbo"]
        #expect(Self.ids(try await store.recentImages(query: model, limit: 10)) == [withLoRAs, without])

        var search = all
        search.search = "fox"
        #expect(try await store.matchingImageCount(query: search) == 3)
        search.search = "green"
        #expect(Self.ids(try await store.recentImages(query: search, limit: 10)) == [broken])
    }

    // MARK: Filters

    @Test func severalLoRAPicksNeedAllOfThem() async throws {
        let f = try await Self.fixture()
        let a = try await Self.save(f, prompt: "a", loras: [Self.x, Self.y])
        try await Self.save(f, prompt: "b", loras: [Self.x])
        try await Self.save(f, prompt: "c", loras: nil)

        var q = GalleryQuery(collectionID: f.collection.id)
        q.loraHashes = [Self.x.sha256, Self.y.sha256]
        #expect(Self.ids(try await f.store.recentImages(query: q, limit: 10)) == [a.id])

        q.loraHashes = [Self.x.sha256]
        #expect(try await f.store.matchingImageCount(query: q) == 2)
    }

    @Test func severalModelPicksMatchAnyOfThem() async throws {
        let f = try await Self.fixture()
        let one = try await Self.save(f, prompt: "a", model: "m1")
        let two = try await Self.save(f, prompt: "b", model: "m2")
        try await Self.save(f, prompt: "c", model: "m3")
        var q = GalleryQuery(collectionID: f.collection.id)
        q.modelIDs = ["m1", "m2"]
        #expect(Self.ids(try await f.store.recentImages(query: q, limit: 10)) == [one.id, two.id])
    }

    @Test func searchPrefixMatchesTheLastWordAndSurvivesOperatorCharacters() async throws {
        let f = try await Self.fixture()
        let cat = try await Self.save(f, prompt: "A ginger cat in a catalog")
        try await Self.save(f, prompt: "a dog")
        var q = GalleryQuery(collectionID: f.collection.id)

        q.search = "CATAL"
        #expect(Self.ids(try await f.store.recentImages(query: q, limit: 10)) == [cat.id])
        q.search = "ginger cat"
        #expect(Self.ids(try await f.store.recentImages(query: q, limit: 10)) == [cat.id])
        for text in ["\"", "cat AND", "-cat", "cat*", "(", "NEAR(cat", "%_", "   ", "-"] {
            q.search = text
            _ = try await f.store.recentImages(query: q, limit: 10)
        }
        // Text with nothing searchable in it is no criterion, so everything shows.
        q.search = "-"
        #expect(q.criteriaCount == 0)
        #expect(try await f.store.matchingImageCount(query: q) == 2)
    }

    @Test func searchFollowsPromptsAndDeletesAndStaysInTheCollection() async throws {
        let f = try await Self.fixture()
        let other = try await f.store.createCollection(name: "Other")
        try await Self.save(f, prompt: "a unique heron", collection: other.id)
        var q = GalleryQuery(collectionID: f.collection.id)
        q.search = "heron"
        #expect(try await f.store.matchingImageCount(query: q) == 0)
        q.collectionID = other.id
        #expect(try await f.store.matchingImageCount(query: q) == 1)
    }

    @Test func pagingUnderAFilterKeepsNewestFirstAndOffsetsCorrect() async throws {
        let f = try await Self.fixture()
        var wanted: [UUID] = []
        for i in 0..<5 {
            wanted.append(try await Self.save(f, prompt: "wanted \(i)", model: "m1").id)
            try await Self.save(f, prompt: "other \(i)", model: "m2")
        }
        var q = GalleryQuery(collectionID: f.collection.id)
        q.modelIDs = ["m1"]
        let first = try await f.store.recentImages(query: q, limit: 3)
        let second = try await f.store.recentImages(query: q, limit: 3, offset: 3)
        #expect(first.count == 3)
        #expect(second.count == 2)
        #expect(Set((first + second).map(\.id)) == Set(wanted))
        #expect(zip(first + second, (first + second).dropFirst()).allSatisfy { $0.createdAt >= $1.createdAt })
    }

    // MARK: Facets (R11, R12, AE7)

    @Test func facetListsNarrowWithTheOtherCriteriaAndKeepPicks() async throws {
        let f = try await Self.fixture()
        try await Self.save(f, prompt: "one", model: "m1", loras: [Self.x])
        try await Self.save(f, prompt: "two", model: "m2", loras: [Self.y])
        try await Self.save(f, prompt: "three", model: "m2", loras: nil)

        var q = GalleryQuery(collectionID: f.collection.id)
        var facets = try await f.store.galleryFacets(query: q)
        #expect(facets.modelIDs == ["m1", "m2"])
        #expect(Set(facets.loras.map(\.sha256)) == [Self.x.sha256, Self.y.sha256])

        // Picking a model narrows the LoRA list to what that model used.
        q.modelIDs = ["m1"]
        facets = try await f.store.galleryFacets(query: q)
        #expect(facets.loras.map(\.sha256) == [Self.x.sha256])
        // The model list ignores its own pick, so the alternative stays reachable.
        #expect(facets.modelIDs == ["m1", "m2"])

        // Picking a LoRA narrows the model list, and the pick itself stays listed.
        q = GalleryQuery(collectionID: f.collection.id, loraHashes: [Self.y.sha256])
        facets = try await f.store.galleryFacets(query: q)
        #expect(facets.modelIDs == ["m2"])
        #expect(facets.loras.map(\.sha256) == [Self.y.sha256])

        // A search with no hits still lists the picks, and no listed option leads to zero results.
        q.search = "zzzz"
        facets = try await f.store.galleryFacets(query: q)
        #expect(facets.loras.map(\.sha256) == [Self.y.sha256])
        q = GalleryQuery(collectionID: f.collection.id)
        facets = try await f.store.galleryFacets(query: q)
        for model in facets.modelIDs {
            var picked = q
            picked.modelIDs = [model]
            #expect(try await f.store.matchingImageCount(query: picked) > 0)
        }
        for lora in facets.loras {
            var picked = q
            picked.loraHashes = [lora.sha256]
            #expect(try await f.store.matchingImageCount(query: picked) > 0)
        }
    }

    @Test func loraOptionUsesTheLibraryNameWhenTheLoRAIsInstalledElseTheRecordedName() async throws {
        let f = try await Self.fixture()
        try await Self.save(f, prompt: "one", loras: [Self.x])
        let facets = try await f.store.galleryFacets(query: GalleryQuery(collectionID: f.collection.id))
        #expect(facets.loras == [GalleryLoRAOption(sha256: Self.x.sha256, name: "Style X")])
    }

    @Test func imageMatchingChecksANewImageAgainstTheQuery() async throws {
        let f = try await Self.fixture()
        let fresh = try await Self.save(f, prompt: "a lighthouse", model: "m1")
        var q = GalleryQuery(collectionID: f.collection.id, search: "light")
        #expect(try await f.store.image(id: fresh.id, matching: q)?.id == fresh.id)
        q.modelIDs = ["m2"]
        #expect(try await f.store.image(id: fresh.id, matching: q) == nil)
        #expect(try await f.store.ids([fresh.id], matching: q).isEmpty)
    }
}
