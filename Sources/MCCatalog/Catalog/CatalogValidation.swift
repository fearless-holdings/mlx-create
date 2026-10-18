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
        guard sequence >= 0 else { throw CatalogError.invalid("sequence must not be negative") }
        guard !models.isEmpty else { throw CatalogError.invalid("catalog lists no models") }
        var ids = Set<String>()
        for model in models {
            guard ids.insert(model.id).inserted else { throw CatalogError.invalid("duplicate model id \(model.id)") }
            try model.validate()
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

        var seen = Set<String>()
        var total: Int64 = 0
        for file in files {
            guard CatalogPath.isSafe(file.path) else {
                throw CatalogError.invalid("file path \(file.path) must be relative with no '..' segment")
            }
            if case .rejected(let reason) = WeightFilePolicy.check(file.path) {
                throw CatalogError.invalid("file \(file.path) is not allowed: \(reason)")
            }
            guard seen.insert(file.path).inserted else { throw CatalogError.invalid("duplicate file path \(file.path)") }
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
}
