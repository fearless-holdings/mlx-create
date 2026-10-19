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

/// Where a downloaded LoRA came from (R11, KTD5): the Civitai model and version, the license the user accepted and when,
/// one preview and the example prompts. A local import has none. Table `lora_source`, one row per downloaded LoRA.
public struct LoRASource: Sendable, Equatable, Codable {
    public var civitaiModelID: Int
    public var civitaiVersionID: Int
    public var pageURL: String
    public var license: CivitaiLicenseFlags
    public var acceptedAt: Date
    /// The preview's path relative to the library root. The commit sets it to the file it wrote, or nil when no preview
    /// was stored, so a caller's value is replaced.
    public var previewRelativePath: String?
    public var previewNSFWLevel: Int?
    public var examplePrompts: [String]

    public init(
        civitaiModelID: Int, civitaiVersionID: Int, pageURL: String, license: CivitaiLicenseFlags, acceptedAt: Date,
        previewRelativePath: String? = nil, previewNSFWLevel: Int? = nil, examplePrompts: [String] = []
    ) {
        self.civitaiModelID = civitaiModelID
        self.civitaiVersionID = civitaiVersionID
        self.pageURL = pageURL
        self.license = license
        self.acceptedAt = acceptedAt
        self.previewRelativePath = previewRelativePath
        self.previewNSFWLevel = previewNSFWLevel
        self.examplePrompts = examplePrompts
    }
}

/// One `lora_source` row. Internal: ``LibraryStore`` writes it inside the commit and reads it for ``LibraryStore/loraSource(loraID:)``.
struct LoRASourceRow: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "lora_source"

    var loraID: String
    var civitaiModelID: Int
    var civitaiVersionID: Int
    var pageURL: String
    var licenseFlags: String
    var acceptedAt: Date
    var previewRelativePath: String?
    var previewNSFWLevel: Int?
    var examplePrompts: String

    init(loraID: String, source: LoRASource) throws {
        self.loraID = loraID
        civitaiModelID = source.civitaiModelID
        civitaiVersionID = source.civitaiVersionID
        pageURL = source.pageURL
        licenseFlags = try JSONCoding.encode(source.license)
        acceptedAt = source.acceptedAt
        previewRelativePath = source.previewRelativePath
        previewNSFWLevel = source.previewNSFWLevel
        examplePrompts = try JSONCoding.encode(source.examplePrompts)
    }

    /// Throws when the stored JSON cannot be read, so a damaged row is reported rather than shown as empty.
    func source() throws -> LoRASource {
        LoRASource(
            civitaiModelID: civitaiModelID,
            civitaiVersionID: civitaiVersionID,
            pageURL: pageURL,
            license: try JSONDecoder().decode(CivitaiLicenseFlags.self, from: Data(licenseFlags.utf8)),
            acceptedAt: acceptedAt,
            previewRelativePath: previewRelativePath,
            previewNSFWLevel: previewNSFWLevel,
            examplePrompts: try JSONDecoder().decode([String].self, from: Data(examplePrompts.utf8))
        )
    }

    enum CodingKeys: String, CodingKey {
        case loraID = "lora_id"
        case civitaiModelID = "civitai_model_id"
        case civitaiVersionID = "civitai_version_id"
        case pageURL = "page_url"
        case licenseFlags = "license_flags"
        case acceptedAt = "accepted_at"
        case previewRelativePath = "preview_relative_path"
        case previewNSFWLevel = "preview_nsfw_level"
        case examplePrompts = "example_prompts"
    }
}

/// The Civitai source of a LoRA (KTD5). Reads only; the source row is written by the commit that stores the LoRA.
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

    /// The Civitai source of the LoRA with this id, or nil for a local import or an unknown id.
    public func loraSource(loraID: String) throws -> LoRASource? {
        try dbQueue.read { db in try LoRASourceRow.fetchOne(db, key: loraID)?.source() }
    }
}
