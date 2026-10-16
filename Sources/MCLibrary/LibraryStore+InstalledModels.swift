import Foundation
import GRDB

/// One installed model, as recorded when its install finished (KTD9). Plain data: the installer decides the values.
public struct InstalledModelRecord: Sendable, Equatable {
    public struct File: Sendable, Equatable, Codable {
        /// Path relative to the model folder.
        public var path: String
        public var size: Int64
        /// Lowercase hex SHA-256, as the signed catalog pinned it.
        public var sha256: String

        public init(path: String, size: Int64, sha256: String) {
            self.path = path
            self.size = size
            self.sha256 = sha256
        }
    }

    public var modelID: String
    public var family: String
    public var repo: String
    public var revision: String
    public var catalogSequence: Int
    /// The per-file manifest stored as JSON.
    public var files: [File]
    public var licenseID: String
    public var licenseVersion: String
    public var acceptedAt: Date
    public var installedAt: Date

    public init(
        modelID: String, family: String, repo: String, revision: String, catalogSequence: Int, files: [File],
        licenseID: String, licenseVersion: String, acceptedAt: Date, installedAt: Date
    ) {
        self.modelID = modelID
        self.family = family
        self.repo = repo
        self.revision = revision
        self.catalogSequence = catalogSequence
        self.files = files
        self.licenseID = licenseID
        self.licenseVersion = licenseVersion
        self.acceptedAt = acceptedAt
        self.installedAt = installedAt
    }
}

/// Installed models (KTD9). The migration is `v3-installed-model`, registered in ``LibraryStore/migrator``.
extension LibraryStore {
    static func createInstalledModelTable(_ db: Database) throws {
        try db.create(table: "installed_model") { t in
            t.primaryKey("model_id", .text).notNull()
            t.column("family", .text).notNull()
            t.column("repo", .text).notNull()
            t.column("revision", .text).notNull()
            t.column("catalog_sequence", .integer).notNull()
            t.column("manifest", .text).notNull()
            t.column("license_id", .text).notNull()
            t.column("license_version", .text).notNull()
            t.column("accepted_at", .datetime).notNull()
            t.column("installed_at", .datetime).notNull()
        }
    }

    /// Writes the record. Fails if the model already has one, so a model is recorded at most once.
    public func recordInstalledModel(_ model: InstalledModelRecord) throws {
        try dbQueue.write { db in try InstalledModelRow(model).insert(db) }
    }

    public func installedModel(id: String) throws -> InstalledModelRecord? {
        try dbQueue.read { db in try InstalledModelRow.fetchOne(db, key: id)?.model }
    }

    /// Every installed model, oldest install first.
    public func installedModels() throws -> [InstalledModelRecord] {
        try dbQueue.read { db in
            try InstalledModelRow
                .order(Column("installed_at"), Column("model_id"))
                .fetchAll(db)
                .map(\.model)
        }
    }
}

private struct InstalledModelRow: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "installed_model"
    var modelID: String
    var family: String
    var repo: String
    var revision: String
    var catalogSequence: Int
    var manifest: String
    var licenseID: String
    var licenseVersion: String
    var acceptedAt: Date
    var installedAt: Date

    init(_ model: InstalledModelRecord) throws {
        modelID = model.modelID
        family = model.family
        repo = model.repo
        revision = model.revision
        catalogSequence = model.catalogSequence
        manifest = try JSONCoding.encode(model.files)
        licenseID = model.licenseID
        licenseVersion = model.licenseVersion
        acceptedAt = model.acceptedAt
        installedAt = model.installedAt
    }

    var model: InstalledModelRecord {
        InstalledModelRecord(
            modelID: modelID, family: family, repo: repo, revision: revision, catalogSequence: catalogSequence,
            files: JSONCoding.decode([InstalledModelRecord.File].self, from: manifest) ?? [],
            licenseID: licenseID, licenseVersion: licenseVersion, acceptedAt: acceptedAt, installedAt: installedAt)
    }

    enum CodingKeys: String, CodingKey {
        case modelID = "model_id"
        case family, repo, revision, manifest
        case catalogSequence = "catalog_sequence"
        case licenseID = "license_id"
        case licenseVersion = "license_version"
        case acceptedAt = "accepted_at"
        case installedAt = "installed_at"
    }
}
