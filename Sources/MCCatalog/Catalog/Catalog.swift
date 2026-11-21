import Foundation

/// The signed model catalog (`catalog.json`, schema v1). Format and validation rules: `docs/lld/models.md` §2.
/// The types are plain data; verification lives in `CatalogSignature` and validation in `CatalogValidation`.
public struct Catalog: Sendable, Codable, Equatable {
    public static let supportedSchemaVersion = 1

    public let schemaVersion: Int
    public let sequence: Int
    public let issuedAt: Date
    public let models: [CatalogModel]
    /// The vouched LoRA shelf (D43, D44). Optional on the wire: absent means no shelf, so a catalog signed before the
    /// shelf existed decodes unchanged.
    public let loraShelf: [LoRAShelfEntry]

    public init(
        schemaVersion: Int, sequence: Int, issuedAt: Date, models: [CatalogModel],
        loraShelf: [LoRAShelfEntry] = []
    ) {
        self.schemaVersion = schemaVersion
        self.sequence = sequence
        self.issuedAt = issuedAt
        self.models = models
        self.loraShelf = loraShelf
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case sequence
        case issuedAt = "issued_at"
        case models
        case loraShelf = "lora_shelf"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decode(Int.self, forKey: .schemaVersion)
        sequence = try c.decode(Int.self, forKey: .sequence)
        issuedAt = try c.decode(Date.self, forKey: .issuedAt)
        models = try c.decode([CatalogModel].self, forKey: .models)
        loraShelf = try c.decodeIfPresent([LoRAShelfEntry].self, forKey: .loraShelf) ?? []
    }

    /// `lora_shelf` is written only when non-empty, so re-encoding a catalog signed before the shelf existed produces
    /// the same bytes and its signature still matches.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(schemaVersion, forKey: .schemaVersion)
        try c.encode(sequence, forKey: .sequence)
        try c.encode(issuedAt, forKey: .issuedAt)
        try c.encode(models, forKey: .models)
        if !loraShelf.isEmpty { try c.encode(loraShelf, forKey: .loraShelf) }
    }
}

/// What a catalog model is for (KTD4). Image models feed the picker. An enhancer is the local chat model the Enhance
/// flow calls. An agent is the local vision chat model that plans Chat-mode turns (D58). Absent in a catalog means
/// image, so every existing signed catalog reads and verifies unchanged.
public enum CatalogModelKind: String, Sendable, Codable, Equatable {
    case image
    case enhancer
    case agent
}

/// One measured reference render for a model: the size and step count the engine was timed at and the seconds it took
/// on the calibration run (KTD8). Image models only. A reviewer sets it, and every change shows in the build diff.
public struct ReferenceTiming: Sendable, Codable, Equatable {
    public let width: Int
    public let height: Int
    public let steps: Int
    public let seconds: Double

    public init(width: Int, height: Int, steps: Int, seconds: Double) {
        self.width = width
        self.height = height
        self.steps = steps
        self.seconds = seconds
    }
}

/// One installable model. `revision` is the pinned 40-hex Hugging Face commit (D27).
public struct CatalogModel: Sendable, Codable, Equatable, Identifiable {
    public let id: String
    /// Matches a `FamilyRegistry` record id. An enhancer names no record; the value is kept as install provenance only.
    public let family: String
    public let name: String
    public let quantization: String
    /// Hugging Face repo, `org/name`.
    public let repo: String
    /// 40-character lowercase hex commit.
    public let revision: String
    public let downloadBytes: Int64
    /// The engine's measured preflight need in GB.
    public let ramGB: Double
    public let license: CatalogLicense
    public let files: [CatalogFile]
    public let kind: CatalogModelKind
    /// Preference order for the automatic recommendation, lowest first (D42). Nil means never recommended.
    public let recommendRank: Int?
    /// The reviewed reference timing for the calibration baseline (KTD8). Nil until a reviewer measures the model.
    public let referenceTiming: ReferenceTiming?

    public init(
        id: String, family: String, name: String, quantization: String, repo: String, revision: String,
        downloadBytes: Int64, ramGB: Double, license: CatalogLicense, files: [CatalogFile],
        kind: CatalogModelKind = .image, recommendRank: Int? = nil, referenceTiming: ReferenceTiming? = nil
    ) {
        self.id = id
        self.family = family
        self.name = name
        self.quantization = quantization
        self.repo = repo
        self.revision = revision
        self.downloadBytes = downloadBytes
        self.ramGB = ramGB
        self.license = license
        self.files = files
        self.kind = kind
        self.recommendRank = recommendRank
        self.referenceTiming = referenceTiming
    }

    enum CodingKeys: String, CodingKey {
        case id, family, name, quantization, repo, revision, license, files, kind
        case recommendRank = "recommend_rank"
        case referenceTiming = "reference_timing"
        case downloadBytes = "download_bytes"
        case ramGB = "ram_gb"
    }

    /// `kind` is optional on the wire: an absent value is an image model.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        family = try c.decode(String.self, forKey: .family)
        name = try c.decode(String.self, forKey: .name)
        quantization = try c.decode(String.self, forKey: .quantization)
        repo = try c.decode(String.self, forKey: .repo)
        revision = try c.decode(String.self, forKey: .revision)
        downloadBytes = try c.decode(Int64.self, forKey: .downloadBytes)
        ramGB = try c.decode(Double.self, forKey: .ramGB)
        license = try c.decode(CatalogLicense.self, forKey: .license)
        files = try c.decode([CatalogFile].self, forKey: .files)
        kind = try c.decodeIfPresent(CatalogModelKind.self, forKey: .kind) ?? .image
        recommendRank = try c.decodeIfPresent(Int.self, forKey: .recommendRank)
        referenceTiming = try c.decodeIfPresent(ReferenceTiming.self, forKey: .referenceTiming)
    }

    /// Writes the keys in the order the synthesised encoder used. `kind` is written for any kind but image and
    /// `recommend_rank` only when set, so re-encoding an unranked image model produces the same bytes, and the
    /// signature over them still matches. `reference_timing` is written only when set, by the same rule.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(family, forKey: .family)
        try c.encode(name, forKey: .name)
        try c.encode(quantization, forKey: .quantization)
        try c.encode(repo, forKey: .repo)
        try c.encode(revision, forKey: .revision)
        try c.encode(downloadBytes, forKey: .downloadBytes)
        try c.encode(ramGB, forKey: .ramGB)
        try c.encode(license, forKey: .license)
        try c.encode(files, forKey: .files)
        if kind != .image { try c.encode(kind, forKey: .kind) }
        if let recommendRank { try c.encode(recommendRank, forKey: .recommendRank) }
        if let referenceTiming { try c.encode(referenceTiming, forKey: .referenceTiming) }
    }
}

/// One file of a model, as pinned by the catalog. `path` is relative to the model folder.
public struct CatalogFile: Sendable, Codable, Equatable {
    public let path: String
    public let size: Int64
    /// 64 lowercase hex characters.
    public let sha256: String

    public init(path: String, size: Int64, sha256: String) {
        self.path = path
        self.size = size
        self.sha256 = sha256
    }
}

/// The license the user accepts at download (D20, D26). `version` binds acceptance (KTD10).
public struct CatalogLicense: Sendable, Codable, Equatable {
    public let id: String
    public let name: String
    public let url: String
    public let commercialUse: Bool
    public let version: String
    /// Plain-language text the license sheet shows.
    public let summary: String

    public init(id: String, name: String, url: String, commercialUse: Bool, version: String, summary: String) {
        self.id = id
        self.name = name
        self.url = url
        self.commercialUse = commercialUse
        self.version = version
        self.summary = summary
    }

    enum CodingKeys: String, CodingKey {
        case id, name, url, version, summary
        case commercialUse = "commercial_use"
    }
}

/// One vouched LoRA on a family's shelf (D43, D44). The catalog carries no weights: `source` names where the file
/// comes from and `sha256` pins what must arrive (R18, R19).
public struct LoRAShelfEntry: Sendable, Codable, Equatable {
    /// Matches a `FamilyRegistry` record id whose record has at least one `loraFingerprints` entry.
    public let family: String
    /// The job the entry fills, e.g. `anatomy`. One entry per family and role; always-on entries are exempt.
    public let role: String
    /// An explicit role is offered only while the NSFW opt-in is on (D43).
    public let nsfw: Bool
    public let source: LoRAShelfSource
    public let filename: String
    /// The SHA-256 of the file as downloaded.
    public let sha256: String
    public let sizeBytes: Int64
    /// The license text the sheet shows, as the source publishes it.
    public let license: String
    public let triggerWords: [String]
    /// The weight the entry was tested at; the stack slot it creates starts there (KTD7).
    public let testedScale: Double
    /// The source's community rating, when it publishes one.
    public let communityRating: Double?
    /// The engine version the entry was vouched on (KTD10). An engine bump re-runs the harness before this changes.
    public let testedEngine: String
    /// `true` when the app applies the entry invisibly to every generation of its family (D44).
    public let alwaysOn: Bool

    public init(
        family: String, role: String, nsfw: Bool, source: LoRAShelfSource, filename: String, sha256: String,
        sizeBytes: Int64, license: String, triggerWords: [String], testedScale: Double,
        communityRating: Double? = nil, testedEngine: String, alwaysOn: Bool
    ) {
        self.family = family
        self.role = role
        self.nsfw = nsfw
        self.source = source
        self.filename = filename
        self.sha256 = sha256
        self.sizeBytes = sizeBytes
        self.license = license
        self.triggerWords = triggerWords
        self.testedScale = testedScale
        self.communityRating = communityRating
        self.testedEngine = testedEngine
        self.alwaysOn = alwaysOn
    }

    enum CodingKeys: String, CodingKey {
        case family, role, nsfw, source, filename, sha256, license
        case sizeBytes = "size_bytes"
        case triggerWords = "trigger_words"
        case testedScale = "tested_scale"
        case communityRating = "community_rating"
        case testedEngine = "tested_engine"
        case alwaysOn = "always_on"
    }
}

/// Where a shelf entry's weights come from (R19). A Civitai entry names `model_id` and `version_id`; a Hugging Face
/// entry names `repo`, the `revision` commit and the `file` inside it. The other keys are absent.
public struct LoRAShelfSource: Sendable, Codable, Equatable {
    public enum Kind: String, Sendable, Codable, Equatable {
        case civitai
        case huggingface
    }

    public let kind: Kind
    public let modelID: Int?
    public let versionID: Int?
    public let repo: String?
    public let revision: String?
    public let file: String?

    public init(
        kind: Kind, modelID: Int? = nil, versionID: Int? = nil, repo: String? = nil, revision: String? = nil,
        file: String? = nil
    ) {
        self.kind = kind
        self.modelID = modelID
        self.versionID = versionID
        self.repo = repo
        self.revision = revision
        self.file = file
    }

    enum CodingKeys: String, CodingKey {
        case kind, repo, revision, file
        case modelID = "model_id"
        case versionID = "version_id"
    }
}
