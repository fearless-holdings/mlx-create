import Foundation
import GRDB

/// The license and commercial-use flags a Civitai model version states (D20). Stored as JSON in `lora_source.license_flags`.
public struct CivitaiLicenseFlags: Sendable, Equatable, Codable {
    public var allowNoCredit: Bool?
    public var allowCommercialUse: [String]
    public var allowDerivatives: Bool?
    public var allowDifferentLicense: Bool?

    public init(
        allowNoCredit: Bool? = nil, allowCommercialUse: [String] = [], allowDerivatives: Bool? = nil,
        allowDifferentLicense: Bool? = nil
    ) {
        self.allowNoCredit = allowNoCredit
        self.allowCommercialUse = allowCommercialUse
        self.allowDerivatives = allowDerivatives
        self.allowDifferentLicense = allowDifferentLicense
    }
}

/// Where a downloaded LoRA's bytes came from (R19, KTD6, D47).
public enum LoRASourceKind: String, Sendable, Equatable, Codable {
    case civitai
    case huggingFace = "hugging_face"
}

/// A Hugging Face LoRA's provenance (R19, KTD6): the repo, the commit its bytes are pinned to, the file inside it, the
/// page the LoRA was picked on and the license text shown with it.
public struct HuggingFaceLoRAOrigin: Sendable, Equatable, Codable {
    /// `org/name`.
    public var repo: String
    /// The 40-hex commit the file is resolved at.
    public var revision: String
    /// The file inside the repo, `/`-separated.
    public var file: String
    public var pageURL: String
    /// The license the user accepted, as shown with the license sheet (R19).
    public var licenseText: String

    public init(repo: String, revision: String, file: String, pageURL: String, licenseText: String) {
        self.repo = repo
        self.revision = revision
        self.file = file
        self.pageURL = pageURL
        self.licenseText = licenseText
    }
}

/// Where a downloaded LoRA came from (R11, KTD5, KTD6): a Civitai model and version, or a Hugging Face repo, commit and
/// file; the license the user accepted and when, one preview and the example prompts. A local import has neither. Table
/// `lora_source`, one row per downloaded LoRA.
public struct LoRASource: Sendable, Equatable, Codable {
    public var kind: LoRASourceKind
    /// Civitai's model and version. Nil for a Hugging Face source.
    public var civitaiModelID: Int?
    public var civitaiVersionID: Int?
    /// The Hugging Face repo, commit and file. Nil for a Civitai source.
    public var huggingFaceRepo: String?
    public var huggingFaceRevision: String?
    public var huggingFaceFile: String?
    public var pageURL: String
    /// Civitai's stated flags (D20). Empty for a Hugging Face source, whose license is ``licenseText``.
    public var license: CivitaiLicenseFlags
    /// The license text the user accepted (R19). Nil for a Civitai source, whose license is ``license``.
    public var licenseText: String?
    public var acceptedAt: Date
    /// The preview's path relative to the library root. The commit sets it to the file it wrote, or nil when no preview
    /// was stored, so a caller's value is replaced.
    public var previewRelativePath: String?
    public var previewNSFWLevel: Int?
    public var examplePrompts: [String]

    /// A Civitai source: the model and version the download came from.
    public init(
        civitaiModelID: Int, civitaiVersionID: Int, pageURL: String, license: CivitaiLicenseFlags, acceptedAt: Date,
        previewRelativePath: String? = nil, previewNSFWLevel: Int? = nil, examplePrompts: [String] = []
    ) {
        kind = .civitai
        self.civitaiModelID = civitaiModelID
        self.civitaiVersionID = civitaiVersionID
        huggingFaceRepo = nil
        huggingFaceRevision = nil
        huggingFaceFile = nil
        self.pageURL = pageURL
        self.license = license
        licenseText = nil
        self.acceptedAt = acceptedAt
        self.previewRelativePath = previewRelativePath
        self.previewNSFWLevel = previewNSFWLevel
        self.examplePrompts = examplePrompts
    }

    /// A Hugging Face source: the pinned origin and the license text the user accepted (R19).
    public init(
        huggingFace origin: HuggingFaceLoRAOrigin, acceptedAt: Date, previewRelativePath: String? = nil
    ) {
        kind = .huggingFace
        civitaiModelID = nil
        civitaiVersionID = nil
        huggingFaceRepo = origin.repo
        huggingFaceRevision = origin.revision
        huggingFaceFile = origin.file
        pageURL = origin.pageURL
        license = CivitaiLicenseFlags()
        licenseText = origin.licenseText
        self.acceptedAt = acceptedAt
        self.previewRelativePath = previewRelativePath
        previewNSFWLevel = nil
        examplePrompts = []
    }
}

/// A `lora_source` row this build cannot read: a source kind a newer build wrote, or a row missing its ids.
enum LoRASourceReadError: Error, Equatable {
    case unknownKind(String)
    case missingCivitaiIDs
    case missingHuggingFaceOrigin
}

/// One `lora_source` row. Internal: ``LibraryStore`` writes it inside the commit and reads it for ``LibraryStore/loraSource(loraID:)``.
struct LoRASourceRow: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "lora_source"

    var loraID: String
    var sourceKind: String
    var civitaiModelID: Int?
    var civitaiVersionID: Int?
    var huggingFaceRepo: String?
    var huggingFaceRevision: String?
    var huggingFaceFile: String?
    var pageURL: String
    var licenseFlags: String
    var licenseText: String?
    var acceptedAt: Date
    var previewRelativePath: String?
    var previewNSFWLevel: Int?
    var examplePrompts: String

    init(loraID: String, source: LoRASource) throws {
        self.loraID = loraID
        sourceKind = source.kind.rawValue
        civitaiModelID = source.civitaiModelID
        civitaiVersionID = source.civitaiVersionID
        huggingFaceRepo = source.huggingFaceRepo
        huggingFaceRevision = source.huggingFaceRevision
        huggingFaceFile = source.huggingFaceFile
        pageURL = source.pageURL
        licenseFlags = try JSONCoding.encode(source.license)
        licenseText = source.licenseText
        acceptedAt = source.acceptedAt
        previewRelativePath = source.previewRelativePath
        previewNSFWLevel = source.previewNSFWLevel
        examplePrompts = try JSONCoding.encode(source.examplePrompts)
    }

    /// Throws when the stored kind, its ids or its JSON cannot be read, so a damaged row is reported rather than shown
    /// as an empty source.
    func source() throws -> LoRASource {
        guard let kind = LoRASourceKind(rawValue: sourceKind) else {
            throw LoRASourceReadError.unknownKind(sourceKind)
        }
        let license = try JSONDecoder().decode(CivitaiLicenseFlags.self, from: Data(licenseFlags.utf8))
        let examplePrompts = try JSONDecoder().decode([String].self, from: Data(self.examplePrompts.utf8))
        switch kind {
        case .civitai:
            guard let civitaiModelID, let civitaiVersionID else {
                throw LoRASourceReadError.missingCivitaiIDs
            }
            return LoRASource(
                civitaiModelID: civitaiModelID, civitaiVersionID: civitaiVersionID, pageURL: pageURL, license: license,
                acceptedAt: acceptedAt, previewRelativePath: previewRelativePath, previewNSFWLevel: previewNSFWLevel,
                examplePrompts: examplePrompts)
        case .huggingFace:
            guard let huggingFaceRepo, let huggingFaceRevision, let huggingFaceFile, let licenseText else {
                throw LoRASourceReadError.missingHuggingFaceOrigin
            }
            return LoRASource(
                huggingFace: HuggingFaceLoRAOrigin(
                    repo: huggingFaceRepo, revision: huggingFaceRevision, file: huggingFaceFile, pageURL: pageURL,
                    licenseText: licenseText),
                acceptedAt: acceptedAt, previewRelativePath: previewRelativePath)
        }
    }

    enum CodingKeys: String, CodingKey {
        case loraID = "lora_id"
        case sourceKind = "source_kind"
        case civitaiModelID = "civitai_model_id"
        case civitaiVersionID = "civitai_version_id"
        case huggingFaceRepo = "hf_repo"
        case huggingFaceRevision = "hf_revision"
        case huggingFaceFile = "hf_file"
        case pageURL = "page_url"
        case licenseFlags = "license_flags"
        case licenseText = "license_text"
        case acceptedAt = "accepted_at"
        case previewRelativePath = "preview_relative_path"
        case previewNSFWLevel = "preview_nsfw_level"
        case examplePrompts = "example_prompts"
    }
}

/// The source of a downloaded LoRA (KTD5, KTD6). Reads only; the source row is written by the commit that stores the LoRA.
extension LibraryStore {
    /// Creates the `lora_source` table (migration `v5-lora-source`). Its row is keyed by `lora_id` and cascades with the LoRA.
    static func createLoRASourceTable(_ db: Database) throws {
        try db.create(table: "lora_source") { t in
            t.primaryKey("lora_id", .text).notNull().references("lora", onDelete: .cascade)
            t.column("civitai_model_id", .integer).notNull()
            t.column("civitai_version_id", .integer).notNull()
            t.column("page_url", .text).notNull()
            t.column("license_flags", .text).notNull()
            t.column("accepted_at", .datetime).notNull()
            t.column("preview_relative_path", .text)
            t.column("preview_nsfw_level", .integer)
            t.column("example_prompts", .text).notNull()
        }
    }

    /// Migration `v9-lora-source-kind`: rebuilds `lora_source` so a row can name a Hugging Face origin (R19, KTD6, D47).
    /// SQLite cannot drop the NOT NULL on the Civitai ids with `ALTER TABLE`, so the table is created anew, the existing
    /// Civitai rows are copied with `source_kind = 'civitai'`, and the old table is dropped and replaced. The `lora_id`
    /// cascade delete is kept. `v5-lora-source` is not edited.
    static func migrateLoRASourceKind(_ db: Database) throws {
        try db.create(table: "lora_source_v9") { t in
            t.primaryKey("lora_id", .text).notNull().references("lora", onDelete: .cascade)
            t.column("source_kind", .text).notNull().defaults(to: LoRASourceKind.civitai.rawValue)
            t.column("civitai_model_id", .integer)
            t.column("civitai_version_id", .integer)
            t.column("hf_repo", .text)
            t.column("hf_revision", .text)
            t.column("hf_file", .text)
            t.column("page_url", .text).notNull()
            t.column("license_flags", .text).notNull()
            t.column("license_text", .text)
            t.column("accepted_at", .datetime).notNull()
            t.column("preview_relative_path", .text)
            t.column("preview_nsfw_level", .integer)
            t.column("example_prompts", .text).notNull()
        }
        try db.execute(
            sql: """
                INSERT INTO lora_source_v9 (lora_id, source_kind, civitai_model_id, civitai_version_id, page_url,
                    license_flags, accepted_at, preview_relative_path, preview_nsfw_level, example_prompts)
                SELECT lora_id, 'civitai', civitai_model_id, civitai_version_id, page_url, license_flags, accepted_at,
                    preview_relative_path, preview_nsfw_level, example_prompts
                FROM lora_source
                """)
        try db.execute(sql: "DROP TABLE lora_source")
        try db.execute(sql: "ALTER TABLE lora_source_v9 RENAME TO lora_source")
    }

    /// The source of the LoRA with this id, or nil for a local import or an unknown id.
    public func loraSource(loraID: String) throws -> LoRASource? {
        try dbQueue.read { db in try LoRASourceRow.fetchOne(db, key: loraID)?.source() }
    }
}
