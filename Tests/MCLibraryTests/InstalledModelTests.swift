import Foundation
import GRDB
import Testing

@testable import MCLibrary

@Suite struct InstalledModelTests {
    private static let installedAt = Date(timeIntervalSince1970: 1_790_000_100)
    private static let acceptedAt = Date(timeIntervalSince1970: 1_790_000_000)

    private static func record(_ id: String, installedAt: Date = installedAt) -> InstalledModelRecord {
        InstalledModelRecord(
            modelID: id, family: "krea-2-turbo", repo: "org/\(id)",
            revision: String(repeating: "ab", count: 20), catalogSequence: 3,
            files: [
                .init(path: "model.safetensors", size: 4096, sha256: String(repeating: "1", count: 64)),
                .init(path: "config.json", size: 64, sha256: String(repeating: "2", count: 64)),
            ],
            licenseID: "krea-2-community-license", licenseVersion: "1 (June 22, 2026)",
            acceptedAt: acceptedAt, installedAt: installedAt)
    }

    private static func scratchRoot() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "installed-\(UUID().uuidString)")
    }

    /// 1 when `installed_model` exists. Read from `sqlite_master` directly: GRDB's schema cache on a connection opened
    /// before the migration can report a stale table list.
    private static func tableCount(_ db: Database) throws -> Int {
        try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = 'installed_model'") ?? 0
    }

    @Test func recordedInstallReadsBackWithItsManifestAndLicense() async throws {
        let store = try LibraryStore(libraryRoot: Self.scratchRoot(), modelsRoot: Self.scratchRoot())
        let model = Self.record("krea-2-turbo-mixed-4-8")

        try await store.recordInstalledModel(model)

        #expect(try await store.installedModel(id: "krea-2-turbo-mixed-4-8") == model)
        #expect(try await store.installedModels() == [model])
        #expect(try await store.installedModel(id: "not-installed") == nil)
    }

    @Test func installedModelsListOldestInstallFirst() async throws {
        let store = try LibraryStore(libraryRoot: Self.scratchRoot(), modelsRoot: Self.scratchRoot())
        try await store.recordInstalledModel(Self.record("later", installedAt: Self.installedAt.addingTimeInterval(60)))
        try await store.recordInstalledModel(Self.record("earlier", installedAt: Self.installedAt))

        #expect(try await store.installedModels().map(\.modelID) == ["earlier", "later"])
    }

    @Test func recordingAModelAgainReplacesItsRow() async throws {
        let store = try LibraryStore(libraryRoot: Self.scratchRoot(), modelsRoot: Self.scratchRoot())
        try await store.recordInstalledModel(Self.record("model-a"))
        let reinstalled = Self.record("model-a", installedAt: Self.installedAt.addingTimeInterval(600))

        try await store.recordInstalledModel(reinstalled)

        #expect(try await store.installedModels() == [reinstalled], "a folder re-installed after deletion is recorded afresh")
    }

    @Test func recordSurvivesReopeningTheLibrary() async throws {
        let root = Self.scratchRoot()
        let model = Self.record("model-a")
        try await LibraryStore(libraryRoot: root, modelsRoot: root.appending(path: "Models")).recordInstalledModel(model)

        #expect(try await LibraryStore(libraryRoot: root, modelsRoot: root.appending(path: "Models")).installedModels() == [model])
    }

    @Test func v3MigrationAppliesOverV2DataAndKeepsJobsAndImages() async throws {
        let root = Self.scratchRoot()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let queue = try DatabaseQueue(path: LibraryPaths(root: root, modelsRoot: root.appending(path: "Models")).database.path)
        try LibraryStore.migrator.migrate(queue, upTo: "v2-job-failure")
        let collectionID = UUID().uuidString
        let jobID = UUID().uuidString
        let imageID = UUID().uuidString
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        try await queue.write { db in
            try db.execute(
                sql: "INSERT INTO project (id, name, is_default, created_at) VALUES (?, 'Default', 1, ?)",
                arguments: [collectionID, now])
            try db.execute(
                sql: """
                    INSERT INTO job (id, project_id, mode, request, batch_count, seed_policy, status, position)
                    VALUES (?, ?, 't2i', '{}', 1, 'random', 'queued', 1)
                    """,
                arguments: [jobID, collectionID])
            try db.execute(
                sql: """
                    INSERT INTO image (id, project_id, job_id, media_type, file_path, thumb_path, width, height,
                                       seed, settings, prompt, created_at)
                    VALUES (?, ?, ?, 'image', 'Projects/a.png', 'Thumbnails/a.heic', 512, 512, 7, '{}', 'p', ?)
                    """,
                arguments: [imageID, collectionID, jobID, now])
        }
        #expect(try await queue.read { db in try Self.tableCount(db) } == 0, "v3 is not applied yet")

        let store = try LibraryStore(libraryRoot: root, modelsRoot: root.appending(path: "Models"))

        let counts = try await queue.read { db in
            (
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM job WHERE id = ?", arguments: [jobID]) ?? 0,
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM image WHERE id = ?", arguments: [imageID]) ?? 0,
                try Self.tableCount(db) == 1
            )
        }
        #expect(counts.0 == 1, "the queued job survives the migration")
        #expect(counts.1 == 1, "the image survives the migration")
        #expect(counts.2, "the installed_model table exists after v3")
        #expect(try await store.installedModels().isEmpty)
    }
}
