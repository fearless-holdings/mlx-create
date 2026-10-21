import Foundation
import GRDB

/// One remembered prompt (D39): the text a job was queued with, and its negative prompt (empty when none).
public struct PromptHistoryEntry: Sendable, Equatable, Identifiable {
    public var id: Int64
    public var prompt: String
    public var negativePrompt: String

    public init(id: Int64, prompt: String, negativePrompt: String) {
        self.id = id
        self.prompt = prompt
        self.negativePrompt = negativePrompt
    }
}

/// Per-collection prompt history. The migration is `v8-prompt-history`, registered in ``LibraryStore/migrator``.
extension LibraryStore {
    /// How many entries a collection keeps.
    static let promptHistoryLimit = 100

    static func createPromptHistoryTable(_ db: Database) throws {
        try db.create(table: "prompt_history") { t in
            t.autoIncrementedPrimaryKey("id")
            t.column("collection_id", .text).notNull().references("collection", onDelete: .cascade)
            t.column("prompt", .text).notNull()
            t.column("negative_prompt", .text).notNull()
        }
        try db.create(
            index: "prompt_history_collection", on: "prompt_history",
            columns: ["collection_id", "id"])
    }

    /// The collection's remembered prompts, newest first.
    public func promptHistory(collectionID: UUID) throws -> [PromptHistoryEntry] {
        try dbQueue.read { db in
            try Row.fetchAll(
                db,
                sql:
                    "SELECT id, prompt, negative_prompt FROM prompt_history WHERE collection_id = ? ORDER BY id DESC",
                arguments: [collectionID.uuidString]
            ).map {
                PromptHistoryEntry(
                    id: $0["id"], prompt: $0["prompt"], negativePrompt: $0["negative_prompt"])
            }
        }
    }

    /// Records a queued prompt. An entry with the same prompt and negative prompt is replaced, so a repeat moves to the top,
    /// and entries beyond the newest ``promptHistoryLimit`` go. Runs inside the caller's write.
    static func recordPrompt(
        _ db: Database, collectionID: UUID, prompt: String, negativePrompt: String?
    ) throws {
        let collection = collectionID.uuidString
        let negative = negativePrompt ?? ""
        try db.execute(
            sql:
                "DELETE FROM prompt_history WHERE collection_id = ? AND prompt = ? AND negative_prompt = ?",
            arguments: [collection, prompt, negative])
        try db.execute(
            sql:
                "INSERT INTO prompt_history (collection_id, prompt, negative_prompt) VALUES (?, ?, ?)",
            arguments: [collection, prompt, negative])
        try db.execute(
            sql: """
                DELETE FROM prompt_history WHERE collection_id = ? AND id NOT IN (
                    SELECT id FROM prompt_history WHERE collection_id = ? ORDER BY id DESC LIMIT ?)
                """,
            arguments: [collection, collection, promptHistoryLimit])
    }
}
