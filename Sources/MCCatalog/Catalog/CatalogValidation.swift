import Foundation

/// Why a catalog or its signature was rejected. Loader code treats every case as "candidate ignored".
public enum CatalogError: Error, Equatable, Sendable {
    case signatureMissing
    case signatureMalformed(String)
    case unknownKey(String)
    case badSignature
    case malformed(String)
    case unsupportedSchemaVersion(Int)
    case invalid(String)
    case noValidCatalog
}

extension Catalog {
    /// Parses and validates a catalog (`docs/lld/models.md` §2). The schema version is read before the full
    /// decode, so a future schema is reported as unsupported rather than malformed.
    public static func decodeValidated(_ bytes: Data) throws -> Catalog {
        struct Header: Decodable {
            let schemaVersion: Int
            enum CodingKeys: String, CodingKey { case schemaVersion = "schema_version" }
        }
        let header: Header
        do {
            header = try JSONDecoder().decode(Header.self, from: bytes)
        } catch {
            throw CatalogError.malformed("\(error)")
        }
        guard header.schemaVersion == supportedSchemaVersion else {
            throw CatalogError.unsupportedSchemaVersion(header.schemaVersion)
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let catalog: Catalog
        do {
            catalog = try decoder.decode(Catalog.self, from: bytes)
        } catch {
            throw CatalogError.malformed("\(error)")
        }
        try catalog.validate()
        return catalog
    }

    public func validate() throws {
        guard !loraShelf.isEmpty else {
            try validate(loraFamilies: nil)
            return
        }
        let families: FamilyRegistry
        do {
            families = try FamilyRegistry.bundled()
        } catch {
            throw CatalogError.invalid("the family registry is unavailable, so the shelf cannot be checked: \(error)")
        }
        try validate(loraFamilies: families)
    }

    /// - Parameter loraFamilies: the registry shelf entries are checked against. `nil` skips those checks and is only
    ///   correct for a catalog with an empty shelf; the loader always passes the bundled registry.
    func validate(loraFamilies: FamilyRegistry?) throws {
        guard sequence >= 0 else { throw CatalogError.invalid("sequence must not be negative") }
        guard !models.isEmpty else { throw CatalogError.invalid("catalog lists no models") }
        var ids = Set<String>()
        var repos = Set<String>()
        for model in models {
            guard ids.insert(model.id).inserted else { throw CatalogError.invalid("duplicate model id \(model.id)") }
            guard repos.insert(CatalogPath.collisionKey(model.repo)).inserted else {
                throw CatalogError.invalid("repo \(model.repo) collides with another model's repo")
            }
            try model.validate()
        }
        try validateShelf(loraFamilies: loraFamilies)
    }

    /// Shelf entries are usable only for a family that accepts LoRAs: a family without `loraFingerprints` cannot
    /// classify a file, so it cannot vouch for one. One entry per family and role, except always-on entries.
    private func validateShelf(loraFamilies: FamilyRegistry?) throws {
        var roles = Set<String>()
        var hashes = Set<String>()
        for entry in loraShelf {
            guard CatalogModel.isHex(entry.sha256, length: 64) else {
                throw CatalogError.invalid("shelf entry \(entry.family)/\(entry.role) needs a 64-character lowercase hex sha256")
            }
            guard hashes.insert(entry.sha256).inserted else {
                throw CatalogError.invalid("shelf entry \(entry.family)/\(entry.role) repeats another entry's sha256")
            }
            guard entry.sizeBytes > 0 else {
                throw CatalogError.invalid("shelf entry \(entry.family)/\(entry.role) needs a positive size_bytes")
            }
            guard entry.filename.hasSuffix(".safetensors"), entry.filename.count > ".safetensors".count else {
                throw CatalogError.invalid("shelf entry \(entry.family)/\(entry.role) needs a .safetensors filename")
            }
            try Self.validate(source: entry.source, of: entry)
            guard entry.testedScale > 0, entry.testedScale <= 20 else {
                throw CatalogError.invalid("tested_scale for shelf entry \(entry.family)/\(entry.role) must be in 0...20")
            }
            if let loraFamilies {
                guard let family = loraFamilies.families.first(where: { $0.id == entry.family }) else {
                    throw CatalogError.invalid("shelf entry names unknown family \(entry.family)")
                }
                guard family.acceptsLoRAs else {
                    throw CatalogError.invalid("shelf entry names family \(entry.family), which accepts no LoRAs")
                }
            }
            guard !entry.alwaysOn else { continue }
            guard roles.insert("\(entry.family)\u{0}\(entry.role)").inserted else {
                throw CatalogError.invalid("duplicate shelf entry for \(entry.family) role \(entry.role)")
            }
        }
    }

    /// A Hugging Face entry pins a commit and a safe file path in a well-formed repo, and a Civitai entry names its model and
    /// version, because both go straight into a download URL.
    private static func validate(source: LoRAShelfSource, of entry: LoRAShelfEntry) throws {
        switch source.kind {
        case .civitai:
            guard source.modelID != nil, source.versionID != nil else {
                throw CatalogError.invalid("shelf entry \(entry.family)/\(entry.role) needs a Civitai model and version id")
            }
        case .huggingface:
            guard let repo = source.repo, CatalogModel.isRepo(repo), let revision = source.revision,
                CatalogModel.isHex(revision, length: 40), let file = source.file, CatalogPath.isSafe(file)
            else {
                throw CatalogError.invalid(
                    "shelf entry \(entry.family)/\(entry.role) needs an org/name repo, a 40-character commit and a safe file path")
            }
        }
    }
}

extension CatalogModel {
    public func validate() throws {
        guard !id.isEmpty, !family.isEmpty, !name.isEmpty, !quantization.isEmpty else {
            throw CatalogError.invalid("model \(id) has an empty required field")
        }
        guard Self.isRepo(repo) else { throw CatalogError.invalid("repo \(repo) must be org/name") }
        guard Self.isHex(revision, length: 40) else {
            throw CatalogError.invalid("revision for \(id) must be 40 lowercase hex characters")
        }
        guard ramGB > 0 else { throw CatalogError.invalid("ram_gb for \(id) must be positive") }
        guard !files.isEmpty else { throw CatalogError.invalid("model \(id) lists no files") }
        if let recommendRank, recommendRank < 1 {
            throw CatalogError.invalid("recommend_rank for \(id) must be a positive integer")
        }

        var seen = Set<String>()
        var total: Int64 = 0
        for file in files {
            guard CatalogPath.isSafe(file.path) else {
                throw CatalogError.invalid("file path \(file.path) must be relative with no '..' segment")
            }
            if case .rejected(let reason) = WeightFilePolicy.check(file.path) {
                throw CatalogError.invalid("file \(file.path) is not allowed: \(reason)")
            }
            let key = CatalogPath.collisionKey(file.path)
            guard seen.insert(key).inserted else { throw CatalogError.invalid("duplicate file path \(file.path)") }
            guard file.size > 0 else { throw CatalogError.invalid("file \(file.path) must have a positive size") }
            guard Self.isHex(file.sha256, length: 64) else {
                throw CatalogError.invalid("sha256 for \(file.path) must be 64 lowercase hex characters")
            }
            total += file.size
        }
        guard total == downloadBytes else {
            throw CatalogError.invalid("download_bytes \(downloadBytes) does not equal the file total \(total)")
        }
        try license.validate(model: id)
    }

    /// `org/name`. Each segment is ASCII, starts with a letter or digit, and then holds only letters, digits, `.`,
    /// `_` or `-`. A leading `.`, `-` or `_` is refused, so no segment can be `.`, `..` or an option-like word.
    public static func isRepo(_ repo: String) -> Bool {
        let parts = repo.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return false }
        return parts.allSatisfy { part in
            guard let first = part.utf8.first, isASCIIAlphanumeric(first) else { return false }
            return part.utf8.allSatisfy { byte in
                isASCIIAlphanumeric(byte) || "._-".utf8.contains(byte)
            }
        }
    }

    /// Exactly `length` lowercase ASCII hex digits.
    public static func isHex(_ value: String, length: Int) -> Bool {
        value.utf8.count == length && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    private static func isASCIIAlphanumeric(_ byte: UInt8) -> Bool {
        (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte)
    }
}

extension CatalogLicense {
    fileprivate func validate(model: String) throws {
        guard !id.isEmpty, !name.isEmpty, !version.isEmpty, !summary.isEmpty else {
            throw CatalogError.invalid("license for \(model) has an empty required field")
        }
        guard URL(string: url)?.scheme == "https" else {
            throw CatalogError.invalid("license URL for \(model) must be https")
        }
    }
}

/// Relative, `/`-separated file paths inside a model folder (`docs/lld/models.md` §2). The catalog and the installer
/// both confine paths with this rule.
public enum CatalogPath {
    /// Non-empty and relative, with no empty, `.` or `..` segment, no backslash and no NUL byte.
    public static func isSafe(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\\"), !path.contains("\0") else { return false }
        return path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy {
            !$0.isEmpty && $0 != "." && $0 != ".."
        }
    }

    /// The key under which two names collide on disk. macOS volumes are case-insensitive and compare names in a
    /// Unicode-normalised form, so `Model.safetensors` and `model.safetensors`, or one name in composed and decomposed
    /// Unicode, name the same file. Used for file paths within a model and for repo names.
    public static func collisionKey(_ name: String) -> String {
        name.precomposedStringWithCanonicalMapping
            .folding(options: .caseInsensitive, locale: nil)
            .precomposedStringWithCanonicalMapping
    }
}
