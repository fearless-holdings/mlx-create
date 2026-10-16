import Foundation
import GRDB

/// The library database and file store (HLD §9, KTD3, KTD4, KTD7).
///
/// All writes go through this actor. Image files live under ``LibraryPaths``; the database holds rows only.
public actor LibraryStore {
    public let paths: LibraryPaths
    private let dbQueue: DatabaseQueue
    private var beforeRowInsertHook: (@Sendable () throws -> Void)?
    private var beforePartialWriteHook: (@Sendable (URL) throws -> Void)?
    private var statusHook: (@Sendable (JobStatus) throws -> Void)?

    /// Opens (creating if needed) the library at `libraryRoot`, runs migrations, sweeps `*.partial` files
    /// and ensures the default project exists.
    public init(libraryRoot: URL) throws {
        paths = LibraryPaths(root: libraryRoot)
        try FileManager.default.createDirectory(at: libraryRoot, withIntermediateDirectories: true)
        dbQueue = try DatabaseQueue(path: paths.database.path)
        try Self.migrator.migrate(dbQueue)
        try Self.sweepPartials(under: libraryRoot)
        try dbQueue.write { db in
            if try ProjectRow.filter(Column("is_default") == true).fetchCount(db) == 0 {
                try ProjectRow(Project(name: "Default"), isDefault: true).insert(db)
            }
        }
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
        return migrator
    }

    /// Removes leftover `*.partial` files from interrupted saves (KTD7).
    static func sweepPartials(under root: URL) throws {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: nil) else { return }
        for case let url as URL in enumerator where url.pathExtension == "partial" {
            try? fm.removeItem(at: url)
        }
    }

    // MARK: Projects

    public func defaultProject() throws -> Project {
        try dbQueue.read { db in
            guard let row = try ProjectRow.filter(Column("is_default") == true).fetchOne(db) else {
                throw LibraryError.notFound
            }
            return row.project
        }
    }

    // MARK: Jobs (KTD4)

    /// Adds a job at the end of the queue and returns it with its assigned position.
    @discardableResult
    public func enqueueJob(projectID: UUID, request: JobRequest, batchCount: Int, seedPolicy: String) throws -> Job {
        try dbQueue.write { db in
            let next = try Int.fetchOne(db, sql: "SELECT COALESCE(MAX(position), 0) + 1 FROM job WHERE status = ?",
                                        arguments: [JobStatus.queued.rawValue]) ?? 1
            let job = Job(
                id: UUID(), projectID: projectID, mode: "t2i", request: request,
                batchCount: batchCount, seedPolicy: seedPolicy, status: .queued, position: next
            )
            try JobRow(job).insert(db)
            return job
        }
    }

    public func jobs(status: JobStatus) throws -> [Job] {
        try dbQueue.read { db in
            try JobRow
                .filter(Column("status") == status.rawValue)
                .order(Column("position"))
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
    public func transitionJob(_ jobID: UUID, from allowed: Set<JobStatus>, to status: JobStatus, failure: JobFailure? = nil) throws -> Bool {
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

    /// The oldest queued job, or nil when the queue is empty.
    public func nextQueuedJob() throws -> Job? {
        try dbQueue.read { db in
            try JobRow
                .filter(Column("status") == JobStatus.queued.rawValue)
                .order(Column("position"))
                .fetchOne(db)?
                .job
        }
    }

    /// Moves a queued job by `offset` places within the queue (negative is earlier). Clamped to the queue ends.
    public func moveQueuedJob(_ jobID: UUID, by offset: Int) throws {
        try dbQueue.write { db in
            let queued = try JobRow
                .filter(Column("status") == JobStatus.queued.rawValue)
                .order(Column("position"))
                .fetchAll(db)
            guard let index = queued.firstIndex(where: { $0.id == jobID.uuidString }) else {
                throw LibraryError.notQueued
            }
            var ids = queued.map(\.id)
            let target = min(max(index + offset, 0), ids.count - 1)
            let moved = ids.remove(at: index)
            ids.insert(moved, at: target)
            for (position, id) in ids.enumerated() {
                try db.execute(sql: "UPDATE job SET position = ? WHERE id = ?", arguments: [position + 1, id])
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

    /// Saves a generated image (KTD7): writes the PNG with metadata to a temp file in the library volume,
    /// renames it into place, writes the HEIC thumbnail, then inserts the row in one transaction.
    /// If any step before the insert fails, every file created for this image is removed.
    @discardableResult
    public func saveImage(_ new: NewImage) throws -> LibraryImage {
        let now = Date()
        let imageID = UUID()
        let filePath = paths.imageRelativePath(projectID: new.projectID, imageID: imageID, date: now)
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
                projectID: new.projectID,
                jobID: new.jobID,
                mediaType: "image",
                filePath: filePath,
                thumbPath: thumbPath,
                width: size.width,
                height: size.height,
                settings: settings,
                createdAt: now
            )
            try dbQueue.write { db in try ImageRow(image).insert(db) }
            return image
        } catch {
            for url in created { try? fm.removeItem(at: url) }
            throw error
        }
    }

    /// The project's most recent images, newest first.
    public func recentImages(projectID: UUID, limit: Int) throws -> [LibraryImage] {
        try dbQueue.read { db in
            try ImageRow
                .filter(Column("project_id") == projectID.uuidString)
                .order(Column("created_at").desc)
                .limit(limit)
                .fetchAll(db)
                .map(\.image)
        }
    }

    /// One image's settings, for ⌘R reuse.
    public func imageSettings(id: UUID) throws -> ImageSettings? {
        try dbQueue.read { db in try ImageRow.fetchOne(db, key: id.uuidString)?.image.settings }
    }
}

// MARK: Row mapping

/// JSON text for `JOB.request` and `IMAGE.settings`. Fresh coders per call keep the globals Sendable-clean.
enum JSONCoding {
    static func encode<T: Encodable>(_ value: T) throws -> String {
        String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
    }

    static func decode<T: Decodable>(_ type: T.Type, from text: String) -> T? {
        try? JSONDecoder().decode(type, from: Data(text.utf8))
    }
}

private struct ProjectRow: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "project"
    var id: String
    var name: String
    var coverImageID: String?
    var defaultModelID: String?
    var isDefault: Bool
    var createdAt: Date

    init(_ project: Project, isDefault: Bool) {
        id = project.id.uuidString
        name = project.name
        coverImageID = project.coverImageID?.uuidString
        defaultModelID = project.defaultModelID
        self.isDefault = isDefault
        createdAt = project.createdAt
    }

    var project: Project {
        Project(
            id: UUID(uuidString: id) ?? UUID(),
            name: name,
            coverImageID: coverImageID.flatMap(UUID.init(uuidString:)),
            defaultModelID: defaultModelID,
            createdAt: createdAt
        )
    }

    enum CodingKeys: String, CodingKey {
        case id, name
        case coverImageID = "cover_image_id"
        case defaultModelID = "default_model_id"
        case isDefault = "is_default"
        case createdAt = "created_at"
    }
}

private struct JobRow: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "job"
    var id: String
    var projectID: String
    var mode: String
    var request: String
    var batchCount: Int
    var seedPolicy: String
    var status: String
    var position: Int
    var failure: String?

    init(_ job: Job) throws {
        id = job.id.uuidString
        projectID = job.projectID.uuidString
        mode = job.mode
        request = try JSONCoding.encode(job.request)
        batchCount = job.batchCount
        seedPolicy = job.seedPolicy
        status = job.status.rawValue
        position = job.position
        failure = try job.failure.map { try JSONCoding.encode($0) }
    }

    var job: Job {
        Job(
            id: UUID(uuidString: id) ?? UUID(),
            projectID: UUID(uuidString: projectID) ?? UUID(),
            mode: mode,
            request: JSONCoding.decode(JobRequest.self, from: request) ?? JobRequest.unreadable,
            batchCount: batchCount,
            seedPolicy: seedPolicy,
            status: JobStatus(rawValue: status) ?? .failed,
            position: position,
            failure: failure.flatMap { JSONCoding.decode(JobFailure.self, from: $0) }
        )
    }

    enum CodingKeys: String, CodingKey {
        case id, mode, request, status, position, failure
        case projectID = "project_id"
        case batchCount = "batch_count"
        case seedPolicy = "seed_policy"
    }
}

private struct ImageRow: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "image"
    var id: String
    var projectID: String
    var jobID: String?
    var mediaType: String
    var filePath: String
    var thumbPath: String
    var width: Int
    var height: Int
    var seed: Int64
    var settings: String
    var prompt: String
    var createdAt: Date

    init(_ image: LibraryImage) throws {
        id = image.id.uuidString
        projectID = image.projectID.uuidString
        jobID = image.jobID?.uuidString
        mediaType = image.mediaType
        filePath = image.filePath
        thumbPath = image.thumbPath
        width = image.width
        height = image.height
        seed = image.seed
        settings = try JSONCoding.encode(image.settings)
        prompt = image.prompt
        createdAt = image.createdAt
    }

    var image: LibraryImage {
        LibraryImage(
            id: UUID(uuidString: id) ?? UUID(),
            projectID: UUID(uuidString: projectID) ?? UUID(),
            jobID: jobID.flatMap(UUID.init(uuidString:)),
            mediaType: mediaType,
            filePath: filePath,
            thumbPath: thumbPath,
            width: width,
            height: height,
            settings: JSONCoding.decode(ImageSettings.self, from: settings) ?? ImageSettings.unreadable,
            createdAt: createdAt
        )
    }

    enum CodingKeys: String, CodingKey {
        case id, width, height, seed, settings, prompt
        case projectID = "project_id"
        case jobID = "job_id"
        case mediaType = "media_type"
        case filePath = "file_path"
        case thumbPath = "thumb_path"
        case createdAt = "created_at"
    }
}

private extension JobRequest {
    /// Stand-in for a row whose JSON cannot be decoded; it never reaches a generation.
    static let unreadable = JobRequest(modelID: "", family: "", prompt: "", width: 0, height: 0)
}

private extension ImageSettings {
    static let unreadable = ImageSettings(prompt: "", modelID: "", requestedWidth: 0, requestedHeight: 0, seed: 0, width: 0, height: 0, steps: 0)
}
