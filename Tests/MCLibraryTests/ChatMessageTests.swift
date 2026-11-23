import Foundation
import GRDB
import Testing

@testable import MCLibrary

/// Chat-mode messages (D55, KTD8): per-collection rows with a `kind` plus a JSON `body`, paged backwards by id and
/// updatable in place. A row this build cannot decode is skipped, never thrown.
@Suite struct ChatMessageTests {
    static func makeStore() throws -> LibraryStore {
        let root = try LibraryStoreTests.tempRoot()
        return try LibraryStore(libraryRoot: root, modelsRoot: root.appending(path: "Models"))
    }

    /// One of every body kind, in the order they are appended.
    static func bodies(jobID: UUID) -> [ChatMessageBody] {
        [
            .userText("paint a fox"),
            .agentText("A fox it is."),
            .question(ChatQuestion(text: "Which size?", suggestions: ["1:1", "16:9"], chosen: "16:9")),
            .result(ChatResult(text: "On it.", jobID: jobID)),
            .download(
                ChatDownload(
                    text: "This needs a model.",
                    items: [
                        ChatDownloadItem(
                            kind: .model, id: "krea-2-turbo-mixed-4-8", name: "Krea 2 Turbo", sizeBytes: 100)
                    ],
                    state: .failed(message: "disk full"), pendingRequest: "paint a fox")),
            .adultNotice(ChatAdultNotice(request: "a fox, adult", resolved: true)),
            .miss(ChatMiss(text: "No ears.", fixRequest: "add ears", used: true)),
            .error(ChatFailure(text: "The engine failed.", retryRequest: "paint a fox")),
        ]
    }

    @Test func appendedMessagesGetIncreasingIDsAndEveryKindRoundTrips() async throws {
        let store = try Self.makeStore()
        let home = try await store.defaultCollection()
        let job = try await store.enqueueJob(
            collectionID: home.id, request: LibraryStoreTests.request(), batchCount: 1, seedPolicy: "random")
        let bodies = Self.bodies(jobID: job.id)

        for body in bodies {
            let record = try await store.appendChatMessage(collectionID: home.id, author: .agent, body: body)
            #expect(record.body == body)
        }

        let messages = try await store.chatMessages(collectionID: home.id, limit: 20)
        #expect(messages.map(\.id) == Array(1...Int64(bodies.count)))
        #expect(messages.map(\.body) == bodies)
        #expect(messages.map(\.jobID) == bodies.map(\.jobID))
        #expect(messages.first { $0.id == 4 }?.jobID == job.id)
    }

    @Test func readsPageBackwardsFromTheNewest() async throws {
        let store = try Self.makeStore()
        let home = try await store.defaultCollection()
        for index in 1...5 {
            try await store.appendChatMessage(collectionID: home.id, author: .user, body: .userText("m\(index)"))
        }

        let newest = try await store.chatMessages(collectionID: home.id, limit: 3)
        #expect(newest.map(\.id) == [3, 4, 5])
        let older = try await store.chatMessages(collectionID: home.id, limit: 3, before: 4)
        #expect(older.map(\.id) == [1, 2, 3])
        let all = try await store.chatMessages(collectionID: home.id, limit: 10, before: 4)
        #expect(all.map(\.id) == [1, 2, 3])
        #expect(try await store.chatMessages(collectionID: home.id, limit: 10, before: 1).isEmpty)
    }

    @Test func anUpdateRewritesKindBodyAndJobID() async throws {
        let store = try Self.makeStore()
        let home = try await store.defaultCollection()
        let first = try await store.enqueueJob(
            collectionID: home.id, request: LibraryStoreTests.request(), batchCount: 1, seedPolicy: "random")
        let second = try await store.enqueueJob(
            collectionID: home.id, request: LibraryStoreTests.request(), batchCount: 1, seedPolicy: "random")
        let record = try await store.appendChatMessage(
            collectionID: home.id, author: .agent, body: .result(ChatResult(text: "On it.", jobID: first.id)))
        #expect(try await store.chatMessage(jobID: first.id)?.id == record.id)

        try await store.updateChatMessage(id: record.id, body: .agentText("Done."))
        #expect(try await store.chatMessage(jobID: first.id) == nil)
        let updated = try #require(try await store.chatMessages(collectionID: home.id, limit: 5).first)
        #expect(updated.body == .agentText("Done."))
        #expect(updated.jobID == nil)

        try await store.updateChatMessage(id: record.id, body: .result(ChatResult(text: "Again.", jobID: second.id)))
        #expect(try await store.chatMessage(jobID: second.id)?.body == .result(ChatResult(text: "Again.", jobID: second.id)))

        await #expect(throws: LibraryError.notFound) {
            try await store.updateChatMessage(id: record.id + 100, body: .agentText("nobody"))
        }
    }

    @Test func clearingRemovesOnlyThatCollectionsMessages() async throws {
        let store = try Self.makeStore()
        let home = try await store.defaultCollection()
        let other = try await store.createCollection(name: "Other")
        let job = try await store.enqueueJob(
            collectionID: home.id, request: LibraryStoreTests.request(), batchCount: 1, seedPolicy: "random")
        let image = try await store.saveImage(
            NewImage(
                collectionID: home.id, jobID: job.id, pngData: try TestPNG.make(width: 64, height: 48),
                settings: LibraryStoreTests.settings()))
        try await store.appendChatMessage(collectionID: home.id, author: .user, body: .userText("home"))
        try await store.appendChatMessage(collectionID: other.id, author: .user, body: .userText("other"))

        try await store.clearChatMessages(collectionID: home.id)

        #expect(try await store.chatMessages(collectionID: home.id, limit: 10).isEmpty)
        #expect(try await store.chatMessages(collectionID: other.id, limit: 10).map(\.body) == [.userText("other")])
        #expect(try await store.recentImages(collectionID: home.id, limit: 10).map(\.id) == [image.id])
        #expect(try await store.jobs(status: .queued).map(\.id) == [job.id])
    }

    @Test func deletingAnEmptyCollectionCascadesItsMessages() async throws {
        let store = try Self.makeStore()
        let home = try await store.defaultCollection()
        let doomed = try await store.createCollection(name: "Doomed")
        try await store.appendChatMessage(collectionID: doomed.id, author: .user, body: .userText("gone"))
        try await store.appendChatMessage(collectionID: home.id, author: .user, body: .userText("stays"))

        try await store.deleteCollection(id: doomed.id)

        let remaining = try await store.dbQueue.read { db in
            try Int.fetchOne(
                db, sql: "SELECT COUNT(*) FROM chat_message WHERE collection_id = ?",
                arguments: [doomed.id.uuidString])
        }
        #expect(remaining == 0)
        #expect(try await store.chatMessages(collectionID: home.id, limit: 10).map(\.body) == [.userText("stays")])
    }

    @Test func rowsWithAnUnknownKindOrAnUndecodableBodyAreSkipped() async throws {
        let store = try Self.makeStore()
        let home = try await store.defaultCollection()
        let jobID = UUID().uuidString
        try await store.dbQueue.write { db in
            for (kind, body) in [("futureKind", "{}"), ("result", "not json")] {
                try db.execute(
                    sql: """
                        INSERT INTO chat_message (collection_id, author, kind, body, job_id, created_at)
                        VALUES (?, 'agent', ?, ?, ?, ?)
                        """,
                    arguments: [home.id.uuidString, kind, body, jobID, Date()])
            }
        }
        let known = try await store.appendChatMessage(collectionID: home.id, author: .user, body: .userText("hi"))

        #expect(try await store.chatMessages(collectionID: home.id, limit: 10).map(\.id) == [known.id])
        #expect(try await store.chatMessage(jobID: UUID(uuidString: jobID)!) == nil)
    }

    @Test func aPageOfUnreadableRowsDoesNotStrandOlderMessages() async throws {
        let store = try Self.makeStore()
        let home = try await store.defaultCollection()
        try await store.appendChatMessage(collectionID: home.id, author: .user, body: .userText("first"))
        try await store.dbQueue.write { db in
            for _ in 1...3 {
                try db.execute(
                    sql: """
                        INSERT INTO chat_message (collection_id, author, kind, body, job_id, created_at)
                        VALUES (?, 'agent', 'futureKind', '{}', NULL, ?)
                        """,
                    arguments: [home.id.uuidString, Date()])
            }
        }
        try await store.appendChatMessage(collectionID: home.id, author: .agent, body: .agentText("last"))

        let messages = try await store.chatMessages(collectionID: home.id, limit: 2)
        #expect(messages.map(\.body) == [.userText("first"), .agentText("last")])
        #expect(try await store.chatMessages(collectionID: home.id, limit: 2, before: messages[0].id).isEmpty)
    }

    @Test func aV11DatabaseMigratesAndKeepsItsRows() async throws {
        let root = try LibraryStoreTests.tempRoot()
        let models = root.appending(path: "Models")
        let queue = try DatabaseQueue(
            path: LibraryPaths(root: root, modelsRoot: models).database.path)
        try LibraryStore.migrator.migrate(queue, upTo: "v11-timing")
        let collectionID = UUID()
        try await queue.write { db in
            try db.execute(
                sql: "INSERT INTO collection (id, name, is_default, created_at) VALUES (?, 'Old', 1, ?)",
                arguments: [collectionID.uuidString, Date()])
            try db.execute(
                sql: "INSERT INTO prompt_history (collection_id, prompt, negative_prompt) VALUES (?, 'kept', '')",
                arguments: [collectionID.uuidString])
        }

        let first = try LibraryStore(libraryRoot: root, modelsRoot: models)
        #expect(try await first.promptHistory(collectionID: collectionID).map(\.prompt) == ["kept"])
        #expect(try await first.chatMessages(collectionID: collectionID, limit: 10).isEmpty)
        try await first.appendChatMessage(collectionID: collectionID, author: .user, body: .userText("persisted"))

        let second = try LibraryStore(libraryRoot: root, modelsRoot: models)
        #expect(
            try await second.chatMessages(collectionID: collectionID, limit: 10).map(\.body) == [
                .userText("persisted")
            ])
    }
}
