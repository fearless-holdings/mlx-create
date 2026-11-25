import Foundation
import GRDB

/// The library database and file store (HLD §9, KTD3, KTD4, KTD7).
///
/// All writes go through this actor. Image files live under ``LibraryPaths``; the database holds rows only.
public actor LibraryStore {
    public let paths: LibraryPaths
    let dbQueue: DatabaseQueue
    private var beforeRowInsertHook: (@Sendable () throws -> Void)?
    private var beforePartialWriteHook: (@Sendable (URL) throws -> Void)?
    private var beforeJobInsertHook: (@Sendable () throws -> Void)?
    private var statusHook: (@Sendable (JobStatus) throws -> Void)?

    /// Opens (creating if needed) the library at `libraryRoot`, runs migrations, sweeps `*.partial` files and
    /// unreferenced LoRA files, and ensures the default collection exists.
    public init(libraryRoot: URL, modelsRoot: URL) throws {
        paths = LibraryPaths(root: libraryRoot, modelsRoot: modelsRoot)
        try FileManager.default.createDirectory(at: libraryRoot, withIntermediateDirectories: true)
        dbQueue = try DatabaseQueue(path: paths.database.path)
        try Self.migrator.migrate(dbQueue)
        try Self.reconcileLegacyProjectsFolder(libraryRoot: libraryRoot)
        try Self.sweepPartials(under: libraryRoot)
        try Self.sweepPartials(under: paths.loraRoot)
        try Self.sweepPartials(under: paths.civitaiStagingDirectory)
        Self.sweepUnreferencedLoRAs(paths: paths, dbQueue: dbQueue)
        try dbQueue.write { db in
            if try CollectionRow.filter(Column("is_default") == true).fetchCount(db) == 0 {
                try CollectionRow(ImageCollection(name: "Default", isDefault: true)).insert(db)
            }
        }
    }

    /// Opens the library off the caller's actor (R15). Directory creation, migrations, the `.partial` sweep and the
    /// default collection run on a detached task, so launch never blocks the main thread.
    public static func open(libraryRoot: URL, modelsRoot: URL) async throws -> LibraryStore {
        try await openOffActor(libraryRoot: libraryRoot, modelsRoot: modelsRoot) { _ in }
    }

    /// ``open(libraryRoot:)`` with a probe that reports whether the opening work ran on the main thread (R15 test seam).
    static func openOffActor(
        libraryRoot: URL, modelsRoot: URL, observe: @escaping @Sendable (_ onMainThread: Bool) -> Void
    ) async throws -> LibraryStore {
        try await Task.detached(priority: .userInitiated) {
            observe(pthread_main_np() != 0)
            return try LibraryStore(libraryRoot: libraryRoot, modelsRoot: modelsRoot)
        }.value
    }

    // MARK: Schema

    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1-project-job-image") { db in
            try db.create(table: "project") { t in
                t.primaryKey("id", .text).notNull()
                t.column("name", .text).notNull()
                t.column("cover_image_id", .text)
                t.column("default_model_id", .text)
                t.column("is_default", .boolean).notNull().defaults(to: false)
                t.column("created_at", .datetime).notNull()
            }
            try db.create(table: "job") { t in
                t.primaryKey("id", .text).notNull()
                t.column("project_id", .text).notNull().references("project", onDelete: .cascade)
                t.column("mode", .text).notNull()
                t.column("request", .text).notNull()
                t.column("batch_count", .integer).notNull()
                t.column("seed_policy", .text).notNull()
                t.column("status", .text).notNull()
                t.column("position", .integer).notNull()
            }
            try db.create(table: "image") { t in
                t.primaryKey("id", .text).notNull()
                t.column("project_id", .text).notNull().references("project", onDelete: .cascade)
                t.column("job_id", .text).references("job", onDelete: .setNull)
                t.column("media_type", .text).notNull()
                t.column("file_path", .text).notNull()
                t.column("thumb_path", .text).notNull()
                t.column("width", .integer).notNull()
                t.column("height", .integer).notNull()
                t.column("seed", .integer).notNull()
                t.column("settings", .text).notNull()
                t.column("prompt", .text).notNull()
                t.column("created_at", .datetime).notNull()
            }
            try db.create(index: "image_project_recent", on: "image", columns: ["project_id", "created_at"])
            try db.create(index: "image_job", on: "image", columns: ["job_id"])
            try db.create(index: "job_status_position", on: "job", columns: ["status", "position"])
        }
        migrator.registerMigration("v2-job-failure") { db in
            try db.alter(table: "job") { t in
                t.add(column: "failure", .text)
            }
        }
        migrator.registerMigration("v3-installed-model", migrate: Self.createInstalledModelTable)
        migrator.registerMigration("v4-lora") { db in
            try db.create(table: "lora") { t in
                t.primaryKey("id", .text).notNull()
                t.column("name", .text).notNull()
                t.column("family", .text).notNull()
                t.column("sha256", .text).notNull().unique()
                t.column("relative_path", .text).notNull()
                t.column("size_bytes", .integer).notNull()
                t.column("trigger_words", .text).notNull()
                t.column("notes", .text)
                t.column("created_at", .datetime).notNull()
            }
        }
        migrator.registerMigration("v5-lora-source") { db in
            try db.alter(table: "lora") { t in
                t.add(column: "variant", .text)
            }
            try Self.createLoRASourceTable(db)
        }
        migrator.registerMigration("v6-collection") { db in
            // GRDB runs migrations with `legacy_alter_table` on, which leaves `job` and `image` pointing at the old `project`
            // table. Turn it off so the rename rewrites those REFERENCES, and restore it after.
            let legacyAlter = try Int.fetchOne(db, sql: "PRAGMA legacy_alter_table") ?? 0
            try db.execute(sql: "PRAGMA legacy_alter_table = OFF")
            try db.execute(sql: "ALTER TABLE project RENAME TO collection")
            try db.execute(sql: "PRAGMA legacy_alter_table = \(legacyAlter)")
            try db.execute(sql: "ALTER TABLE job RENAME COLUMN project_id TO collection_id")
            try db.execute(sql: "ALTER TABLE image RENAME COLUMN project_id TO collection_id")
            try db.drop(index: "image_project_recent")
            try db.create(index: "image_collection_recent", on: "image", columns: ["collection_id", "created_at"])
            try db.execute(sql: "ALTER TABLE collection ADD COLUMN defaults TEXT")
            // `default_model_id` was never written by the app; carry a value over rather than drop it silently.
            try db.execute(
                sql: """
                    UPDATE collection SET defaults = json_object('modelID', default_model_id)
                    WHERE default_model_id IS NOT NULL
                    """)
            try db.execute(sql: "ALTER TABLE collection DROP COLUMN default_model_id")
            // 'Projects/' is nine characters, so the remainder starts at the tenth.
            try db.execute(
                sql: """
                    UPDATE image SET file_path = 'Collections/' || substr(file_path, 10)
                    WHERE file_path LIKE 'Projects/%'
                    """)
        }
        migrator.registerMigration("v7-gallery-filters") { db in
            try db.execute(sql: "ALTER TABLE image ADD COLUMN model_id TEXT")
            try db.create(table: "image_lora") { t in
                t.column("image_id", .text).notNull().references("image", onDelete: .cascade)
                t.column("sha256", .text).notNull()
                t.column("name", .text).notNull()
                t.primaryKey(["image_id", "sha256"])
            }
            try db.create(index: "image_lora_sha256", on: "image_lora", columns: ["sha256"])
            try db.create(index: "image_collection_model", on: "image", columns: ["collection_id", "model_id", "created_at"])
            // SQLite raises on malformed JSON, and one unreadable `settings` row must not stop the library from opening,
            // so every read is guarded by `json_valid`. Such a row keeps a NULL model and gets no LoRA rows.
            try db.execute(
                sql: """
                    UPDATE image SET model_id = json_extract(settings, '$.modelID')
                    WHERE json_valid(settings) AND json_type(settings, '$.modelID') = 'text'
                    """)
            // `json_each` over a guarded argument: the planner may evaluate it before the WHERE clause.
            try db.execute(
                sql: """
                    INSERT OR IGNORE INTO image_lora (image_id, sha256, name)
                    SELECT i.id, json_extract(l.value, '$.sha256'), COALESCE(json_extract(l.value, '$.name'), '')
                    FROM image i,
                         json_each(CASE WHEN json_valid(i.settings) THEN i.settings ELSE '{}' END, '$.loras') l
                    WHERE json_type(l.value, '$.sha256') = 'text'
                    """)
            // External-content full-text index over the prompt column (D37). Triggers keep it in step with `image`.
            // The index is keyed on `image`'s implicit rowid, which VACUUM may renumber (the table has a TEXT primary
            // key). Nothing vacuums today; one that does must follow with
            // `INSERT INTO image_fts(image_fts) VALUES('rebuild')`, or search results will point at the wrong rows.
            try db.execute(
                sql: "CREATE VIRTUAL TABLE image_fts USING fts5(prompt, content='image', content_rowid='rowid', tokenize='unicode61')")
            try db.execute(sql: "INSERT INTO image_fts(rowid, prompt) SELECT rowid, prompt FROM image")
            try db.execute(
                sql: """
                    CREATE TRIGGER image_fts_insert AFTER INSERT ON image BEGIN
                        INSERT INTO image_fts(rowid, prompt) VALUES (new.rowid, new.prompt);
                    END
                    """)
            try db.execute(
                sql: """
                    CREATE TRIGGER image_fts_delete AFTER DELETE ON image BEGIN
                        INSERT INTO image_fts(image_fts, rowid, prompt) VALUES ('delete', old.rowid, old.prompt);
                    END
                    """)
            try db.execute(
                sql: """
                    CREATE TRIGGER image_fts_update AFTER UPDATE OF prompt ON image WHEN old.prompt IS NOT new.prompt BEGIN
                        INSERT INTO image_fts(image_fts, rowid, prompt) VALUES ('delete', old.rowid, old.prompt);
                        INSERT INTO image_fts(rowid, prompt) VALUES (new.rowid, new.prompt);
                    END
                    """)
        }
        migrator.registerMigration("v8-prompt-history", migrate: Self.createPromptHistoryTable)
        migrator.registerMigration("v9-lora-source-kind", migrate: Self.migrateLoRASourceKind)
        migrator.registerMigration("v10-lora-always-on") { db in
            try db.alter(table: "lora") { t in
                t.add(column: "always_on_scale", .double)
            }
        }
        migrator.registerMigration("v11-timing", migrate: Self.createTimingTables)
        migrator.registerMigration("v12-chat-message", migrate: Self.createChatMessageTable)
        migrator.registerMigration("v13-job-position-dedup") { db in
            // A job enqueued behind a running batch once inherited its position, so positions can repeat. Renumber
            // them densely in the order the queue already ran (position, then insertion order), which decides ties the
            // same way a resume would have: the older batch first.
            let ids = try String.fetchAll(db, sql: "SELECT id FROM job ORDER BY position, rowid")
            for (index, id) in ids.enumerated() {
                try db.execute(sql: "UPDATE job SET position = ? WHERE id = ?", arguments: [index + 1, id])
            }
        }
        return migrator
    }

    /// Moves every file under `<library>/Projects/` to the same relative path under `<library>/Collections/` (D35). Where the
    /// target already exists the `Projects/` copy is deleted, since the database names the `Collections/` copy. A crash between
    /// the migration and this step leaves a state the next open finishes. A failed move stops the open: no image is stranded unreported.
    static func reconcileLegacyProjectsFolder(libraryRoot: URL) throws {
        let fm = FileManager.default
        let legacy = libraryRoot.appending(path: "Projects", directoryHint: .isDirectory)
        guard fm.fileExists(atPath: legacy.path) else { return }
        let target = libraryRoot.appending(path: "Collections", directoryHint: .isDirectory)
        guard let enumerator = fm.enumerator(atPath: legacy.path) else {
            throw LibraryError.folderReconcileFailed(path: legacy.path)
        }
        var files: [String] = []
        for case let relative as String in enumerator {
            var isDirectory: ObjCBool = false
            if fm.fileExists(atPath: legacy.appending(path: relative).path, isDirectory: &isDirectory), !isDirectory.boolValue {
                files.append(relative)
            }
        }
        for relative in files {
            let source = legacy.appending(path: relative)
            let destination = target.appending(path: relative)
            do {
                if fm.fileExists(atPath: destination.path) {
                    try fm.removeItem(at: source)
                } else {
                    try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try fm.moveItem(at: source, to: destination)
                }
            } catch {
                throw LibraryError.folderReconcileFailed(path: source.path)
            }
        }
        // Only empty folders are left. A leftover file means a failed step above, which already threw.
        try? fm.removeItem(at: legacy)
    }

    /// Removes leftover `*.partial` files from interrupted saves (KTD7).
    static func sweepPartials(under root: URL) throws {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: nil) else { return }
        for case let url as URL in enumerator where url.pathExtension == "partial" {
            try? fm.removeItem(at: url)
        }
    }

    /// Deletes files under `Models/LoRAs` that no `lora` row names: a copy whose import did not commit, or one left by a
    /// crash. Only regular files inside the LoRA folder are touched, and `.partial` files are left to ``sweepPartials(under:)``.
    /// Runs once at open. Errors are ignored: a stray file costs disk space, never correctness.
    static func sweepUnreferencedLoRAs(paths: LibraryPaths, dbQueue: DatabaseQueue) {
        let root = paths.loraRoot
        let fm = FileManager.default
        // `enumerator(atPath:)` yields paths relative to the root, so the result does not depend on how /var and /private/var resolve.
        guard
            let referenced = try? dbQueue.read({ (db: Database) throws -> Set<String> in
                try Set(String.fetchAll(db, sql: "SELECT relative_path FROM lora"))
            }),
            let enumerator = fm.enumerator(atPath: root.path)
        else { return }
        var orphans: [URL] = []
        for case let name as String in enumerator where !name.hasSuffix(".partial") {
            let url = root.appending(path: name)
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
            let relativePath = "LoRAs/" + name
            guard LibraryPaths.isValidLoRARelativePath(relativePath), !referenced.contains(relativePath) else { continue }
            orphans.append(url)
        }
        for url in orphans {
            try? fm.removeItem(at: url)
        }
    }

    // MARK: Collections (D35)

    public func defaultCollection() throws -> ImageCollection {
        try dbQueue.read { db in
            guard let row = try CollectionRow.filter(Column("is_default") == true).fetchOne(db) else {
                throw LibraryError.notFound
            }
            return row.collection
        }
    }

    public func collection(id: UUID) throws -> ImageCollection? {
        try dbQueue.read { db in try CollectionRow.fetchOne(db, key: id.uuidString)?.collection }
    }

    /// Every collection with its image and open-job counts: the default first, then oldest first.
    public func collections() throws -> [CollectionSummary] {
        try dbQueue.read { db in
            let rows = try CollectionRow.order(Column("is_default").desc, Column("created_at"), Column("name")).fetchAll(db)
            return try rows.map { row in
                CollectionSummary(
                    collection: row.collection,
                    imageCount: try Self.imageCount(db, collectionID: row.id),
                    openJobCount: try Self.openJobCount(db, collectionID: row.id))
            }
        }
    }

    @discardableResult
    public func createCollection(name: String) throws -> ImageCollection {
        try dbQueue.write { db in
            let trimmed = try Self.validatedCollectionName(db, name: name, excluding: nil)
            let collection = ImageCollection(name: trimmed)
            try CollectionRow(collection).insert(db)
            return collection
        }
    }

    public func renameCollection(id: UUID, to name: String) throws {
        try dbQueue.write { db in
            guard var row = try CollectionRow.fetchOne(db, key: id.uuidString) else { throw LibraryError.notFound }
            row.name = try Self.validatedCollectionName(db, name: name, excluding: id.uuidString)
            try row.update(db)
        }
    }

    /// Deletes an empty, non-default collection with no queued, running or paused jobs. The checks run in the same write as
    /// the delete, so an image saved after the UI looked cannot be lost (R6-R8, KTD4). Only rows go: no file is touched, because
    /// the collection's folder can hold files of images that were moved to another collection.
    public func deleteCollection(id: UUID) throws {
        try dbQueue.write { db in
            guard let row = try CollectionRow.fetchOne(db, key: id.uuidString) else { throw LibraryError.notFound }
            if row.isDefault { throw LibraryError.defaultCollectionCannotBeDeleted }
            let images = try Self.imageCount(db, collectionID: row.id)
            if images > 0 { throw LibraryError.collectionHasImages(count: images) }
            let jobs = try Self.openJobCount(db, collectionID: row.id)
            if jobs > 0 { throw LibraryError.collectionHasJobs(count: jobs) }
            // Finished, failed and cancelled job rows go with the collection through the foreign key.
            _ = try row.delete(db)
        }
    }

    /// Stores the composer defaults a collection applies on switch. Nil clears them.
    public func setCollectionDefaults(id: UUID, _ defaults: CollectionDefaults?) throws {
        try dbQueue.write { db in
            guard var row = try CollectionRow.fetchOne(db, key: id.uuidString) else { throw LibraryError.notFound }
            row.defaults = try defaults.map { try JSONCoding.encode($0) }
            try row.update(db)
        }
    }

    private static func imageCount(_ db: Database, collectionID: String) throws -> Int {
        try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM image WHERE collection_id = ?", arguments: [collectionID]) ?? 0
    }

    private static func openJobCount(_ db: Database, collectionID: String) throws -> Int {
        try Int.fetchOne(
            db, sql: "SELECT COUNT(*) FROM job WHERE collection_id = ? AND status IN (?, ?, ?)",
            arguments: [collectionID, JobStatus.queued.rawValue, JobStatus.running.rawValue, JobStatus.paused.rawValue]) ?? 0
    }

    /// The trimmed name, or a thrown error when it is empty or another collection already has it, ignoring case (R14).
    /// Runs inside the caller's write, so two creates cannot both pass the check.
    private static func validatedCollectionName(_ db: Database, name: String, excluding id: String?) throws -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw LibraryError.invalidName }
        let others = try Row.fetchAll(db, sql: "SELECT id, name FROM collection")
        let clash = others.contains { row in
            (row["id"] as String) != id && (row["name"] as String).caseInsensitiveCompare(trimmed) == .orderedSame
        }
        if clash { throw LibraryError.duplicateCollectionName }
        return trimmed
    }

    // MARK: Jobs (KTD4)

    /// Adds a job at the end of the queue and returns it with its assigned position.
    @discardableResult
    public func enqueueJob(collectionID: UUID, request: JobRequest, batchCount: Int, seedPolicy: String, mode: String = Job.textToImageMode)
        throws -> Job
    {
        let hook = beforeJobInsertHook
        return try dbQueue.write { db in
            for entry in request.loras ?? [] {
                guard let row = try LoRARecord.fetchOne(db, key: entry.id), row.sha256 == entry.sha256,
                    row.relativePath == entry.relativePath,
                    let file = paths.loraURL(relativePath: row.relativePath),
                    FileManager.default.fileExists(atPath: file.path)
                else { throw LibraryError.loraUnavailable(name: entry.name) }
            }
            // Count every status, not just queued jobs: a running, paused or finished job keeps its position, so a new
            // job after it must not inherit it. Otherwise Pause and Resume would tie the two, and which one runs first
            // would come down to their ids instead of the order the user queued them in.
            let next =
                try Int.fetchOne(db, sql: "SELECT COALESCE(MAX(position), 0) + 1 FROM job") ?? 1
            let job = Job(
                id: UUID(), collectionID: collectionID, mode: mode, request: request,
                batchCount: batchCount, seedPolicy: seedPolicy, status: .queued, position: next
            )
            try hook?()
            try JobRow(job).insert(db)
            try Self.recordPrompt(db, collectionID: collectionID, prompt: request.prompt, negativePrompt: request.negativePrompt)
            return job
        }
    }

    public func jobs(status: JobStatus) throws -> [Job] {
        try dbQueue.read { db in
            try JobRow
                .filter(Column("status") == status.rawValue)
                .order(Column("position"), Column("id"))
                .fetchAll(db)
                .map(\.job)
        }
    }

    /// Sets a job's status. `failure` is stored with it and cleared when nil (so retry, which moves a failed job back to `queued`, clears it).
    public func setJobStatus(_ jobID: UUID, _ status: JobStatus, failure: JobFailure? = nil) throws {
        try transitionJob(jobID, from: Set(JobStatus.allCases), to: status, failure: failure)
    }

    /// Sets a job's status only if it is currently one of `allowed`. Returns false and changes nothing otherwise, so a
    /// status decided earlier cannot overwrite one written since (for example a cancel racing the executor's start).
    @discardableResult
    public func transitionJob(_ jobID: UUID, from allowed: Set<JobStatus>, to status: JobStatus, failure: JobFailure? = nil) throws -> Bool
    {
        let hook = statusHook
        return try dbQueue.write { db in
            try hook?(status)
            guard var row = try JobRow.fetchOne(db, key: jobID.uuidString) else { throw LibraryError.notFound }
            guard allowed.contains(where: { $0.rawValue == row.status }) else { return false }
            row.status = status.rawValue
            row.failure = try failure.map { try JSONCoding.encode($0) }
            try row.update(db)
            return true
        }
    }

    /// The oldest queued job, or nil when the queue is empty. A requeued job keeps its old position and can tie a newer
    /// one, so ties go to the lower id; the Chat placeholders (`pendingTiles`) order jobs the same way.
    public func nextQueuedJob() throws -> Job? {
        try dbQueue.read { db in
            try JobRow
                .filter(Column("status") == JobStatus.queued.rawValue)
                .order(Column("position"), Column("id"))
                .fetchOne(db)?
                .job
        }
    }

    /// Moves a queued job by `offset` places among the queued jobs of its own collection (negative is earlier), clamped
    /// to that collection's queue ends. Jobs of other collections keep their positions, so a move the user sees as one
    /// step never reorders jobs the queue strip hides.
    public func moveQueuedJob(_ jobID: UUID, by offset: Int) throws {
        try dbQueue.write { db in
            let queued =
                try JobRow
                .filter(Column("status") == JobStatus.queued.rawValue)
                .order(Column("position"), Column("id"))
                .fetchAll(db)
            guard let moving = queued.first(where: { $0.id == jobID.uuidString }) else {
                throw LibraryError.notQueued
            }
            let siblings = queued.filter { $0.collectionID == moving.collectionID }
            let slots = siblings.map(\.position)
            var ids = siblings.map(\.id)
            let index = ids.firstIndex(of: moving.id)!
            let target = min(max(index + offset, 0), ids.count - 1)
            let moved = ids.remove(at: index)
            ids.insert(moved, at: target)
            for (slot, id) in zip(slots, ids) {
                try db.execute(sql: "UPDATE job SET position = ? WHERE id = ?", arguments: [slot, id])
            }
        }
    }

    /// Saved images for `jobID`. Progress is `batchCount - savedImageCount(jobID:)` (KTD4).
    public func savedImageCount(jobID: UUID) throws -> Int {
        try dbQueue.read { db in
            try ImageRow.filter(Column("job_id") == jobID.uuidString).fetchCount(db)
        }
    }

    // MARK: Images (KTD7)

    /// Test seam: runs just before the image row insert, so a failure there exercises file cleanup.
    func setBeforeRowInsertHook(_ hook: (@Sendable () throws -> Void)?) {
        beforeRowInsertHook = hook
    }

    /// Test seam: runs before each job status write, so a failure there exercises the executor's error path.
    func setJobStatusHook(_ hook: (@Sendable (JobStatus) throws -> Void)?) {
        statusHook = hook
    }

    /// Test seam: runs just before a PNG is written to its `.partial` file, so a failure there exercises cleanup.
    func setBeforePartialWriteHook(_ hook: (@Sendable (URL) throws -> Void)?) {
        beforePartialWriteHook = hook
    }

    /// Test seam: runs inside `enqueueJob` just before the job row insert, so a test can hold or fail the write.
    func setBeforeJobInsertHook(_ hook: (@Sendable () throws -> Void)?) {
        beforeJobInsertHook = hook
    }

    /// Saves a generated image (KTD7): writes the PNG with metadata to a temp file in the library volume,
    /// renames it into place, writes the HEIC thumbnail, then inserts the row in one transaction.
    /// If any step before the insert fails, every file created for this image is removed.
    @discardableResult
    public func saveImage(_ new: NewImage) throws -> LibraryImage {
        let now = Date()
        let imageID = UUID()
        let filePath = paths.imageRelativePath(collectionID: new.collectionID, imageID: imageID, date: now)
        let thumbPath = paths.thumbnailRelativePath(imageID: imageID)
        let finalURL = paths.url(relativePath: filePath)
        let partialURL = finalURL.deletingPathExtension().appendingPathExtension("partial")
        let thumbURL = paths.url(relativePath: thumbPath)
        let fm = FileManager.default
        var created: [URL] = []

        do {
            try fm.createDirectory(at: finalURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.createDirectory(at: thumbURL.deletingLastPathComponent(), withIntermediateDirectories: true)

            // The engine may round the request to its size grid, so the PNG is the only source of the real size (KTD3, R16).
            let size = try Thumbnails.pixelSize(ofPNG: new.pngData)
            var settings = new.settings
            settings.width = size.width
            settings.height = size.height
            let withMetadata = try MetadataCodec.embed(settings, into: new.pngData)
            created.append(partialURL)
            try beforePartialWriteHook?(partialURL)
            try withMetadata.write(to: partialURL)
            try fm.moveItem(at: partialURL, to: finalURL)
            created.removeAll { $0 == partialURL }
            created.append(finalURL)

            let thumbnail = try Thumbnails.makeHEIC(fromPNG: withMetadata, maxPixelSize: 512)
            created.append(thumbURL)
            try thumbnail.write(to: thumbURL)

            try beforeRowInsertHook?()

            let image = LibraryImage(
                id: imageID,
                collectionID: new.collectionID,
                jobID: new.jobID,
                mediaType: "image",
                filePath: filePath,
                thumbPath: thumbPath,
                width: size.width,
                height: size.height,
                settings: settings,
                createdAt: now
            )
            try dbQueue.write { db in
                try ImageRow(image).insert(db)
                for lora in settings.loras ?? [] {
                    try db.execute(
                        sql: "INSERT OR IGNORE INTO image_lora (image_id, sha256, name) VALUES (?, ?, ?)",
                        arguments: [image.id.uuidString, lora.sha256, lora.name])
                }
            }
            return image
        } catch {
            for url in created { try? fm.removeItem(at: url) }
            throw error
        }
    }

    /// One image by id, or nil when the library has none. A just-saved image is read this way.
    public func image(id: UUID) throws -> LibraryImage? {
        try dbQueue.read { db in try ImageRow.fetchOne(db, key: id.uuidString)?.image }
    }

    /// One image's settings, for ⌘R reuse.
    public func imageSettings(id: UUID) throws -> ImageSettings? {
        try dbQueue.read { db in try ImageRow.fetchOne(db, key: id.uuidString)?.image.settings }
    }
}
