import CryptoKit
import Foundation
import MCCatalog

/// `catalog/models.src.json`: the reviewed inputs that `mc-catalog build` turns into a catalog.
struct SourceCatalog: Decodable, Equatable {
    let issuedAt: Date
    let models: [SourceModel]
    /// Absent means no shelf (D43). The entries are copied into the built catalog unchanged.
    let loraShelf: [LoRAShelfEntry]

    enum CodingKeys: String, CodingKey {
        case issuedAt = "issued_at"
        case models
        case loraShelf = "lora_shelf"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        issuedAt = try c.decode(Date.self, forKey: .issuedAt)
        models = try c.decode([SourceModel].self, forKey: .models)
        loraShelf = try c.decodeIfPresent([LoRAShelfEntry].self, forKey: .loraShelf) ?? []
    }

    static func load(_ data: Data) throws -> SourceCatalog {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            return try decoder.decode(SourceCatalog.self, from: data)
        } catch {
            throw CatalogToolError.source("\(error)")
        }
    }
}

struct SourceModel: Decodable, Equatable {
    let id: String
    let family: String
    let name: String
    let quantization: String
    let repo: String
    /// Branch or tag resolved to a commit at build time; the catalog stores the commit, never the ref.
    let ref: String
    let ramGB: Double
    let license: CatalogLicense
    /// Absent means image (KTD4).
    let kind: CatalogModelKind?
    /// Preference order for the automatic recommendation, lowest first. Absent means never recommended (D42).
    let recommendRank: Int?

    enum CodingKeys: String, CodingKey {
        case id, family, name, quantization, repo, ref, license, kind
        case recommendRank = "recommend_rank"
        case ramGB = "ram_gb"
    }
}

struct CatalogBuild: Equatable {
    let catalog: Catalog
    let bytes: Data
    /// Repo paths dropped by `WeightFilePolicy`, reported so a reviewer sees what was left out.
    let skipped: [String]
}

/// Builds a catalog from a Hugging Face tree at pinned commits (D27, KTD1).
/// LFS entries contribute their `lfs.oid` as SHA-256. Small non-LFS files are downloaded and hashed.
struct CatalogBuilder: Sendable {
    /// Largest non-LFS file the builder will download to hash. Anything larger is refused.
    static let maxSmallFileBytes: Int64 = 1 << 20

    let hub: any HubClient

    func build(source: SourceCatalog, previous: Catalog?) async throws -> CatalogBuild {
        var models: [CatalogModel] = []
        var skipped: [String] = []
        for entry in source.models {
            let (model, dropped) = try await buildModel(entry)
            models.append(model)
            skipped += dropped.map { "\(entry.id): \($0)" }
        }
        let catalog = Catalog(
            schemaVersion: Catalog.supportedSchemaVersion,
            sequence: (previous?.sequence ?? 0) + 1,
            issuedAt: source.issuedAt,
            models: models,
            loraShelf: source.loraShelf)
        try catalog.validate()
        return CatalogBuild(catalog: catalog, bytes: try CatalogEncoder.encode(catalog), skipped: skipped)
    }

    private func buildModel(_ entry: SourceModel) async throws -> (CatalogModel, [String]) {
        guard CatalogModel.isRepo(entry.repo) else { throw CatalogToolError.source("repo \(entry.repo) must be org/name") }
        let revision = try await hub.resolveRevision(repo: entry.repo, ref: entry.ref)
        guard CatalogModel.isHex(revision, length: 40) else {
            throw CatalogToolError.hub("\(entry.repo)@\(entry.ref) resolved to a non-commit \(revision)")
        }
        var files: [CatalogFile] = []
        var dropped: [String] = []
        for item in try await hub.tree(repo: entry.repo, revision: revision) where item.type == "file" {
            if case .rejected = WeightFilePolicy.check(item.path) {
                dropped.append(item.path)
                continue
            }
            files.append(try await file(for: item, of: entry, revision: revision))
        }
        files.sort { $0.path < $1.path }
        let model = CatalogModel(
            id: entry.id, family: entry.family, name: entry.name, quantization: entry.quantization,
            repo: entry.repo, revision: revision,
            downloadBytes: files.reduce(0) { $0 + $1.size }, ramGB: entry.ramGB,
            license: entry.license, files: files, kind: entry.kind ?? .image, recommendRank: entry.recommendRank)
        try model.validate()
        return (model, dropped)
    }

    private func file(for item: HubTreeEntry, of entry: SourceModel, revision: String) async throws -> CatalogFile {
        if let lfs = item.lfs {
            if let size = item.size, size != lfs.size {
                throw CatalogToolError.hub("\(entry.repo) \(item.path): tree size \(size) disagrees with LFS size \(lfs.size)")
            }
            return CatalogFile(path: item.path, size: lfs.size, sha256: lfs.oid)
        }
        guard let size = item.size else {
            throw CatalogToolError.hub("\(entry.repo) \(item.path): no size in tree")
        }
        guard size <= Self.maxSmallFileBytes else {
            throw CatalogToolError.hub("\(entry.repo) \(item.path): \(size) bytes is too large to pin by hashing")
        }
        let data = try await hub.fetch(repo: entry.repo, revision: revision, path: item.path)
        guard Int64(data.count) == size else {
            throw CatalogToolError.hub("\(entry.repo) \(item.path): downloaded \(data.count) bytes, tree says \(size)")
        }
        return CatalogFile(path: item.path, size: size, sha256: SHA256.hash(data: data).hex)
    }
}

extension SHA256Digest {
    var hex: String { map { String(format: "%02x", $0) }.joined() }
}

/// Deterministic JSON: sorted keys, ISO 8601 dates, one trailing newline. The same inputs always give the same bytes.
enum CatalogEncoder {
    static func encode(_ catalog: Catalog) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(catalog) + Data("\n".utf8)
    }
}

/// Lines a reviewer reads before `sign --acknowledge-diff`: added, removed and re-hashed files, revision moves, and
/// shelf additions, removals and changes.
enum CatalogDiff {
    static func lines(previous: Catalog?, next: Catalog) -> [String] {
        let previousModels = Dictionary(
            (previous?.models ?? []).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var lines: [String] = []
        for model in next.models {
            let old = previousModels[model.id]
            if let old, old.revision != model.revision {
                lines.append("~ model \(model.id) revision \(old.revision) -> \(model.revision)")
            } else if old == nil {
                lines.append("+ model \(model.id) revision \(model.revision)")
            }
            let oldFiles = Dictionary((old?.files ?? []).map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
            let newPaths = Set(model.files.map(\.path))
            for file in model.files {
                guard let oldFile = oldFiles[file.path] else {
                    lines.append("+ \(model.id) \(file.path) sha256 \(file.sha256)")
                    continue
                }
                if oldFile.sha256 != file.sha256 {
                    lines.append("~ \(model.id) \(file.path) sha256 \(oldFile.sha256) -> \(file.sha256)")
                }
            }
            for oldFile in old?.files ?? [] where !newPaths.contains(oldFile.path) {
                lines.append("- \(model.id) \(oldFile.path)")
            }
        }
        let newIDs = Set(next.models.map(\.id))
        for old in previous?.models ?? [] where !newIDs.contains(old.id) {
            lines.append("- model \(old.id)")
        }
        return lines + shelfLines(previous: previous, next: next)
    }

    /// An entry is identified by family, role and whether it is always-on, so flipping `always_on` reads as a
    /// removal plus an addition rather than a silent edit.
    private static func shelfKey(_ entry: LoRAShelfEntry) -> String {
        "\(entry.family)\u{0}\(entry.role)\u{0}\(entry.alwaysOn)"
    }

    private static func shelfName(_ entry: LoRAShelfEntry) -> String {
        "shelf \(entry.family)/\(entry.role)" + (entry.alwaysOn ? " (always-on)" : "")
    }

    private static func shelfLines(previous: Catalog?, next: Catalog) -> [String] {
        let previousEntries = Dictionary(
            (previous?.loraShelf ?? []).map { (shelfKey($0), $0) }, uniquingKeysWith: { first, _ in first })
        let nextKeys = Set(next.loraShelf.map(shelfKey))
        var lines: [String] = []
        for entry in next.loraShelf {
            let name = shelfName(entry)
            guard let old = previousEntries[shelfKey(entry)] else {
                lines.append("+ \(name) \(entry.filename) sha256 \(entry.sha256)")
                continue
            }
            if old.sha256 != entry.sha256 {
                lines.append("~ \(name) sha256 \(old.sha256) -> \(entry.sha256)")
            }
            if old.testedScale != entry.testedScale {
                lines.append("~ \(name) tested_scale \(old.testedScale) -> \(entry.testedScale)")
            }
            let detailsChanged =
                old.source != entry.source || old.filename != entry.filename || old.sizeBytes != entry.sizeBytes
                || old.license != entry.license || old.triggerWords != entry.triggerWords
                || old.communityRating != entry.communityRating || old.testedEngine != entry.testedEngine
                || old.nsfw != entry.nsfw
            if detailsChanged { lines.append("~ \(name) details changed") }
        }
        for entry in previous?.loraShelf ?? [] where !nextKeys.contains(shelfKey(entry)) {
            lines.append("- \(shelfName(entry))")
        }
        return lines
    }
}
