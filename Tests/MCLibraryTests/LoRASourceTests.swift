import CoreGraphics
import Foundation
import GRDB
import ImageIO
import Testing

@testable import MCLibrary

/// The `lora_source` table, the HEIC preview, the v5 migration and the Civitai staging sweep (plan U3, KTD4, KTD5, KTD11).
@Suite struct LoRASourceTests {
    @Test func aV4DatabaseMigratesToV5AndItsRowsStillDecode() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "lora-v4-\(UUID().uuidString)", directoryHint: .isDirectory)
        let models = root.appending(path: "Models", directoryHint: .isDirectory)
        let libraryRoot = root.appending(path: "Library", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: libraryRoot, withIntermediateDirectories: true)
        let queue = try DatabaseQueue(path: LibraryPaths(root: libraryRoot, modelsRoot: models).database.path)
        try LibraryStore.migrator.migrate(queue, upTo: "v4-lora")
        try await queue.write { db in
            try db.execute(
                sql:
                    "INSERT INTO lora (id, name, family, sha256, relative_path, size_bytes, trigger_words, notes, created_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
                arguments: [
                    "old", "Old", "alpha", String(repeating: "a", count: 64), "LoRAs/alpha/aaaaaaaaaa-old.safetensors",
                    7, "[\"sks\"]", nil, Date(timeIntervalSince1970: 1_700_000_000),
                ])
        }

        let store = try LibraryStore(libraryRoot: libraryRoot, modelsRoot: models)

        let loras = try await store.loras()
        #expect(loras.count == 1)
        #expect(loras.first?.name == "Old")
        #expect(loras.first?.variant == nil)
        #expect(loras.first?.triggerWords == ["sks"])
        #expect(try await store.loraSource(loraID: "old") == nil)
        #expect(try await store.dbQueue.read { db in try db.tableExists("lora_source") })
    }

    @Test func deletingALoRAWithASourceRemovesItsSourceRowAndPreview() async throws {
        let fixture = try LoRALibraryTests.makeFixture()
        let file = try LoRALibraryTests.staged(fixture, fill: 40)
        let jpeg = try TestImage.encode(width: 640, height: 480, type: "public.jpeg")
        let added = try LoRALibraryTests.addedRecord(
            try await fixture.store.commitStagedLoRA(
                staged: file.url, sha256: file.sha256, sizeBytes: file.size, family: "alpha", variant: nil, name: "Pixel",
                triggerWords: [], source: LoRALibraryTests.sampleSource(), previewImage: jpeg))
        let preview = await fixture.store.paths.url(relativePath: "Thumbnails/LoRA/\(added.id).heic")
        #expect(FileManager.default.fileExists(atPath: preview.path))

        #expect(try await fixture.store.deleteLoRA(id: added.id) == 0)

        #expect(try await fixture.store.loraSource(loraID: added.id) == nil)
        #expect(!FileManager.default.fileExists(atPath: preview.path))
        #expect(!fixture.store.loraFileExists(added))
        #expect(try await fixture.store.loras().isEmpty)
    }

    @Test func aJPEGPreviewIsStoredAsAHEICThumbnailOutsideLoRAs() async throws {
        let fixture = try LoRALibraryTests.makeFixture()
        let file = try LoRALibraryTests.staged(fixture, fill: 41)
        let jpeg = try TestImage.encode(width: 1024, height: 768, type: "public.jpeg")

        let added = try LoRALibraryTests.addedRecord(
            try await fixture.store.commitStagedLoRA(
                staged: file.url, sha256: file.sha256, sizeBytes: file.size, family: "alpha", variant: nil, name: "Pixel",
                triggerWords: [], source: LoRALibraryTests.sampleSource(), previewImage: jpeg))

        let stored = try #require(try await fixture.store.loraSource(loraID: added.id))
        let relative = try #require(stored.previewRelativePath)
        #expect(relative == "Thumbnails/LoRA/\(added.id).heic")
        #expect(!relative.hasPrefix("LoRAs/"))
        let previewURL = await fixture.store.paths.url(relativePath: relative)
        let data = try Data(contentsOf: previewURL)
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        #expect(CGImageSourceGetType(source) as String? == "public.heic")
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(max(image.width, image.height) == 512)
    }

    @Test func aPreviewThatCannotBeDecodedLeavesTheLoRAStoredWithoutAPreview() async throws {
        let fixture = try LoRALibraryTests.makeFixture()
        let file = try LoRALibraryTests.staged(fixture, fill: 43)

        let added = try LoRALibraryTests.addedRecord(
            try await fixture.store.commitStagedLoRA(
                staged: file.url, sha256: file.sha256, sizeBytes: file.size, family: "alpha", variant: nil, name: "Pixel",
                triggerWords: [], source: LoRALibraryTests.sampleSource(), previewImage: Data("not an image".utf8)))

        #expect(fixture.store.loraFileExists(added))
        let stored = try #require(try await fixture.store.loraSource(loraID: added.id))
        #expect(stored.previewRelativePath == nil)
        #expect(stored.civitaiVersionID == 202)
        let previews = await fixture.store.paths.loraPreviewDirectory
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: previews.path)) ?? []).isEmpty)
    }

    @Test func aLeftoverCivitaiStagingFileIsRemovedAtTheNextOpen() async throws {
        let fixture = try LoRALibraryTests.makeFixture()
        let leftover = fixture.models.appending(path: ".partial/civitai/\(UUID().uuidString).partial")
        try FileManager.default.createDirectory(at: leftover.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("half".utf8).write(to: leftover)
        let libraryRoot = fixture.models.deletingLastPathComponent().appending(path: "Library", directoryHint: .isDirectory)

        _ = try LibraryStore(libraryRoot: libraryRoot, modelsRoot: fixture.models)

        #expect(!FileManager.default.fileExists(atPath: leftover.path))
    }

    @Test func aStoredPreviewPathOutsideThePreviewFolderIsNeverDeleted() async throws {
        let fixture = try LoRALibraryTests.makeFixture()
        let record = try await LoRALibraryTests.importedAlpha(fixture, fill: 42)
        let keep = fixture.models.appending(path: "keep.heic")
        try Data("keep".utf8).write(to: keep)
        let tampered = LoRALibraryTests.sampleSource(previewRelativePath: "../Models/keep.heic")
        try await fixture.store.dbQueue.write { db in try LoRASourceRow(loraID: record.id, source: tampered).insert(db) }

        #expect(try await fixture.store.deleteLoRA(id: record.id) == 0)

        #expect(FileManager.default.fileExists(atPath: keep.path))
        #expect(try await fixture.store.loras().isEmpty)
    }
}
