import Foundation
import GRDB
import Testing
@testable import MCLibrary

@Suite struct LoRATypesTests {
    private static func scratchRoot() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "lora-types-\(UUID().uuidString)")
    }

    private static let createdAt = Date(timeIntervalSince1970: 1_790_000_200)

    private static func hash(_ digit: Character) -> String {
        String(repeating: String(digit), count: 64)
    }

    @Test func jobRequestSavedBeforeLoRASupportDecodesWithoutStack() async throws {
        let root = Self.scratchRoot()
        let store = try LibraryStore(libraryRoot: root, modelsRoot: root.appending(path: "Models", directoryHint: .isDirectory))
        let project = try await store.defaultProject()
        let original = JobRequest(modelID: "krea-2-turbo", family: "krea-2", prompt: "a red fox", width: 512, height: 512, steps: 8)

        // The JSON shape written before this change: the encoded request with no `loras` key.
        let encoded = try JSONEncoder().encode(original)
        var object = try #require(try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "loras")
        let legacy = String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)

        try await store.dbQueue.write { db in
            try db.execute(
                sql: "INSERT INTO job (id, project_id, mode, request, batch_count, seed_policy, status, position) VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
                arguments: [UUID().uuidString, project.id.uuidString, Job.textToImageMode, legacy, 1, "fixed", JobStatus.queued.rawValue, 1])
        }

        let queued = try #require(try await store.jobs(status: .queued).first)
        #expect(queued.request == original, "a pre-LoRA request is read back, not replaced by JobRequest.unreadable")
        #expect(queued.request.loras == nil)
    }

    @Test func imageSettingsWithoutLoRAsDecodeUnchanged() throws {
        let settings = ImageSettings(
            prompt: "a red fox", modelID: "krea-2-turbo", requestedWidth: 512, requestedHeight: 512,
            seed: 42, width: 512, height: 512, steps: 8)

        let encoded = try JSONEncoder().encode(settings)
        let object = try #require(try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        #expect(object["loras"] == nil)

        let decoded = try JSONDecoder().decode(ImageSettings.self, from: encoded)
        #expect(decoded == settings)
        #expect(decoded.loras == nil)
    }

    @Test func jobRequestStackRoundTripsThroughTheStore() async throws {
        let root = Self.scratchRoot()
        let models = root.appending(path: "Models", directoryHint: .isDirectory)
        let store = try LibraryStore(libraryRoot: root, modelsRoot: models)
        let project = try await store.defaultProject()
        let stack = [
            LoRAStackEntry(id: "lora-a", name: "Pixel art", sha256: Self.hash("a"), weight: 0.8,
                           relativePath: "LoRAs/krea-2/aaaaaaaaaa-pixel-art.safetensors"),
            LoRAStackEntry(id: "lora-b", name: "Film grain", sha256: Self.hash("b"), weight: -1.25,
                           relativePath: "LoRAs/krea-2/bbbbbbbbbb-film-grain.safetensors"),
            LoRAStackEntry(id: "lora-c", name: "Portrait", sha256: Self.hash("c"), weight: 2,
                           relativePath: "LoRAs/krea-2/cccccccccc-portrait.safetensors"),
        ]
        let request = JobRequest(modelID: "krea-2-turbo", family: "krea-2", prompt: "a fox", width: 512, height: 512, loras: stack)
        for entry in stack {
            let file = models.appending(path: entry.relativePath)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data().write(to: file)
            let record = LoRARecord(
                id: entry.id, name: entry.name, family: "krea-2", sha256: entry.sha256, relativePath: entry.relativePath,
                sizeBytes: 0, triggerWords: [], notes: nil, createdAt: Self.createdAt)
            try await store.dbQueue.write { db in try record.insert(db) }
        }

        let enqueued = try await store.enqueueJob(projectID: project.id, request: request, batchCount: 1, seedPolicy: "fixed")

        let queued = try #require(try await store.jobs(status: .queued).first)
        #expect(queued == enqueued)
        let loras = try #require(queued.request.loras)
        #expect(loras.map(\.name) == ["Pixel art", "Film grain", "Portrait"])
        #expect(loras.map(\.sha256) == stack.map(\.sha256))
        #expect(loras.map(\.weight) == [0.8, -1.25, 2])
        #expect(loras.map(\.relativePath) == stack.map(\.relativePath))
    }

    @Test func loraRecordRoundTripsAndRejectsDuplicateHash() async throws {
        let root = Self.scratchRoot()
        let store = try LibraryStore(libraryRoot: root, modelsRoot: root.appending(path: "Models", directoryHint: .isDirectory))
        let record = LoRARecord(
            id: "lora-a", name: "Pixel art", family: "krea-2", sha256: Self.hash("a"),
            relativePath: "LoRAs/krea-2/aaaaaaaaaa-pixel-art.safetensors", sizeBytes: 1_234,
            triggerWords: ["pixel art", "sks"], notes: nil, createdAt: Self.createdAt)

        try await store.dbQueue.write { db in try record.insert(db) }

        let fetched = try await store.dbQueue.read { db in try LoRARecord.fetchOne(db, key: "lora-a") }
        #expect(fetched == record)
        #expect(fetched?.triggerWords == ["pixel art", "sks"])

        let duplicate = LoRARecord(
            id: "lora-copy", name: "Same file", family: "krea-2", sha256: Self.hash("a"),
            relativePath: "LoRAs/krea-2/aaaaaaaaaa-copy.safetensors", sizeBytes: 1_234,
            triggerWords: [], notes: "second import", createdAt: Self.createdAt)
        var duplicateRejected = false
        do {
            try await store.dbQueue.write { db in try duplicate.insert(db) }
        } catch {
            duplicateRejected = true
        }
        #expect(duplicateRejected, "sha256 is unique")
    }
}
