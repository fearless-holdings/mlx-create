import Foundation
import GRDB
import Testing

@testable import MCLibrary

/// Prompt history (D39): recorded when a job is queued, per collection, deduplicated and capped.
@Suite struct PromptHistoryTests {
    static func makeStore() throws -> LibraryStore {
        let root = try LibraryStoreTests.tempRoot()
        return try LibraryStore(libraryRoot: root, modelsRoot: root.appending(path: "Models"))
    }

    @discardableResult
    static func enqueue(
        _ store: LibraryStore, _ collectionID: UUID, prompt: String, negative: String? = nil
    ) async throws -> Job {
        var request = LibraryStoreTests.request()
        request.prompt = prompt
        request.negativePrompt = negative
        return try await store.enqueueJob(
            collectionID: collectionID, request: request, batchCount: 1, seedPolicy: "random")
    }

    @Test func aQueuedJobRecordsItsPromptAndNegativePrompt() async throws {
        let store = try Self.makeStore()
        let home = try await store.defaultCollection()
        try await Self.enqueue(store, home.id, prompt: "a fox", negative: "blurry")

        let history = try await store.promptHistory(collectionID: home.id)
        #expect(history.map(\.prompt) == ["a fox"])
        #expect(history.map(\.negativePrompt) == ["blurry"])
    }

    @Test func repeatingAPromptMovesItToTheTopInsteadOfAddingARow() async throws {
        let store = try Self.makeStore()
        let home = try await store.defaultCollection()
        try await Self.enqueue(store, home.id, prompt: "a fox", negative: "blurry")
        try await Self.enqueue(store, home.id, prompt: "a cat")
        try await Self.enqueue(store, home.id, prompt: "a fox", negative: "blurry")

        let history = try await store.promptHistory(collectionID: home.id)
        #expect(history.map(\.prompt) == ["a fox", "a cat"])
    }

    @Test func aDifferentNegativePromptIsADifferentEntry() async throws {
        let store = try Self.makeStore()
        let home = try await store.defaultCollection()
        try await Self.enqueue(store, home.id, prompt: "a fox", negative: "blurry")
        try await Self.enqueue(store, home.id, prompt: "a fox", negative: "dark")

        #expect(
            try await store.promptHistory(collectionID: home.id).map(\.negativePrompt) == [
                "dark", "blurry",
            ])
    }

    @Test func aMissingNegativePromptEqualsAnEmptyOne() async throws {
        let store = try Self.makeStore()
        let home = try await store.defaultCollection()
        try await Self.enqueue(store, home.id, prompt: "a fox", negative: nil)
        try await Self.enqueue(store, home.id, prompt: "a fox", negative: "")

        let history = try await store.promptHistory(collectionID: home.id)
        #expect(history.count == 1)
        #expect(history.first?.negativePrompt == "")
    }

    @Test func eachCollectionKeepsItsNewestHundredAndOthersAreUntouched() async throws {
        let store = try Self.makeStore()
        let home = try await store.defaultCollection()
        let other = try await store.createCollection(name: "Other")
        try await Self.enqueue(store, other.id, prompt: "kept elsewhere")
        for index in 0..<101 { try await Self.enqueue(store, home.id, prompt: "prompt \(index)") }

        let history = try await store.promptHistory(collectionID: home.id)
        #expect(history.count == 100)
        #expect(history.first?.prompt == "prompt 100")
        #expect(history.last?.prompt == "prompt 1")
        #expect(
            try await store.promptHistory(collectionID: other.id).map(\.prompt) == [
                "kept elsewhere"
            ])
    }

    @Test func historySurvivesCancelledJobsAndDeletedImages() async throws {
        let store = try Self.makeStore()
        let home = try await store.defaultCollection()
        let cancelled = try await Self.enqueue(store, home.id, prompt: "never rendered")
        try await store.setJobStatus(cancelled.id, .cancelled)
        let failed = try await Self.enqueue(store, home.id, prompt: "engine failed")
        try await store.setJobStatus(
            failed.id, .failed, failure: JobFailure(message: "x", detail: "y", retryable: true))

        #expect(
            try await store.promptHistory(collectionID: home.id).map(\.prompt) == [
                "engine failed", "never rendered",
            ])
    }

    @Test func aJobRejectedForAnUnavailableLoRARecordsNothing() async throws {
        let store = try Self.makeStore()
        let home = try await store.defaultCollection()
        let ghost = LoRAStackEntry(
            id: "ghost", name: "Ghost", sha256: String(repeating: "c", count: 64), weight: 1,
            relativePath: "LoRAs/alpha/cccccccccc-ghost.safetensors")
        var request = LibraryStoreTests.request()
        request.prompt = "with a missing lora"
        request.loras = [ghost]
        await #expect(throws: LibraryError.self) {
            try await store.enqueueJob(
                collectionID: home.id, request: request, batchCount: 1, seedPolicy: "random")
        }

        #expect(try await store.promptHistory(collectionID: home.id).isEmpty)
    }

    @Test func deletingACollectionDeletesItsHistoryOnly() async throws {
        let store = try Self.makeStore()
        let home = try await store.defaultCollection()
        let doomed = try await store.createCollection(name: "Doomed")
        let job = try await Self.enqueue(store, doomed.id, prompt: "goes away")
        try await store.setJobStatus(job.id, .cancelled)
        try await Self.enqueue(store, home.id, prompt: "stays")

        try await store.deleteCollection(id: doomed.id)

        #expect(try await store.promptHistory(collectionID: doomed.id).isEmpty)
        #expect(try await store.promptHistory(collectionID: home.id).map(\.prompt) == ["stays"])
    }

    @Test func aV7DatabaseOpensWithAnEmptyHistoryAndEntriesPersistAcrossOpens() async throws {
        let root = try LibraryStoreTests.tempRoot()
        let models = root.appending(path: "Models")
        let queue = try DatabaseQueue(
            path: LibraryPaths(root: root, modelsRoot: models).database.path)
        try LibraryStore.migrator.migrate(queue, upTo: "v7-gallery-filters")

        let first = try LibraryStore(libraryRoot: root, modelsRoot: models)
        let home = try await first.defaultCollection()
        #expect(try await first.promptHistory(collectionID: home.id).isEmpty)
        try await Self.enqueue(first, home.id, prompt: "persisted")

        let second = try LibraryStore(libraryRoot: root, modelsRoot: models)
        #expect(
            try await second.promptHistory(collectionID: home.id).map(\.prompt) == ["persisted"])
    }
}
