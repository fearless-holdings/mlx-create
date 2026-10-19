import Foundation
import GRDB

/// One LoRA in the library (KTD1, D34). Table `lora`; `sha256` is unique, so a file is recorded once.
/// `relativePath` is relative to the Models root (D17). `triggerWords` is stored as a JSON array of strings.
public struct LoRARecord: Codable, FetchableRecord, PersistableRecord, Equatable, Sendable {
    public static let databaseTableName = "lora"

    public var id: String
    public var name: String
    public var family: String
    /// Lowercase hex SHA-256 (64 characters).
    public var sha256: String
    public var relativePath: String
    public var sizeBytes: Int64
    public var triggerWords: [String]
    public var notes: String?
    public var createdAt: Date

    public init(
        id: String, name: String, family: String, sha256: String, relativePath: String, sizeBytes: Int64,
        triggerWords: [String], notes: String?, createdAt: Date
    ) {
        self.id = id
        self.name = name
        self.family = family
        self.sha256 = sha256
        self.relativePath = relativePath
        self.sizeBytes = sizeBytes
        self.triggerWords = triggerWords
        self.notes = notes
        self.createdAt = createdAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        family = try c.decode(String.self, forKey: .family)
        sha256 = try c.decode(String.self, forKey: .sha256)
        relativePath = try c.decode(String.self, forKey: .relativePath)
        sizeBytes = try c.decode(Int64.self, forKey: .sizeBytes)
        let words = try c.decode(String.self, forKey: .triggerWords)
        guard let parsed = JSONCoding.decode([String].self, from: words) else {
            throw DecodingError.dataCorruptedError(
                forKey: .triggerWords, in: c, debugDescription: "trigger_words is not a JSON array of strings")
        }
        triggerWords = parsed
        notes = try c.decodeIfPresent(String.self, forKey: .notes)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(family, forKey: .family)
        try c.encode(sha256, forKey: .sha256)
        try c.encode(relativePath, forKey: .relativePath)
        try c.encode(sizeBytes, forKey: .sizeBytes)
        try c.encode(try JSONCoding.encode(triggerWords), forKey: .triggerWords)
        try c.encode(notes, forKey: .notes)
        try c.encode(createdAt, forKey: .createdAt)
    }

    public enum CodingKeys: String, CodingKey {
        case id, name, family, sha256, notes
        case relativePath = "relative_path"
        case sizeBytes = "size_bytes"
        case triggerWords = "trigger_words"
        case createdAt = "created_at"
    }
}
