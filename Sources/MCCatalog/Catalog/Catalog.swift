import Foundation

/// The signed model catalog (`catalog.json`, schema v1). Format and validation rules: `docs/lld/models.md` §2.
/// The types are plain data; verification lives in `CatalogSignature` and validation in `CatalogValidation`.
public struct Catalog: Sendable, Codable, Equatable {
    public static let supportedSchemaVersion = 1

    public let schemaVersion: Int
    public let sequence: Int
    public let issuedAt: Date
    public let models: [CatalogModel]

    public init(schemaVersion: Int, sequence: Int, issuedAt: Date, models: [CatalogModel]) {
        self.schemaVersion = schemaVersion
        self.sequence = sequence
        self.issuedAt = issuedAt
        self.models = models
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case sequence
        case issuedAt = "issued_at"
        case models
    }
}

/// What a catalog model is for (KTD4). Image models feed the picker. An enhancer is the local chat model the Enhance
/// flow calls. Absent in a catalog means image, so every existing signed catalog reads and verifies unchanged.
public enum CatalogModelKind: String, Sendable, Codable, Equatable {
    case image
    case enhancer
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

    public init(
        id: String, family: String, name: String, quantization: String, repo: String, revision: String,
        downloadBytes: Int64, ramGB: Double, license: CatalogLicense, files: [CatalogFile],
        kind: CatalogModelKind = .image
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
    }

    enum CodingKeys: String, CodingKey {
        case id, family, name, quantization, repo, revision, license, files, kind
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
    }

    /// Writes the keys in the order the synthesised encoder used. `kind` is written only for an enhancer, so re-encoding
    /// an image model produces the same bytes, and the signature over them still matches.
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
