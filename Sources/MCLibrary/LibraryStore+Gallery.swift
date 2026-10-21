import Foundation
import GRDB

// Gallery search, filters and file actions (D37).

/// What the gallery shows: one collection, narrowed by prompt text, models (any of) and LoRAs (all of).
public struct GalleryQuery: Equatable, Sendable {
    public var collectionID: UUID
    public var search: String
    public var modelIDs: Set<String>
    public var loraHashes: Set<String>

    public init(collectionID: UUID, search: String = "", modelIDs: Set<String> = [], loraHashes: Set<String> = []) {
        self.collectionID = collectionID
        self.search = search
        self.modelIDs = modelIDs
        self.loraHashes = loraHashes
    }

    /// FTS5 `MATCH` text for ``search``, or nil when it holds nothing searchable. Each word is quoted so operator
    /// characters cannot raise a syntax error, and the last word is a prefix, so results narrow as the user types.
    var matchExpression: String? {
        let words = search
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
            .filter { $0.unicodeScalars.contains { CharacterSet.alphanumerics.contains($0) } }
        guard !words.isEmpty else { return nil }
        let quoted = words.map { "\"" + $0.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
        return (quoted.dropLast() + [quoted.last! + "*"]).joined(separator: " ")
    }

    /// The number of search and filter criteria that are set.
    public var criteriaCount: Int {
        (matchExpression == nil ? 0 : 1) + (modelIDs.isEmpty ? 0 : 1) + (loraHashes.isEmpty ? 0 : 1)
    }

    public var isFiltered: Bool { criteriaCount > 0 }

    /// `WHERE` text over `image i` and its arguments. The facet that is being listed leaves out its own selection.
    func predicate(includeModels: Bool = true, includeLoRAs: Bool = true) -> (sql: String, arguments: StatementArguments) {
        var clauses = ["i.collection_id = ?"]
        var arguments: StatementArguments = [collectionID.uuidString]
        if let match = matchExpression {
            clauses.append("i.rowid IN (SELECT rowid FROM image_fts WHERE image_fts MATCH ?)")
            arguments += [match]
        }
        if includeModels, !modelIDs.isEmpty {
            let ids = modelIDs.sorted()
            clauses.append("i.model_id IN (\(Self.placeholders(ids.count)))")
            arguments += StatementArguments(ids)
        }
        if includeLoRAs, !loraHashes.isEmpty {
            let hashes = loraHashes.sorted()
            clauses.append("""
                i.id IN (SELECT image_id FROM image_lora WHERE sha256 IN (\(Self.placeholders(hashes.count)))
                         GROUP BY image_id HAVING COUNT(*) = ?)
                """)
            arguments += StatementArguments(hashes)
            arguments += [hashes.count]
        }
        return (clauses.joined(separator: " AND "), arguments)
    }

    private static func placeholders(_ count: Int) -> String {
        Array(repeating: "?", count: count).joined(separator: ", ")
    }
}

/// A LoRA the gallery can filter by. `name` is the library's name, else the one recorded on the newest image that used it.
public struct GalleryLoRAOption: Equatable, Sendable, Identifiable {
    public var sha256: String
    public var name: String
    public var id: String { sha256 }
}

/// The filter choices for a query: models and LoRAs used by images that match the query's other criteria (R11, R12).
public struct GalleryFacets: Equatable, Sendable {
    public var modelIDs: [String]
    public var loras: [GalleryLoRAOption]

    public init(modelIDs: [String] = [], loras: [GalleryLoRAOption] = []) {
        self.modelIDs = modelIDs
        self.loras = loras
    }
}

/// What happened to one image in a delete (R4, R17).
public enum ImageDeleteOutcome: Equatable, Sendable {
    case deleted
    /// Its job is queued, running or paused, so a delete would make the executor generate a replacement.
    case skippedActiveJob
    case failed(String)
}

/// What happened to one image in an export (R7).
public enum ImageExportOutcome: Equatable, Sendable {
    case exported(URL)
    case failed(String)
}

/// Moves a file to the Trash and returns where it went. Injected so tests can run without touching the real Trash (KTD7).
public typealias TrashFunction = @Sendable (URL) throws -> URL?

extension LibraryStore {
    /// The query's images, newest first, skipping the first `offset`. Callers page with growing offsets.
    public func recentImages(query: GalleryQuery, limit: Int, offset: Int = 0) throws -> [LibraryImage] {
        try dbQueue.read { db in
            let (sql, arguments) = query.predicate()
            var args = arguments
            args += [limit, offset]
            return try ImageRow
                .fetchAll(db, sql: "SELECT i.* FROM image i WHERE \(sql) ORDER BY i.created_at DESC, i.id DESC LIMIT ? OFFSET ?", arguments: args)
                .map(\.image)
        }
    }

    /// The collection's most recent images with no search or filters.
    public func recentImages(collectionID: UUID, limit: Int, offset: Int = 0) throws -> [LibraryImage] {
        try recentImages(query: GalleryQuery(collectionID: collectionID), limit: limit, offset: offset)
    }

    /// How many images match the query.
    public func matchingImageCount(query: GalleryQuery) throws -> Int {
        try dbQueue.read { db in
            let (sql, arguments) = query.predicate()
            return try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM image i WHERE \(sql)", arguments: arguments) ?? 0
        }
    }

    /// The image with `id` when it matches the query, else nil. A just-saved image is checked this way (KTD8).
    public func image(id: UUID, matching query: GalleryQuery) throws -> LibraryImage? {
        try dbQueue.read { db in
            let (sql, arguments) = query.predicate()
            var args = arguments
            args += [id.uuidString]
            return try ImageRow.fetchOne(db, sql: "SELECT i.* FROM image i WHERE \(sql) AND i.id = ?", arguments: args)?.image
        }
    }

    /// The ids of `ids` that match the query, so a selection can be cut down to what the gallery shows (R3).
    public func ids(_ ids: [UUID], matching query: GalleryQuery) throws -> Set<UUID> {
        guard !ids.isEmpty else { return [] }
        return try dbQueue.read { db in
            let (sql, arguments) = query.predicate()
            var found: Set<UUID> = []
            // SQLite caps bound variables; chunking keeps a large selection under it.
            for chunk in stride(from: 0, to: ids.count, by: 400).map({ Array(ids[$0..<min($0 + 400, ids.count)]) }) {
                var args = arguments
                args += StatementArguments(chunk.map(\.uuidString))
                let marks = Array(repeating: "?", count: chunk.count).joined(separator: ", ")
                let rows = try String.fetchAll(
                    db, sql: "SELECT i.id FROM image i WHERE \(sql) AND i.id IN (\(marks))", arguments: args)
                found.formUnion(rows.compactMap(UUID.init(uuidString:)))
            }
            return found
        }
    }

    /// The filter lists for a query. Each list is built from the images matching every other criterion, and picked values
    /// stay listed so a pick can always be undone (R11, R12).
    public func galleryFacets(query: GalleryQuery) throws -> GalleryFacets {
        try dbQueue.read { db in
            // Models combine as "any", so their own pick is left out: it would hide the alternatives.
            let forModels = query.predicate(includeModels: false)
            var models = try String.fetchAll(
                db,
                sql: "SELECT DISTINCT i.model_id FROM image i WHERE \(forModels.sql) AND i.model_id IS NOT NULL ORDER BY i.model_id",
                arguments: forModels.arguments)
            for picked in query.modelIDs.sorted() where !models.contains(picked) { models.append(picked) }

            // LoRAs combine as "all", so the picks stay in force: a further LoRA must have been used with them.
            let forLoRAs = query.predicate(includeModels: true, includeLoRAs: true)
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT il.sha256 AS sha256, COALESCE(l.name, il.name) AS name, MAX(i.created_at) AS newest
                    FROM image i
                    JOIN image_lora il ON il.image_id = i.id
                    LEFT JOIN lora l ON l.sha256 = il.sha256
                    WHERE \(forLoRAs.sql)
                    GROUP BY il.sha256
                    ORDER BY name COLLATE NOCASE, il.sha256
                    """,
                arguments: forLoRAs.arguments)
            var loras = rows.map { GalleryLoRAOption(sha256: $0["sha256"], name: $0["name"]) }
            for picked in query.loraHashes.sorted() where !loras.contains(where: { $0.sha256 == picked }) {
                let name = try String.fetchOne(
                    db,
                    sql: "SELECT COALESCE((SELECT name FROM lora WHERE sha256 = ?), (SELECT name FROM image_lora WHERE sha256 = ? LIMIT 1))",
                    arguments: [picked, picked])
                loras.append(GalleryLoRAOption(sha256: picked, name: name ?? String(picked.prefix(10))))
            }
            return GalleryFacets(modelIDs: models, loras: loras)
        }
    }

    // MARK: Move

    /// Reassigns the images' home collection in one transaction. Only `collection_id` changes: files stay where they are (KTD3).
    public func moveImages(ids: [UUID], toCollection collectionID: UUID) throws {
        try dbQueue.write { db in
            guard try CollectionRow.fetchOne(db, key: collectionID.uuidString) != nil else { throw LibraryError.notFound }
            for id in ids {
                guard try ImageRow.fetchOne(db, key: id.uuidString) != nil else { throw LibraryError.notFound }
            }
            for id in ids {
                try db.execute(
                    sql: "UPDATE image SET collection_id = ? WHERE id = ? AND collection_id != ?",
                    arguments: [collectionID.uuidString, id.uuidString, collectionID.uuidString])
            }
        }
    }

    // MARK: Delete (KTD5)

    /// Deletes each image on its own: the PNG and thumbnail go to the Trash, then the row goes. An image whose job is
    /// queued, running or paused is skipped (R17). If the row cannot be removed, the files are put back. One image's
    /// failure never undoes another's deletion.
    public func deleteImages(ids: [UUID], trash: TrashFunction) -> [UUID: ImageDeleteOutcome] {
        var outcomes: [UUID: ImageDeleteOutcome] = [:]
        for id in ids {
            outcomes[id] = deleteImage(id: id, trash: trash)
        }
        return outcomes
    }

    private func deleteImage(id: UUID, trash: TrashFunction) -> ImageDeleteOutcome {
        let fm = FileManager.default
        do {
            let state: (row: ImageRow, jobActive: Bool)? = try dbQueue.read { db in
                guard let row = try ImageRow.fetchOne(db, key: id.uuidString) else { return nil }
                let active: Bool
                if let jobID = row.jobID {
                    active = try Int.fetchOne(
                        db, sql: "SELECT COUNT(*) FROM job WHERE id = ? AND status IN (?, ?, ?)",
                        arguments: [jobID, JobStatus.queued.rawValue, JobStatus.running.rawValue, JobStatus.paused.rawValue]) ?? 0 > 0
                } else {
                    active = false
                }
                return (row, active)
            }
            // A row that is already gone has nothing left to delete.
            guard let state else { return .deleted }
            if state.jobActive { return .skippedActiveJob }

            var trashed: [(original: URL, trashed: URL)] = []
            func restore() {
                for item in trashed.reversed() { try? fm.moveItem(at: item.trashed, to: item.original) }
            }
            for relative in [state.row.filePath, state.row.thumbPath] {
                let url = paths.url(relativePath: relative)
                // A file already missing from disk counts as gone.
                guard fm.fileExists(atPath: url.path) else { continue }
                do {
                    if let result = try trash(url) { trashed.append((url, result)) }
                } catch {
                    restore()
                    return .failed(Self.trashMessage(error))
                }
            }
            do {
                try dbQueue.write { db in _ = try ImageRow.deleteOne(db, key: id.uuidString) }
            } catch {
                restore()
                return .failed(error.localizedDescription)
            }
            return .deleted
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    private static func trashMessage(_ error: Error) -> String {
        if let cocoa = error as? CocoaError, cocoa.code == .featureUnsupported {
            return "This volume has no Trash, so the image was left in place."
        }
        return error.localizedDescription
    }

    // MARK: Export (KTD6)

    /// Copies each image's PNG into `folder` byte for byte, so the prompt and settings metadata stay in the file. A name
    /// that is already taken gets a numeric suffix; nothing is overwritten (R7).
    public func exportImages(ids: [UUID], to folder: URL) -> [UUID: ImageExportOutcome] {
        let fm = FileManager.default
        var outcomes: [UUID: ImageExportOutcome] = [:]
        for id in ids {
            do {
                guard let image = try dbQueue.read({ db in try ImageRow.fetchOne(db, key: id.uuidString) })?.image else {
                    outcomes[id] = .failed("The image is no longer in the library.")
                    continue
                }
                let source = paths.url(relativePath: image.filePath)
                let target = Self.uniqueURL(in: folder, base: Self.exportBaseName(image), ext: "png")
                try fm.copyItem(at: source, to: target)
                outcomes[id] = .exported(target)
            } catch {
                outcomes[id] = .failed(error.localizedDescription)
            }
        }
        return outcomes
    }

    /// `<first words of the prompt>-<seed>`, safe as a file name.
    static func exportBaseName(_ image: LibraryImage) -> String {
        let words = image.prompt.split(whereSeparator: \.isWhitespace).prefix(6).joined(separator: "-")
        let slug = String(words.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) || $0 == "-" }
            .map(Character.init)).lowercased()
        let stem = slug.isEmpty ? "image" : String(slug.prefix(60))
        return "\(stem)-\(image.seed)"
    }

    static func uniqueURL(in folder: URL, base: String, ext: String) -> URL {
        let fm = FileManager.default
        var candidate = folder.appending(path: "\(base).\(ext)")
        var n = 2
        while fm.fileExists(atPath: candidate.path) {
            candidate = folder.appending(path: "\(base)-\(n).\(ext)")
            n += 1
        }
        return candidate
    }
}
