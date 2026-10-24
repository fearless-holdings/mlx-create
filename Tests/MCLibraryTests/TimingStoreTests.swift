import Foundation
import GRDB
import Testing

@testable import MCLibrary

/// Calibration baseline and generation timing storage (KTD5, KTD7). Tests assert which rows a read returns, never measured values.
@Suite struct TimingStoreTests {
    static func makeStore() throws -> LibraryStore {
        let root = try LibraryStoreTests.tempRoot()
        return try LibraryStore(libraryRoot: root, modelsRoot: root.appending(path: "Models"))
    }

    static func key(
        engine: String = "26.10.3", model: String = "krea-2-turbo", width: Int = 512, height: Int = 512,
        steps: Int = 4, loras: Int = 0
    ) -> TimingSampleKey {
        TimingSampleKey(
            engineVersion: engine, modelID: model, width: width, height: height, steps: steps, loraCount: loras)
    }

    static func baseline(engine: String, seconds: Double) -> CalibrationBaseline {
        CalibrationBaseline(
            engineVersion: engine, modelID: "flux2-klein-4b", width: 512, height: 512, steps: 4, seconds: seconds,
            referenceSeconds: 10, measuredAt: Date(timeIntervalSince1970: 1_790_000_000))
    }

    static func sampleCount(_ store: LibraryStore) async throws -> Int {
        try await store.dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM generation_timing") ?? 0
        }
    }

    // MARK: Baseline

    @Test func aBaselineIsInvisibleToAnotherEngineVersion() async throws {
        let store = try Self.makeStore()
        try await store.saveBaseline(Self.baseline(engine: "26.10.3", seconds: 12.5))

        #expect(try await store.baseline(engineVersion: "26.10.3") == Self.baseline(engine: "26.10.3", seconds: 12.5))
        #expect(try await store.baseline(engineVersion: "26.10.4") == nil)
    }

    @Test func savingABaselineAgainForTheSameEngineReplacesIt() async throws {
        let store = try Self.makeStore()
        try await store.saveBaseline(Self.baseline(engine: "26.10.3", seconds: 12.5))
        try await store.saveBaseline(Self.baseline(engine: "26.10.3", seconds: 9))

        #expect(try await store.baseline(engineVersion: "26.10.3") == Self.baseline(engine: "26.10.3", seconds: 9))
    }

    @Test func aSecondEngineBaselineLeavesTheFirstUntouched() async throws {
        let store = try Self.makeStore()
        try await store.saveBaseline(Self.baseline(engine: "26.10.3", seconds: 12.5))
        try await store.saveBaseline(Self.baseline(engine: "26.10.4", seconds: 7))

        #expect(try await store.baseline(engineVersion: "26.10.3") == Self.baseline(engine: "26.10.3", seconds: 12.5))
        #expect(try await store.baseline(engineVersion: "26.10.4") == Self.baseline(engine: "26.10.4", seconds: 7))
    }

    // MARK: Samples

    @Test func samplesForAnotherModelSizeStepsLoRACountOrEngineNeverAppearInAKeyRead() async throws {
        let store = try Self.makeStore()
        let base = Self.key()
        try await store.recordTimingSample(key: base, seconds: 3, at: Date(timeIntervalSince1970: 100))
        let variants = [
            Self.key(engine: "26.10.4"),
            Self.key(model: "flux2-klein-4b"),
            Self.key(width: 1024),
            Self.key(height: 768),
            Self.key(steps: 8),
            Self.key(loras: 1),
        ]
        for variant in variants {
            #expect(try await store.recentTimings(key: variant).isEmpty)
        }
        #expect(try await store.recentTimings(key: base) == [3])
    }

    @Test func aSampleWithAnOlderTimestampStillCountsAsTheNewest() async throws {
        let store = try Self.makeStore()
        let key = Self.key()
        for index in 1...5 {
            try await store.recordTimingSample(key: key, seconds: Double(index), at: Date(timeIntervalSince1970: Double(1000 + index)))
        }
        // The clock stepped backwards: the newest sample carries the oldest timestamp.
        try await store.recordTimingSample(key: key, seconds: 6, at: Date(timeIntervalSince1970: 1))

        #expect(try await store.recentTimings(key: key) == [6, 5, 4, 3, 2])
    }

    @Test func aSampleOfOneKeyDoesNotTrimAnotherKey() async throws {
        let store = try Self.makeStore()
        let busy = Self.key()
        let quiet = Self.key(loras: 2)
        try await store.recordTimingSample(key: quiet, seconds: 40, at: Date(timeIntervalSince1970: 50))
        for index in 0..<6 {
            try await store.recordTimingSample(
                key: busy, seconds: Double(index), at: Date(timeIntervalSince1970: Double(100 + index)))
        }

        #expect(try await store.recentTimings(key: quiet) == [40])
    }

    @Test func aSixthSampleDropsTheOldestAndReadReturnsTheNewestFiveNewestFirst() async throws {
        let store = try Self.makeStore()
        let key = Self.key()
        for index in 1...6 {
            try await store.recordTimingSample(
                key: key, seconds: Double(index), at: Date(timeIntervalSince1970: Double(index)))
        }

        #expect(try await store.recentTimings(key: key) == [6, 5, 4, 3, 2])
        #expect(try await Self.sampleCount(store) == 5)
    }

    @Test func samplesWithTheSameTimestampReadNewestInsertFirst() async throws {
        let store = try Self.makeStore()
        let key = Self.key()
        let same = Date(timeIntervalSince1970: 1_790_000_000)
        try await store.recordTimingSample(key: key, seconds: 1, at: same)
        try await store.recordTimingSample(key: key, seconds: 2, at: same)

        #expect(try await store.recentTimings(key: key) == [2, 1])
    }

    // MARK: Gallery, jobs, FTS and prompt history are unchanged

    @Test func writingSamplesAndABaselineLeavesImagesJobsGalleryHistoryAndSearchUnchanged() async throws {
        let store = try Self.makeStore()
        let home = try await store.defaultCollection()
        var request = LibraryStoreTests.request()
        request.prompt = "a cat on a roof"
        _ = try await store.enqueueJob(collectionID: home.id, request: request, batchCount: 1, seedPolicy: "random")
        _ = try await store.saveImage(
            NewImage(
                collectionID: home.id, jobID: nil, pngData: try TestPNG.make(width: 8, height: 8),
                settings: LibraryStoreTests.settings(prompt: "a cat")))

        var search = GalleryQuery(collectionID: home.id)
        search.search = "cat"
        let before = (
            queued: try await store.jobs(status: .queued),
            images: try await store.recentImages(collectionID: home.id, limit: 50),
            matching: try await store.matchingImageCount(query: search),
            found: try await store.recentImages(query: search, limit: 50),
            facets: try await store.galleryFacets(query: GalleryQuery(collectionID: home.id)),
            prompts: try await store.promptHistory(collectionID: home.id)
        )

        let key = Self.key()
        try await store.recordTimingSample(key: key, seconds: 4, at: Date(timeIntervalSince1970: 10))
        try await store.saveBaseline(Self.baseline(engine: "26.10.3", seconds: 12.5))

        let after = (
            queued: try await store.jobs(status: .queued),
            images: try await store.recentImages(collectionID: home.id, limit: 50),
            matching: try await store.matchingImageCount(query: search),
            found: try await store.recentImages(query: search, limit: 50),
            facets: try await store.galleryFacets(query: GalleryQuery(collectionID: home.id)),
            prompts: try await store.promptHistory(collectionID: home.id)
        )

        #expect(after.queued == before.queued)
        #expect(after.images == before.images)
        #expect(after.matching == before.matching)
        #expect(after.found == before.found)
        #expect(after.facets == before.facets)
        #expect(after.prompts == before.prompts)
        #expect(before.matching == 1)
    }

    // MARK: Migration

    @Test func aLibraryCreatedAtV10OpensAtV11AndTheTimingTablesWork() async throws {
        let root = try LibraryStoreTests.tempRoot()
        let models = root.appending(path: "Models")
        let queue = try DatabaseQueue(path: LibraryPaths(root: root, modelsRoot: models).database.path)
        try LibraryStore.migrator.migrate(queue, upTo: "v10-lora-always-on")

        let store = try LibraryStore(libraryRoot: root, modelsRoot: models)
        #expect(try await store.baseline(engineVersion: "26.10.3") == nil)
        #expect(try await store.recentTimings(key: Self.key()).isEmpty)

        try await store.saveBaseline(Self.baseline(engine: "26.10.3", seconds: 12.5))
        try await store.recordTimingSample(key: Self.key(), seconds: 4, at: Date(timeIntervalSince1970: 10))
        #expect(try await store.recentTimings(key: Self.key()) == [4])
        #expect(try await store.baseline(engineVersion: "26.10.3") == Self.baseline(engine: "26.10.3", seconds: 12.5))
    }
}
