import Foundation
import GRDB

/// Chat-mode conversation storage (D55, KTD8; `docs/lld/agent.md` §8). The migration is `v12-chat-message`, registered
/// in ``LibraryStore/migrator``. A message's progress and outcome live on its job row, never here; `job_id` is a plain
/// column with no foreign key, so a message outlives any job cleanup.
extension LibraryStore {
    static func createChatMessageTable(_ db: Database) throws {
        try db.create(table: "chat_message") { t in
            t.autoIncrementedPrimaryKey("id")
            t.column("collection_id", .text).notNull().references("collection", onDelete: .cascade)
            t.column("author", .text).notNull()
            t.column("kind", .text).notNull()
            t.column("body", .text).notNull()
            t.column("job_id", .text)
            t.column("created_at", .datetime).notNull()
        }
        try db.create(
            index: "chat_message_collection", on: "chat_message",
            columns: ["collection_id", "id"])
        try db.create(index: "chat_message_job", on: "chat_message", columns: ["job_id"])
    }

    /// Appends a message to the collection's conversation and returns it with its assigned id (D55). `job_id` comes
    /// from a `.result` body; every other kind stores nil.
    @discardableResult
    public func appendChatMessage(
        collectionID: UUID, author: ChatAuthor, body: ChatMessageBody, at date: Date = Date()
    ) throws -> ChatMessageRecord {
        try dbQueue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO chat_message (collection_id, author, kind, body, job_id, created_at)
                    VALUES (?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    collectionID.uuidString, author.rawValue, body.kind, try body.encodedBody(),
                    body.jobID?.uuidString, date,
                ])
            return ChatMessageRecord(
                id: db.lastInsertedRowID, collectionID: collectionID, author: author, body: body,
                jobID: body.jobID, createdAt: date)
        }
    }

    /// The newest `limit` messages with `id < before` (all when nil), returned oldest first; a `limit` below 1
    /// returns none. A row whose `kind` this build does not know, or whose body does not decode, is skipped: the read
    /// keeps paging until `limit` rows decode or the conversation ends, so an empty result means no older readable
    /// messages, not an unreadable page.
    public func chatMessages(collectionID: UUID, limit: Int, before: Int64? = nil) throws -> [ChatMessageRecord] {
        guard limit > 0 else { return [] }
        return try dbQueue.read { db in
            var records: [ChatMessageRecord] = []
            var before = before
            while records.count < limit {
                var sql = """
                    SELECT id, collection_id, author, kind, body, job_id, created_at
                    FROM chat_message WHERE collection_id = ?
                    """
                var arguments = StatementArguments([collectionID.uuidString])
                if let before {
                    sql += " AND id < ?"
                    arguments += [before]
                }
                sql += " ORDER BY id DESC LIMIT ?"
                arguments += [limit]
                let rows = try Row.fetchAll(db, sql: sql, arguments: arguments)
                guard let lastRow = rows.last else { break }
                before = lastRow["id"]
                records += rows.lazy.compactMap(Self.chatMessage(from:))
                if rows.count < limit { break }
            }
            return Array(records.prefix(limit).reversed())
        }
    }

    /// Rewrites a message's body, `kind` and `job_id` together. An unknown id throws ``LibraryError/notFound``.
    public func updateChatMessage(id: Int64, body: ChatMessageBody) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: "UPDATE chat_message SET kind = ?, body = ?, job_id = ? WHERE id = ?",
                arguments: [body.kind, try body.encodedBody(), body.jobID?.uuidString, id])
            guard db.changesCount > 0 else { throw LibraryError.notFound }
        }
    }

    /// Removes every message of the collection's conversation. Images and jobs are untouched.
    public func clearChatMessages(collectionID: UUID) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: "DELETE FROM chat_message WHERE collection_id = ?", arguments: [collectionID.uuidString])
        }
    }

    /// The job `jobID` names, or nil when its row is gone. Chat replays and follows result jobs by id.
    public func job(id jobID: UUID) throws -> Job? {
        try dbQueue.read { db in
            try JobRow.fetchOne(db, key: jobID.uuidString)?.job
        }
    }

    /// The images `jobID` saved, oldest first (a same-millisecond pair keeps its insert order). A referent lookup
    /// takes the newest.
    public func images(jobID: UUID) throws -> [LibraryImage] {
        try dbQueue.read { db in
            try ImageRow
                .filter(Column("job_id") == jobID.uuidString)
                .order(Column("created_at"), Column("rowid"))
                .fetchAll(db)
                .map(\.image)
        }
    }

    /// The message whose `job_id` is `jobID`, or nil. Only `.result` rows carry one.
    public func chatMessage(jobID: UUID) throws -> ChatMessageRecord? {
        try dbQueue.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT id, collection_id, author, kind, body, job_id, created_at
                    FROM chat_message WHERE job_id = ?
                    """,
                arguments: [jobID.uuidString]
            ).lazy.compactMap(Self.chatMessage(from:)).first
        }
    }

    /// The message with id `id`, or nil. Chat's card writes read it back so a card in a collection that is not on
    /// screen — however old — mutates its persisted body rather than a caller's snapshot.
    public func chatMessage(id: Int64) throws -> ChatMessageRecord? {
        try dbQueue.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT id, collection_id, author, kind, body, job_id, created_at
                    FROM chat_message WHERE id = ?
                    """,
                arguments: [id]
            ).lazy.compactMap(Self.chatMessage(from:)).first
        }
    }

    /// A row decodes to its record, or nil when its `kind` is unknown, its body does not decode, or its ids are not
    /// well-formed: a message a newer build wrote is skipped on read, never thrown.
    static func chatMessage(from row: Row) -> ChatMessageRecord? {
        guard
            let collectionID = UUID(uuidString: row["collection_id"]),
            let author = ChatAuthor(rawValue: row["author"]),
            let body = ChatMessageBody.decode(kind: row["kind"], bodyJSON: row["body"])
        else { return nil }
        let jobIDText: String? = row["job_id"]
        return ChatMessageRecord(
            id: row["id"], collectionID: collectionID, author: author, body: body,
            jobID: jobIDText.flatMap(UUID.init(uuidString:)), createdAt: row["created_at"])
    }
}
