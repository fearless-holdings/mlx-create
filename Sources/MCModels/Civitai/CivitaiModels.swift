import Foundation

// Decoded subset of Civitai's public `/api/v1` responses (HLD §8.7). Only the fields the app reads are declared.
// Missing and null optional fields decode to defaults and unknown fields are ignored, so a response that omits them
// still decodes. A field of the wrong type is treated as absent where the field is optional.

/// One page of `GET /api/v1/models`. Pass `nextCursor` back as the cursor for the following page.
public struct CivitaiSearchPage: Decodable, Sendable, Equatable {
    public let items: [CivitaiModel]
    public let nextCursor: String?

    private enum CodingKeys: String, CodingKey {
        case items, metadata
    }

    private enum MetadataKeys: String, CodingKey {
        case nextCursor
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        items = try container.decodeIfPresent([CivitaiModel].self, forKey: .items) ?? []
        let metadata = try? container.nestedContainer(keyedBy: MetadataKeys.self, forKey: .metadata)
        nextCursor = try? metadata?.decodeIfPresent(String.self, forKey: .nextCursor)
    }
}

/// A LoRA listing from `GET /api/v1/models`.
public struct CivitaiModel: Decodable, Sendable, Equatable, Identifiable {
    public let id: Int
    public let name: String
    public let creatorName: String?
    /// Civitai's NSFW flag. A listing without the flag counts as NSFW until the user opts in.
    public let isNSFW: Bool
    public let downloadCount: Int?
    /// Civitai's base-model labels, for example `Flux.2 Klein 4B`. Creator-set, so the file's fit check stays the authority.
    public let baseModels: [String]
    /// The license flags sit at the top level of the listing, next to `nsfw`.
    public let license: CivitaiLicense
    public let versions: [CivitaiModelVersion]

    private enum CodingKeys: String, CodingKey {
        case id, name, nsfw, creator, stats, baseModels
        case versions = "modelVersions"
    }

    private struct Creator: Decodable {
        let username: String?
    }

    private struct Stats: Decodable {
        let downloadCount: Int?
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(Int.self, forKey: .id)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        isNSFW = try container.decodeIfPresent(Bool.self, forKey: .nsfw) ?? true
        let creator = try? container.decodeIfPresent(Creator.self, forKey: .creator)
        creatorName = creator?.username
        let stats = try? container.decodeIfPresent(Stats.self, forKey: .stats)
        downloadCount = stats?.downloadCount
        baseModels = try container.decodeIfPresent([String].self, forKey: .baseModels) ?? []
        license = try CivitaiLicense(from: decoder)
        versions = try container.decodeIfPresent([CivitaiModelVersion].self, forKey: .versions) ?? []
    }
}

/// License and commercial-use flags Civitai reports for a model. Shown to the user and recorded at download (D20).
public struct CivitaiLicense: Decodable, Sendable, Equatable {
    public let allowNoCredit: Bool?
    public let allowCommercialUse: [String]
    public let allowDerivatives: Bool?
    public let allowDifferentLicense: Bool?

    private enum CodingKeys: String, CodingKey {
        case allowNoCredit, allowCommercialUse, allowDerivatives, allowDifferentLicense
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        allowNoCredit = try? container.decodeIfPresent(Bool.self, forKey: .allowNoCredit)
        allowCommercialUse = (try? container.decodeIfPresent([String].self, forKey: .allowCommercialUse)) ?? []
        allowDerivatives = try? container.decodeIfPresent(Bool.self, forKey: .allowDerivatives)
        allowDifferentLicense = try? container.decodeIfPresent(Bool.self, forKey: .allowDifferentLicense)
    }
}

/// One version of a LoRA, from a listing or from `GET /api/v1/model-versions/{id}`.
public struct CivitaiModelVersion: Decodable, Sendable, Equatable, Identifiable {
    public let id: Int
    public let modelID: Int?
    public let name: String
    public let baseModel: String?
    /// Parsed from Civitai's ISO 8601 timestamp. Listings carry this field, and version detail carries it too.
    public let publishedAt: Date?
    public let trainedWords: [String]
    public let files: [CivitaiFile]
    public let images: [CivitaiImage]

    /// The file to download: the primary `.safetensors` file, else the first `.safetensors` file. Nil when the version
    /// has none, in which case the version is not downloadable.
    public var safetensorsFile: CivitaiFile? {
        let candidates = files.filter(\.isSafetensors)
        return candidates.first(where: \.primary) ?? candidates.first
    }

    /// Non-empty example prompts from the version's images, in image order.
    public var examplePrompts: [String] {
        images.compactMap(\.prompt).filter { !$0.isEmpty }
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case modelID = "modelId"
        case name, baseModel, publishedAt, trainedWords, files, images
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(Int.self, forKey: .id)
        modelID = try? container.decodeIfPresent(Int.self, forKey: .modelID)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        baseModel = try? container.decodeIfPresent(String.self, forKey: .baseModel)
        let published = try? container.decodeIfPresent(String.self, forKey: .publishedAt)
        publishedAt = published.flatMap { CivitaiDate.parse($0) }
        trainedWords = try container.decodeIfPresent([String].self, forKey: .trainedWords) ?? []
        files = try container.decodeIfPresent([CivitaiFile].self, forKey: .files) ?? []
        images = try container.decodeIfPresent([CivitaiImage].self, forKey: .images) ?? []
    }
}

/// One file of a version. Only `isSafetensors` files are offered for download (AGENTS.md non-negotiable 6).
public struct CivitaiFile: Decodable, Sendable, Equatable, Identifiable {
    public let id: Int
    public let name: String
    /// Size as Civitai reports it, in KiB.
    public let sizeKB: Double?
    /// `metadata.format`, for example `SafeTensor`.
    public let format: String?
    /// `hashes.SHA256`, lowercased to match `Sha256File`.
    public let sha256: String?
    public let primary: Bool
    /// The signed download URL Civitai advertises. Downloads resolve it again per attempt.
    public let downloadURL: URL?

    public var sizeBytes: Int64? {
        sizeKB.map { Int64(($0 * 1024).rounded()) }
    }

    /// Civitai's metadata says SafeTensor and the name ends in `.safetensors`.
    public var isSafetensors: Bool {
        format == "SafeTensor" && name.lowercased().hasSuffix(".safetensors")
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, sizeKB, metadata, hashes, primary
        case downloadURL = "downloadUrl"
    }

    private struct Metadata: Decodable {
        let format: String?
    }

    private struct Hashes: Decodable {
        let sha256: String?

        private enum CodingKeys: String, CodingKey {
            case sha256 = "SHA256"
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(Int.self, forKey: .id)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        sizeKB = try? container.decodeIfPresent(Double.self, forKey: .sizeKB)
        let metadata = try? container.decodeIfPresent(Metadata.self, forKey: .metadata)
        format = metadata?.format
        let hashes = try? container.decodeIfPresent(Hashes.self, forKey: .hashes)
        sha256 = hashes?.sha256?.lowercased()
        primary = try container.decodeIfPresent(Bool.self, forKey: .primary) ?? false
        let url = try? container.decodeIfPresent(String.self, forKey: .downloadURL)
        downloadURL = url.flatMap { URL(string: $0) }
    }
}

/// One image of a version. `prompt` comes from `meta.prompt`, which listings include only when generation metadata is public.
public struct CivitaiImage: Decodable, Sendable, Equatable {
    public let url: URL?
    /// Civitai's per-image NSFW level, as reported. The blur rule interprets it, not this type.
    public let nsfwLevel: Int?
    public let width: Int?
    public let height: Int?
    public let prompt: String?

    private enum CodingKeys: String, CodingKey {
        case url, nsfwLevel, width, height, meta
    }

    private struct Meta: Decodable {
        let prompt: String?
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let rawURL = try? container.decodeIfPresent(String.self, forKey: .url)
        url = rawURL.flatMap { URL(string: $0) }
        nsfwLevel = try? container.decodeIfPresent(Int.self, forKey: .nsfwLevel)
        width = try? container.decodeIfPresent(Int.self, forKey: .width)
        height = try? container.decodeIfPresent(Int.self, forKey: .height)
        let meta = try? container.decodeIfPresent(Meta.self, forKey: .meta)
        prompt = meta?.prompt
    }
}

/// Civitai timestamps are ISO 8601, with fractional seconds on the API's own values (`2026-03-23T17:12:14.712Z`).
enum CivitaiDate {
    static func parse(_ text: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: text) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: text)
    }
}
